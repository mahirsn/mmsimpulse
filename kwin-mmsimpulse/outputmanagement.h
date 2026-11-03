#pragma once

#include <QList>
#include <QObject>

struct wl_client;
struct wl_global;

namespace KWin
{
class BackendOutput;
}

// zwlr_output_manager_v1: the screens with their modes, position, scale and
// rotation, and a way to change them (wlr-randr, kanshi, a shell's display
// page). Changes go through KWin's own output configuration, as KDE's display
// settings do; a test is checked the same way but cannot ask the driver.
class OutputManagement : public QObject
{
public:
    OutputManagement();
    ~OutputManagement() override;

    struct Manager;
    struct Head;

    void forget(Manager *manager);
    uint32_t serial() const
    {
        return m_serial;
    }

private:
    static void bind(wl_client *client, void *data, uint32_t version, uint32_t id);
    void watch(KWin::BackendOutput *output);
    void schedule();
    void syncAll();
    void sync(Manager *manager);

    wl_global *m_global = nullptr;
    QList<Manager *> m_managers;
    uint32_t m_serial = 1;
    bool m_pending = false;
};
