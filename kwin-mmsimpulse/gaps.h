#pragma once

#include <QObject>
#include <QPointer>
#include <QList>

namespace KWin
{
class Window;
}

// Hyprland's gaps on KWin's quick tiles (halves and quarters): KWin builds
// them with no padding; this gives each one the padding mmsimpulse writes to
// kwinrc [mmsimpulse] QuickTileGap. A tile's padding is a full gap at the
// screen edges and half of it on each side between two tiles.
class QuickTileGaps : public QObject
{
public:
    QuickTileGaps();

private:
    void reload();
    void watch(KWin::Window *window);
    void pad(QObject *root);

    qreal m_gap = 0;
    QList<QPointer<QObject>> m_roots;
};
