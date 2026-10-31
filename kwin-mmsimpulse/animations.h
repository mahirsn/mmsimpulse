#pragma once

#include <QObject>
#include <QPointer>

namespace KWin
{
class EffectsHandler;
}

// Keeps KWin's window animations off a shell's panels.
//
// KWin turns a layer surface's namespace into a window type and knows only its
// own names ("dock", "notification", ...). A shell written for another
// compositor names its panels "dms:bar", "dms:spotlight" and so on, so KWin
// takes each for a normal window, and Scale (or Glide, or Fade) zooms it open
// and closed on top of the animation the shell plays itself. Such a panel's
// open and close animations are claimed here, the way effects hand an
// animation to one another, so no effect plays them.
class LayerAnimations : public QObject
{
public:
    LayerAnimations();

private:
    void connectEffects();

    QPointer<KWin::EffectsHandler> m_effects;
};
