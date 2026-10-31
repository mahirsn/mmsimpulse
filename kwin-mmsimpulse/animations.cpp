#include "animations.h"

#include <compositor.h>
#include <effect/effecthandler.h>
#include <effect/effectwindow.h>
#include <window.h>

using namespace KWin;

LayerAnimations::LayerAnimations()
{
    connectEffects();
    // The effects handler is made again whenever compositing restarts. This
    // runs before the effects are loaded, so this side sees each new window
    // first and the claim is in place when an effect looks for it.
    connect(Compositor::self(), &Compositor::compositingToggled, this, [this](bool active) {
        if (active)
            connectEffects();
    });
}

void LayerAnimations::connectEffects()
{
    if (!effects || m_effects == effects)
        return;
    m_effects = effects;
    connect(effects, &EffectsHandler::windowAdded, this, [this](EffectWindow *ew) {
        Window *w = ew->window();
        // LayerShellV1Window has no exported meta-object to cast to.
        if (!w || !w->inherits("KWin::LayerShellV1Window") || !w->isNormalWindow())
            return;
        const QVariant claim = QVariant::fromValue(static_cast<void *>(this));
        ew->setData(WindowAddedGrabRole, claim);
        ew->setData(WindowClosedGrabRole, claim);
    });
}
