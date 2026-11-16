#include "gaps.h"

#include <main.h>
#include <window.h>
#include <workspace.h>

using namespace KWin;

QuickTileGaps::QuickTileGaps()
{
    connect(workspace(), &Workspace::windowAdded, this, &QuickTileGaps::watch);
    connect(workspace(), &Workspace::configChanged, this, &QuickTileGaps::reload);
    const auto windows = workspace()->windows();
    for (Window *window : windows) {
        watch(window);
    }
    reload();
}

void QuickTileGaps::reload()
{
    m_gap = kwinApp()->config()->group(QStringLiteral("mmsimpulse")).readEntry("QuickTileGap", 0.0);
    for (const QPointer<QObject> &root : std::as_const(m_roots)) {
        if (root) {
            root->setProperty("padding", m_gap);
        }
    }
}

void QuickTileGaps::watch(Window *window)
{
    // Tile is not in KWin's installed headers; as a QObject its class and
    // padding are reachable. A quick tile's QObject parent is the output's
    // QuickRootTile for that desktop, whose padding goes to all its tiles.
    connect(window, &Window::tileChanged, this, [this, window]() {
        QObject *tile = window->property("tile").value<QObject *>();
        if (tile && tile->parent() && tile->parent()->inherits("KWin::QuickRootTile")) {
            pad(tile->parent());
        }
    });
}

void QuickTileGaps::pad(QObject *root)
{
    if (!m_roots.contains(root)) {
        m_roots.removeAll(nullptr);
        m_roots.append(root);
    }
    if (root->property("padding").toReal() != m_gap) {
        root->setProperty("padding", m_gap);
    }
}
