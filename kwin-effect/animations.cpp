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
    effects hand an animation to one another.

    SPDX-License-Identifier: GPL-2.0-or-later
*/

#include "core/output.h"
#include "effect/animationeffect.h"
#include "effect/effecthandler.h"
#include "effect/effectwindow.h"
#include "window.h"

#include <KConfigGroup>
#include <QHash>

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>

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

    std::array<Leaf, 2> m_windows, m_fade, m_layers, m_fadeLayers; // [closing, opening]
    bool m_layerOn = false;
    QHash<EffectWindow *, QList<quint64>> m_running;
};

KWIN_EFFECT_FACTORY_SUPPORTED(HyprAnimationsEffect, "animations.json", return HyprAnimationsEffect::supported();)

} // namespace KWin

#include "animations.moc"
