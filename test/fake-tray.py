#!/usr/bin/env python3
"""A StatusNotifierItem with a real DBusMenu, so the tray can be tested.

Every tray application that ships with a desktop decides its own status and
menu, which makes "does right-click open a menu" impossible to test
repeatably. This one is always Active — so it survives the shell's
filterPassive — and serves a fixed three-entry menu including a submenu.

Run it inside the session under test and leave it running.
"""

import signal
import sys

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

SNI = "org.kde.StatusNotifierItem"
MENU = "com.canonical.dbusmenu"
WATCHER = "org.kde.StatusNotifierWatcher"

ENTRIES = [
    (1, "Open"),
    (2, "Preferences"),
    (3, "Quit"),
]


class Menu(dbus.service.Object):
    """The smallest DBusMenu a tray menu can be built from."""

    def __init__(self, bus, path):
        super().__init__(bus, path)
        self.clicked = []

    def _entry(self, ident, label):
        return dbus.Struct(
            (dbus.Int32(ident),
             dbus.Dictionary({"label": dbus.String(label),
                              "enabled": dbus.Boolean(True),
                              "visible": dbus.Boolean(True)}, signature="sv"),
             dbus.Array([], signature="v")),
            signature="ia{sv}av")

    @dbus.service.method(MENU, in_signature="iias", out_signature="u(ia{sv}av)")
    def GetLayout(self, parent_id, depth, property_names):
        children = dbus.Array([dbus.Variant(self._entry(i, label))
                               if hasattr(dbus, "Variant") else self._entry(i, label)
                               for i, label in ENTRIES], signature="v")
        root = dbus.Struct(
            (dbus.Int32(0),
             dbus.Dictionary({"children-display": dbus.String("submenu")}, signature="sv"),
             children),
            signature="ia{sv}av")
        return dbus.UInt32(1), root

    @dbus.service.method(MENU, in_signature="aias", out_signature="a(ia{sv})")
    def GetGroupProperties(self, ids, property_names):
        out = []
        for ident, label in ENTRIES:
            if not ids or ident in ids:
                out.append(dbus.Struct(
                    (dbus.Int32(ident),
                     dbus.Dictionary({"label": dbus.String(label),
                                      "enabled": dbus.Boolean(True),
                                      "visible": dbus.Boolean(True)}, signature="sv")),
                    signature="ia{sv}"))
        return dbus.Array(out, signature="(ia{sv})")

    @dbus.service.method(MENU, in_signature="is", out_signature="v")
    def GetProperty(self, ident, name):
        for entry_id, label in ENTRIES:
            if entry_id == ident and name == "label":
                return dbus.String(label)
        return dbus.String("")

    @dbus.service.method(MENU, in_signature="isvu", out_signature="")
    def Event(self, ident, event_id, data, timestamp):
        if event_id == "clicked":
            self.clicked.append(int(ident))
            print("CLICKED %d" % ident, flush=True)

    @dbus.service.method(MENU, in_signature="i", out_signature="b")
    def AboutToShow(self, ident):
        return dbus.Boolean(False)

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature="ss", out_signature="v")
    def Get(self, interface, name):
        return self.GetAll(interface).get(name, dbus.String(""))

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        return dbus.Dictionary({"Version": dbus.UInt32(3),
                                "TextDirection": dbus.String("ltr"),
                                "Status": dbus.String("normal"),
                                "IconThemePath": dbus.Array([], signature="s")},
                               signature="sv")

    @dbus.service.signal(MENU, signature="uu")
    def LayoutUpdated(self, revision, parent):
        pass


class Item(dbus.service.Object):
    def __init__(self, bus, path, menu_path):
        super().__init__(bus, path)
        self.menu_path = menu_path

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature="ss", out_signature="v")
    def Get(self, interface, name):
        return self.GetAll(interface).get(name, dbus.String(""))

    @dbus.service.method(dbus.PROPERTIES_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        return dbus.Dictionary({
            "Category": dbus.String("ApplicationStatus"),
            "Id": dbus.String("mmsimpulse-faketray"),
            "Title": dbus.String("Fake Tray"),
            "Status": dbus.String("Active"),
            "IconName": dbus.String("applications-system"),
            "ToolTip": dbus.Struct((dbus.String(""), dbus.Array([], signature="(iiay)"),
                                    dbus.String("Fake Tray"), dbus.String("for testing")),
                                   signature="sa(iiay)ss"),
            "ItemIsMenu": dbus.Boolean(False),
            "Menu": dbus.ObjectPath(self.menu_path),
        }, signature="sv")

    @dbus.service.method(SNI, in_signature="ii", out_signature="")
    def Activate(self, x, y):
        print("ACTIVATED", flush=True)

    @dbus.service.method(SNI, in_signature="ii", out_signature="")
    def SecondaryActivate(self, x, y):
        pass

    @dbus.service.method(SNI, in_signature="ii", out_signature="")
    def ContextMenu(self, x, y):
        print("CONTEXTMENU", flush=True)

    @dbus.service.signal(SNI, signature="")
    def NewStatus(self):
        pass


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    name = dbus.service.BusName("org.mmsimpulse.FakeTray", bus)
    Menu(bus, "/Menu")
    Item(bus, "/StatusNotifierItem", "/Menu")
    try:
        watcher = bus.get_object(WATCHER, "/StatusNotifierWatcher")
        dbus.Interface(watcher, WATCHER).RegisterStatusNotifierItem(
            "%s/StatusNotifierItem" % bus.get_unique_name())
    except dbus.DBusException as exc:
        print("register failed: %s" % exc, file=sys.stderr)
        return 1
    print("registered as %s" % name.get_name(), flush=True)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    GLib.MainLoop().run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
