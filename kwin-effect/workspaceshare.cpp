/*
    mmsimpulse workspace sharing.

    "Share virtual screen" in KDE's screen-share dialog makes KWin add a screen
    that exists only in the stream. A window lives on one screen, so moving a
    workspace's windows onto it would take them off the monitor. Instead this
    paints, on that screen, the windows of whichever workspace the screen is
    set to (its current desktop, which the mmsimpulse shell chooses), taken
    from the monitor they are on and scaled to fit. The workspace stays usable
    on the monitor, and keeps streaming while the monitor shows another one.

    Windows of a workspace no monitor is showing are hidden by KWin; they are
    kept paintable here, and kept off the monitors they would otherwise
    appear on.

    SPDX-License-Identifier: GPL-2.0-or-later
*/

#include "core/output.h"
#include "core/renderviewport.h"
#include "effect/effect.h"
#include "effect/effecthandler.h"
#include "effect/effectwindow.h"

#include <QHash>

namespace KWin
{

class WorkspaceShareEffect : public Effect
{
    Q_OBJECT

public:
    WorkspaceShareEffect()
    {
        connect(effects, &EffectsHandler::screenAdded, this, &WorkspaceShareEffect::update);
        connect(effects, &EffectsHandler::screenRemoved, this, &WorkspaceShareEffect::update);
        connect(effects, &EffectsHandler::desktopChanged, this, &WorkspaceShareEffect::update);
        connect(effects, &EffectsHandler::screenLockingChanged, this, &WorkspaceShareEffect::repaintShares);
        connect(effects, &EffectsHandler::windowAdded, this, &WorkspaceShareEffect::watch);
        connect(effects, &EffectsHandler::windowDeleted, this, [this](EffectWindow *w) {
            m_visible.remove(w);
            repaintShares();
        });
        const auto windows = effects->stackingOrder();
        for (EffectWindow *w : windows) {
            watch(w);
        }
        update();
    }

    static bool supported()
    {
        return effects->isOpenGLCompositing();
    }

    bool isActive() const override
    {
        return !m_shares.isEmpty();
    }

    int requestedEffectChainPosition() const override
    {
        return 90;
    }

    void prePaintWindow(RenderView *view, EffectWindow *w, WindowPrePaintData &data) override
    {
        // Kept paintable for the stream only: it must not hide what is
        // really on the monitor underneath it.
        if (keptOffMonitor(w)) {
            data.setTranslucent();
        }
        effects->prePaintWindow(view, w, data);
    }

    void paintWindow(const RenderTarget &renderTarget, const RenderViewport &viewport, EffectWindow *w, int mask, const Region &deviceRegion, WindowPaintData &data) override
    {
        if (keptOffMonitor(w)) {
            return;
        }
        effects->paintWindow(renderTarget, viewport, w, mask, deviceRegion, data);
    }

    void paintScreen(const RenderTarget &renderTarget, const RenderViewport &viewport, int mask, const Region &deviceRegion, LogicalOutput *screen) override
    {
        effects->paintScreen(renderTarget, viewport, mask, deviceRegion, screen);
        // Over the lock screen the stream gets the lock screen, like any
        // other screen, and nothing of what it hides.
        if (!m_shares.contains(screen) || effects->isScreenLocked()) {
            return;
        }
        VirtualDesktop *desktop = effects->currentDesktop(screen);
        const RectF target = screen->geometry();
        const auto windows = effects->stackingOrder();
        for (EffectWindow *w : windows) {
            if (!shown(w, desktop, screen)) {
                continue;
            }
            // The monitor's picture, scaled to fit the shared screen and
            // centred in it.
            const RectF source = w->screen()->geometry();
            const qreal scale = std::min(target.width() / source.width(), target.height() / source.height());
            const QPointF origin(target.x() + (target.width() - source.width() * scale) / 2,
                                 target.y() + (target.height() - source.height() * scale) / 2);
            WindowPaintData data;
            data.setXScale(scale);
            data.setYScale(scale);
            data.setXTranslation(origin.x() + (w->x() - source.x()) * scale - w->x());
            data.setYTranslation(origin.y() + (w->y() - source.y()) * scale - w->y());
            effects->drawWindow(renderTarget, viewport, w,
                                PAINT_WINDOW_TRANSFORMED | PAINT_WINDOW_TRANSLUCENT | PAINT_WINDOW_OPAQUE,
                                viewport.mapToDeviceCoordinatesAligned(screen->geometry()), data);
        }
    }

private:
    static bool isShare(LogicalOutput *screen)
    {
        // How xdg-desktop-portal-kde names the screens it creates.
        return screen->name().startsWith(QLatin1String("Virtual-virtual-xdp-kde-"));
    }

    // Belongs to the workspace a shared screen shows, and is not a window of
    // the shared screen itself (its wallpaper and panels).
    static bool shown(EffectWindow *w, VirtualDesktop *desktop, LogicalOutput *share)
    {
        return w->screen() && w->screen() != share && !isShare(w->screen())
            && !w->isDeleted() && !w->isMinimized() && !w->isDesktop() && !w->isDock()
            && !w->isOnAllDesktops() && w->isOnDesktop(desktop);
    }

    bool keptOffMonitor(EffectWindow *w) const
    {
        return m_visible.contains(w) && w->screen() && !w->isOnDesktop(effects->currentDesktop(w->screen()));
    }

    void watch(EffectWindow *w)
    {
        connect(w, &EffectWindow::windowDesktopsChanged, this, &WorkspaceShareEffect::update);
        connect(w, &EffectWindow::minimizedChanged, this, &WorkspaceShareEffect::update);
        connect(w, &EffectWindow::windowDamaged, this, [this](EffectWindow *w) {
            if (m_visible.contains(w)) {
                repaintShares();
            }
        });
        connect(w, &EffectWindow::windowFrameGeometryChanged, this, [this](EffectWindow *w) {
            if (m_visible.contains(w)) {
                repaintShares();
            }
        });
        update();
    }

    void update()
    {
        m_shares.clear();
        const auto screens = effects->screens();
        for (LogicalOutput *screen : screens) {
            if (isShare(screen)) {
                m_shares << screen;
            }
        }
        QHash<EffectWindow *, EffectWindowVisibleRef> visible;
        const auto windows = effects->stackingOrder();
        for (EffectWindow *w : windows) {
            for (LogicalOutput *share : std::as_const(m_shares)) {
                if (shown(w, effects->currentDesktop(share), share)) {
                    auto it = m_visible.find(w);
                    visible.insert(w, it != m_visible.end() ? std::move(*it) : EffectWindowVisibleRef(w, EffectWindow::PAINT_DISABLED_BY_DESKTOP));
                    break;
                }
            }
        }
        m_visible = std::move(visible);
        repaintShares();
        effects->addRepaintFull();
    }

    void repaintShares()
    {
        for (LogicalOutput *share : std::as_const(m_shares)) {
            effects->addRepaint(share->geometry());
        }
    }

    QList<LogicalOutput *> m_shares;
    QHash<EffectWindow *, EffectWindowVisibleRef> m_visible;
};

KWIN_EFFECT_FACTORY_SUPPORTED(WorkspaceShareEffect, "metadata.json", return WorkspaceShareEffect::supported();)

} // namespace KWin

#include "workspaceshare.moc"
