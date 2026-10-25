#pragma once

#include <QHash>
#include <QList>
#include <QObject>
#include <QPair>
#include <QSet>

struct wl_client;
struct wl_global;

namespace KWin
{
class LogicalOutput;
class VirtualDesktop;
}

// ext_workspace_manager_v1: KWin's virtual desktops as workspaces, so a bar
// can show and switch them.
//
// The desktops are one pool that every monitor shows from, as in the shell's
// own bar. With per-output virtual desktops each monitor is a workspace group
// holding every desktop, active where that monitor shows it, and activating
// one shows it on that monitor. The KWin script keeps a desktop on one monitor
// at a time: asking for one another monitor shows moves the focus there.
// Without per-output desktops every monitor shows the same desktop, and there
// is one group on all of them.
class ExtWorkspaces : public QObject
{
public:
    ExtWorkspaces();
    ~ExtWorkspaces() override;

    struct Group;
    struct Space;
    struct Manager;

    void forget(Manager *manager);
    void activate(KWin::LogicalOutput *group, KWin::VirtualDesktop *desktop);

private:
    // What every client is brought to on a refresh. A group is keyed by its
    // monitor, or by null for the one group of all monitors.
    struct Model
    {
        QList<KWin::LogicalOutput *> groups;
        QHash<KWin::LogicalOutput *, QList<KWin::LogicalOutput *>> groupOutputs;
        QList<KWin::VirtualDesktop *> desktops;
        QSet<QPair<KWin::LogicalOutput *, KWin::VirtualDesktop *>> active;
    };

    static void bind(wl_client *client, void *data, uint32_t version, uint32_t id);
    void watchDesktop(KWin::VirtualDesktop *desktop);
    void refresh();
    Model model() const;
    void sync(Manager *manager);

    wl_global *m_global = nullptr;
    QList<Manager *> m_managers;
    Model m_model;
};
