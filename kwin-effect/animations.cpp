/*
    Hyprland's window and layer animations on KWin.

    hl.animation and hl.curve in mmsimpulse.lua (or a Hyprland config it
    sources) end up in kwinrc's [Effect-mmsimpulse_animations], one line per
    leaf of Hyprland's tree that KWin windows have, already resolved down the
    tree by mmsimpulse-shortcuts:

        WindowsIn=<on> <speed> <x1> <y1> <x2> <y2> <style>

    speed is Hyprland's, in tenths of a second; the curve is the bezier through
    (0,0), (x1,y1), (x2,y2), (1,1); the style is Hyprland's, and what it does
    to a window follows Hyprland's animation controllers. Opening and closing
    windows are claimed from KWin's own effects (Scale, Fade, Glide) the way
    effects hand an animation to one another. Switching workspaces plays
    Hyprland's workspacesIn and workspacesOut on the monitor that switched, in
    place of KWin's Slide, which mmsimpulse-shortcuts turns off meanwhile.

    SPDX-License-Identifier: GPL-2.0-or-later
*/

#include "core/output.h"
#include "core/renderviewport.h"
#include "effect/animationeffect.h"
#include "effect/effecthandler.h"
#include "effect/effectwindow.h"
#include "effect/timeline.h"
#include "virtualdesktops.h"
#include "window.h"

#include <KConfigGroup>
#include <QHash>

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <map>

namespace KWin
{

class HyprAnimationsEffect : public AnimationEffect
{
    Q_OBJECT

public:
    HyprAnimationsEffect()
    {
        reconfigure(ReconfigureAll);
        connect(effects, &EffectsHandler::windowAdded, this, [this](EffectWindow *w) {
            start(w, true);
        });
        connect(effects, &EffectsHandler::windowClosed, this, [this](EffectWindow *w) {
            start(w, false);
        });
        connect(effects, &EffectsHandler::windowDeleted, this, [this](EffectWindow *w) {
            m_running.remove(w);
        });
        connect(effects, &EffectsHandler::desktopChanged, this, &HyprAnimationsEffect::switchWorkspace);
        connect(effects, &EffectsHandler::screenRemoved, this, [this](LogicalOutput *screen) {
            m_switches.erase(screen);
            finishSwitches();
        });
    }

    ~HyprAnimationsEffect() override
    {
        m_switches.clear();
        finishSwitches();
    }

    bool isActive() const override
    {
        return !m_switches.empty() || AnimationEffect::isActive();
    }

    void prePaintScreen(ScreenPrePaintData &data) override
    {
        if (auto it = m_switches.find(data.screen); it != m_switches.end()) {
            it->second.in.advance(data.view);
            it->second.out.advance(data.view);
            data.mask |= PAINT_SCREEN_TRANSFORMED;
        }
        AnimationEffect::prePaintScreen(data);
    }

    void prePaintWindow(RenderView *view, EffectWindow *w, WindowPrePaintData &data) override
    {
        if (m_switches.contains(w->screen())) {
            data.setTransformed();
            data.setTranslucent(); // a fading workspace
        }
        AnimationEffect::prePaintWindow(view, w, data);
    }

    bool paintWindow(const RenderTarget &renderTarget, const RenderViewport &viewport, EffectWindow *w, int mask,
                     const Region &deviceRegion, WindowPaintData &data) override
    {
        auto it = m_switches.find(w->screen());
        if (it == m_switches.end() || w->isOnAllDesktops() || w == it->second.with) {
            return AnimationEffect::paintWindow(renderTarget, viewport, w, mask, deviceRegion, data);
        }
        const Switch &s = it->second;
        const bool in = w->isOnDesktop(s.to);
        if (!in && !w->isOnDesktop(s.from)) {
            return AnimationEffect::paintWindow(renderTarget, viewport, w, mask, deviceRegion, data);
        }
        // Workspace::startAnimation: the new one comes in from its offset to
        // nothing, the old one goes from nothing to its offset.
        const qreal t = in ? s.in.value() : s.out.value();
        data += (in ? s.inOffset : s.outOffset) * (in ? 1 - t : t);
        // Nothing of it on the monitor next to this one.
        const Region onScreen = deviceRegion.intersected(viewport.mapToDeviceCoordinatesAligned(s.screen->geometry()));
        return AnimationEffect::paintWindow(renderTarget, viewport, w, mask, onScreen, data);
    }

    void postPaintScreen() override
    {
        for (auto it = m_switches.begin(); it != m_switches.end();) {
            if (it->second.in.done() && it->second.out.done()) {
                it = m_switches.erase(it);
            } else {
                effects->addRepaint(it->second.screen->geometry());
                ++it;
            }
        }
        if (m_switches.empty()) {
            finishSwitches();
        }
        AnimationEffect::postPaintScreen();
    }

    static bool supported()
    {
        return effects->animationsSupported();
    }

    void reconfigure(ReconfigureFlags) override
    {
        const KConfigGroup g = effects->config()->group(QStringLiteral("Effect-mmsimpulse_animations"));
        m_windows = {leaf(g, "WindowsOut"), leaf(g, "WindowsIn")};
        m_fade = {leaf(g, "FadeOut"), leaf(g, "FadeIn")};
        m_layers = {leaf(g, "LayersOut"), leaf(g, "LayersIn")};
        m_fadeLayers = {leaf(g, "FadeLayersOut"), leaf(g, "FadeLayersIn")};
        m_layerOn = g.readEntry("Layers", false);
        m_workspaces = {leaf(g, "WorkspacesOut"), leaf(g, "WorkspacesIn")};
    }

private:
    struct Leaf
    {
        bool on = false;
        int ms = 0;
        QEasingCurve curve;
        QString style;
    };

    static Leaf leaf(const KConfigGroup &g, const char *name)
    {
        const QStringList f = g.readEntry(name, QString()).split(QLatin1Char(' '), Qt::SkipEmptyParts);
        Leaf l;
        if (f.size() < 6) {
            return l;
        }
        l.on = f[0] == QLatin1String("1");
        l.ms = qRound(f[1].toDouble() * 100);
        l.curve = QEasingCurve(QEasingCurve::BezierSpline);
        l.curve.addCubicBezierSegment(QPointF(f[2].toDouble(), f[3].toDouble()),
                                      QPointF(f[4].toDouble(), f[5].toDouble()), QPointF(1, 1));
        l.style = f.mid(6).join(QLatin1Char(' ')).toLower();
        return l;
    }

    static bool isLayer(EffectWindow *w)
    {
        // LayerShellV1Window has no exported meta-object to cast to.
        return w->window() && w->window()->inherits("KWin::LayerShellV1Window");
    }

    // The windows KWin's Scale effect animates.
    static bool isAppWindow(EffectWindow *w)
    {
        if (w->hasDecoration()) {
            return true;
        }
        if (w->isPopupWindow() || w->isLockScreen() || w->isOutline() || !w->isManaged()) {
            return false;
        }
        return w->isNormalWindow() || w->isDialog();
    }

    // Hyprland's percentageFromStyle: the number before a '%' after the last
    // space, as a fraction.
    static double percentage(const QString &style)
    {
        if (!style.contains(QLatin1Char('%'))) {
            return 0;
        }
        const QString last = style.mid(style.lastIndexOf(QLatin1Char(' ')) + 1);
        return last.left(last.indexOf(QLatin1Char('%'))).toInt() / 100.0;
    }

    void start(EffectWindow *w, bool in)
    {
        if (effects->hasActiveFullScreenEffect()) {
            return;
        }
        const bool layer = isLayer(w);
        if (layer ? !m_layerOn : !isAppWindow(w)) {
            return;
        }
        if (!w->isVisible() || (!in && w->skipsCloseAnimation())) {
            return;
        }
        w->setData(in ? WindowAddedGrabRole : WindowClosedGrabRole, QVariant::fromValue(static_cast<void *>(this)));
        for (quint64 id : m_running.take(w)) {
            cancel(id);
        }

        QList<quint64> ids;
        const Leaf &fade = (layer ? m_fadeLayers : m_fade)[in];
        if (fade.on) {
            ids << animate(w, Opacity, 0, animationTime(std::chrono::milliseconds(fade.ms)), FPx2(in ? 1.0 : 0.0),
                           fade.curve, 0, FPx2(in ? 0.0 : 1.0));
        }
        const Leaf &move = (layer ? m_layers : m_windows)[in];
        if (move.on) {
            ids << (layer ? layerGeometry(w, move, in) : windowGeometry(w, move, in));
        }
        ids.removeAll(0);
        if (!ids.isEmpty()) {
            m_running[w] = ids;
        }
    }

    // Opening goes from the styled state to the window; closing the other way.
    quint64 animateTo(EffectWindow *w, const Leaf &l, bool in, Attribute a, const FPx2 &styled, const FPx2 &normal)
    {
        return animate(w, a, 0, animationTime(std::chrono::milliseconds(l.ms)), in ? normal : styled, l.curve, 0,
                       in ? styled : normal);
    }

    // WindowAnimationController: slide [top|bottom|left|right], gnomed, and
    // popin [N%] for anything else.
    quint64 windowGeometry(EffectWindow *w, const Leaf &l, bool in)
    {
        const RectF g = w->frameGeometry();
        const QStringList words = l.style.split(QLatin1Char(' '), Qt::SkipEmptyParts);
        const QString kind = words.value(0);
        if (kind == QLatin1String("slide")) {
            const LogicalOutput *screen = w->screen();
            if (!screen) {
                return 0;
            }
            const RectF mon = screen->geometryF();
            const QString force = words.value(1);
            QPointF to;
            if (force.isEmpty()) {
                const double mx = g.x() + g.width() / 2, my = g.y() + g.height() / 2;
                const std::array<double, 4> d = {my - mon.y(), mon.x() + mon.width() - mx, mon.y() + mon.height() - my, mx - mon.x()};
                const double least = *std::min_element(d.begin(), d.end());
                to = least == d[2] ? QPointF(g.x(), mon.y() + mon.height())
                    : least == d[3] ? QPointF(g.x() - g.width(), g.y())
                    : least == d[1] ? QPointF(g.x() + g.width(), g.y())
                                    : QPointF(g.x(), mon.y() - g.height());
            } else {
                to = force == QLatin1String("bottom") ? QPointF(g.x(), mon.y() + mon.height())
                    : force == QLatin1String("left")  ? QPointF(g.x() - g.width(), g.y())
                    : force == QLatin1String("right") ? QPointF(g.x() + g.width(), g.y())
                                                      : QPointF(g.x(), mon.y() - g.height());
            }
            return animateTo(w, l, in, Translation, FPx2(to.x() - g.x(), to.y() - g.y()), FPx2(0.0, 0.0));
        }
        if (kind == QLatin1String("gnomed") || kind == QLatin1String("gnome")) {
            return animateTo(w, l, in, Size, FPx2(g.width(), 0.0), FPx2(g.width(), g.height()));
        }
        // A style that starts with '%' has no percentage (Hyprland's
        // ignoreLeadingPercentage).
        const double p = l.style.startsWith(QLatin1Char('%')) ? 0 : percentage(l.style);
        return animateTo(w, l, in, Size,
                         FPx2(std::clamp(g.width() * p, std::min(5.0, g.width()), g.width()),
                              std::clamp(g.height() * p, std::min(5.0, g.height()), g.height())),
                         FPx2(g.width(), g.height()));
    }

    // LayerSurfaceAnimationController: slide [top|bottom|left|right] from the
    // nearest screen edge, popin [N%], and nothing but the fade otherwise.
    quint64 layerGeometry(EffectWindow *w, const Leaf &l, bool in)
    {
        const RectF g = w->frameGeometry();
        const QStringList words = l.style.split(QLatin1Char(' '), Qt::SkipEmptyParts);
        if (l.style.startsWith(QLatin1String("slide"))) {
            const LogicalOutput *screen = w->screen();
            if (!screen) {
                return 0;
            }
            const RectF mon = screen->geometryF();
            static const QStringList edges = {QStringLiteral("top"), QStringLiteral("bottom"), QStringLiteral("left"), QStringLiteral("right")};
            int edge = words.size() > 1 ? edges.indexOf(words[1]) : -1;
            if (edge == -1) {
                // Hyprland's edge points, the third of them a corner as there.
                const QPointF mid(g.x() + g.width() / 2, g.y() + g.height() / 2);
                const std::array<QPointF, 4> points = {
                    QPointF(mon.x() + mon.width() / 2, mon.y()),
                    QPointF(mon.x() + mon.width() / 2, mon.y() + mon.height()),
                    QPointF(mon.x(), mon.y() + mon.height()),
                    QPointF(mon.x() + mon.width(), mon.y() + mon.height() / 2),
                };
                double closest = std::numeric_limits<double>::max();
                for (int i = 0; i < 4; ++i) {
                    const QPointF v = mid - points[i];
                    const double dist = std::hypot(v.x(), v.y());
                    if (dist < closest) {
                        edge = i;
                        closest = dist;
                    }
                }
            }
            const QPointF to = edge == 0 ? QPointF(g.x(), mon.y() - g.height())
                : edge == 1              ? QPointF(g.x(), mon.y() + mon.height())
                : edge == 2              ? QPointF(mon.x() - g.width(), g.y())
                                         : QPointF(mon.x() + mon.width(), g.y());
            return animateTo(w, l, in, Translation, FPx2(to.x() - g.x(), to.y() - g.y()), FPx2(0.0, 0.0));
        }
        if (l.style.startsWith(QLatin1String("popin"))) {
            const double p = percentage(l.style);
            return animateTo(w, l, in, Size, FPx2(std::max(g.width() * p, 5.0), std::max(g.height() * p, 5.0)),
                             FPx2(g.width(), g.height()));
        }
        return 0;
    }

    struct Switch
    {
        LogicalOutput *screen = nullptr;
        VirtualDesktop *from = nullptr;
        VirtualDesktop *to = nullptr;
        EffectWindow *with = nullptr;
        TimeLine in, out;
        QPointF inOffset, outOffset;
        bool inFade = false, outFade = false;
        QList<EffectWindowVisibleRef> visible;
    };

    // Workspace::startAnimation for one side: where the workspace is when it
    // is off screen, and whether it fades.
    static void workspaceStyle(const QString &style, bool left, const RectF &mon, QPointF *offset, bool *fade, bool in)
    {
        const QStringList args = style.split(QLatin1Char(' '), Qt::SkipEmptyParts);
        bool vert = style.startsWith(QLatin1String("slidevert")) || style.startsWith(QLatin1String("slidefadevert"));
        if (args.size() > 1) {
            const QString a = args[1];
            if (a == QLatin1String("top") || a == QLatin1String("bottom")) {
                left = a == QLatin1String("bottom");
                vert = true;
            } else if (a == QLatin1String("left") || a == QLatin1String("right")) {
                left = a == QLatin1String("right");
                vert = false;
            }
        }
        qreal perc = 1.0;
        if (!args.isEmpty() && args.last().endsWith(QLatin1Char('%'))) {
            perc = args.last().chopped(1).toInt() / 100.0;
        }
        // general:gaps_workspaces is Hyprland's 0.
        const qreal d = (vert ? mon.height() : mon.width()) * perc;
        const qreal sign = (left ? 1 : -1) * (in ? 1 : -1);
        *fade = style.startsWith(QLatin1String("slidefade")) || style == QLatin1String("fade");
        *offset = style == QLatin1String("fade") ? QPointF() : vert ? QPointF(0, sign * d) : QPointF(sign * d, 0);
    }

    void switchWorkspace(VirtualDesktop *from, VirtualDesktop *to, EffectWindow *with, LogicalOutput *screen)
    {
        if (!screen || !from || !to || from == to
            || (effects->hasActiveFullScreenEffect() && effects->activeFullScreenEffect() != this)) {
            return;
        }
        const Leaf &in = m_workspaces[1], &out = m_workspaces[0];
        if (!in.on && !out.on) {
            return;
        }
        // ponytail: a switch while one plays starts over from the old
        // workspace in place; Hyprland carries the moving one on.
        Switch &s = m_switches[screen];
        s = Switch();
        s.screen = screen;
        s.from = from;
        s.to = to;
        s.with = with;
        // Monitor::changeWorkspace: a higher number comes from the right.
        const bool left = to->x11DesktopNumber() > from->x11DesktopNumber();
        const RectF mon = screen->geometryF();
        workspaceStyle(in.style, left, mon, &s.inOffset, &s.inFade, true);
        workspaceStyle(out.style, left, mon, &s.outOffset, &s.outFade, false);
        for (TimeLine *line : {&s.in, &s.out}) {
            const Leaf &l = line == &s.in ? in : out;
            line->setDuration(l.on ? animationTime(std::chrono::milliseconds(l.ms)) : std::chrono::milliseconds(1));
            line->setEasingCurve(l.curve);
        }
        for (quint64 id : std::as_const(m_fading)) {
            cancel(id);
        }
        m_fading.clear();
        const auto windows = effects->stackingOrder();
        for (EffectWindow *w : windows) {
            if (w->screen() != screen || w->isOnAllDesktops() || w == with) {
                continue;
            }
            const bool isIn = w->isOnDesktop(to);
            if (!isIn && !w->isOnDesktop(from)) {
                continue;
            }
            if (!isIn) {
                s.visible << EffectWindowVisibleRef(w, EffectWindow::PAINT_DISABLED_BY_DESKTOP);
            }
            // The fade as a window animation, as KWin's Fade Desktop does.
            if (isIn ? s.inFade : s.outFade) {
                m_fading << animate(w, Opacity, 0, isIn ? s.in.duration() : s.out.duration(), FPx2(isIn ? 1.0 : 0.0),
                                    (isIn ? in : out).curve, 0, FPx2(isIn ? 0.0 : 1.0), false, false);
            }
        }
        effects->setActiveFullScreenEffect(this);
        effects->addRepaint(screen->geometry());
    }

    void finishSwitches()
    {
        if (effects->activeFullScreenEffect() == this) {
            effects->setActiveFullScreenEffect(nullptr);
        }
    }

    std::array<Leaf, 2> m_windows, m_fade, m_layers, m_fadeLayers, m_workspaces; // [closing, opening]
    std::map<LogicalOutput *, Switch> m_switches;
    QList<quint64> m_fading;
    bool m_layerOn = false;
    QHash<EffectWindow *, QList<quint64>> m_running;
};

KWIN_EFFECT_FACTORY_SUPPORTED(HyprAnimationsEffect, "animations.json", return HyprAnimationsEffect::supported();)

} // namespace KWin

#include "animations.moc"
