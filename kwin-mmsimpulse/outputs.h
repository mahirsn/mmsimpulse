#pragma once

// A protocol event that names an output names the client's own wl_output
// object for it, so both protocols need the client's resources for an output,
// and to hear when a client binds one.

#include <wayland/display.h>
#include <wayland/output.h>
#include <wayland_server.h>
#include <workspace.h>

#include <QSet>
#include <QTimer>

#include <functional>
#include <memory>

namespace mms
{

inline QSet<wl_resource *> outputResources(KWin::LogicalOutput *output, wl_client *client)
{
    QSet<wl_resource *> resources;
    for (KWin::OutputInterface *o : KWin::waylandServer()->display()->outputs()) {
        if (o->handle() == output && !o->isRemoved()) {
            const auto list = o->clientResources(client);
            resources.unite(QSet<wl_resource *>(list.begin(), list.end()));
        }
    }
    return resources;
}

// The client's wl_output objects that still exist: a leave event may only name
// one of these, never one the client has already destroyed.
inline QSet<wl_resource *> liveOutputResources(wl_client *client)
{
    QSet<wl_resource *> resources;
    for (KWin::OutputInterface *o : KWin::waylandServer()->display()->outputs()) {
        const auto list = o->clientResources(client);
        resources.unite(QSet<wl_resource *>(list.begin(), list.end()));
    }
    return resources;
}

// Calls `changed` when outputs come or go, and when a client binds an output
// (the client may hold a window list from before it had that output).
inline void watchOutputs(QObject *context, std::function<void()> changed)
{
    auto watched = std::make_shared<QSet<KWin::OutputInterface *>>();
    auto scan = [context, changed, watched]() {
        for (KWin::OutputInterface *o : KWin::waylandServer()->display()->outputs()) {
            if (watched->contains(o))
                continue;
            watched->insert(o);
            QObject::connect(o, &KWin::OutputInterface::bound, context, [changed] {
                changed();
            });
            QObject::connect(o, &QObject::destroyed, context, [watched, o] {
                watched->remove(o);
            });
        }
        changed();
    };
    scan();
    // The output's wl_output global is made after the workspace announces it.
    auto later = [context, scan] {
        QTimer::singleShot(0, context, scan);
    };
    QObject::connect(KWin::workspace(), &KWin::Workspace::outputAdded, context, later);
    QObject::connect(KWin::workspace(), &KWin::Workspace::outputRemoved, context, later);
}

} // namespace mms
