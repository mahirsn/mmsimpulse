#!/usr/bin/env python3
"""Self-check for mmsimpulse-kwin-bridge's snapshot logic. Run: python3 test_bridge.py"""
import importlib.machinery
import importlib.util
import pathlib

src = pathlib.Path(__file__).with_name("bin") / "mmsimpulse-kwin-bridge"
# the bridge is an extensionless executable, so the loader must be named explicitly
spec = importlib.util.spec_from_file_location(
    "bridge", src, loader=importlib.machinery.SourceFileLoader("bridge", str(src)))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

n = bridge.normalize_uuid
assert n("{abc}") == "{abc}"
assert n("abc") == "{abc}", "unbraced ids from the script must match WindowsRunner.Run's braced form"

desktops = [(0, "u1", "One"), (1, "u2", "")]
snap = bridge.build_snapshot(
    {"windows": [
        {"id": "wA", "appId": "foot", "desktops": ["u2"]},
        {"id": "{wB}", "appId": "zen", "desktops": []},
    ], "activeOutput": "eDP-1"},
    desktops, "u1")
per_output = bridge.build_snapshot(
    {"outputs": [{"name": "DP-1", "currentDesktop": "u2"},
                 {"name": "DP-2", "currentDesktop": "gone"}]}, desktops, "u1")
# an unknown per-output desktop falls back to the global current one
assert per_output["outputs"] == [{"name": "DP-1", "current": 2},
                                 {"name": "DP-2", "current": 1}]

# position is 0-based on D-Bus, the shell wants Hyprland-style 1-based ids
assert [w["id"] for w in snap["workspaces"]] == [1, 2]
assert snap["workspaces"][1]["name"] == "Desktop 2", "unnamed desktops get a fallback label"
assert snap["current"] == 1
assert snap["activeOutput"] == "eDP-1"
assert snap["outputs"] == []
# the skin's non-Hyprland path reads niri's field names
assert [w["is_active"] for w in snap["workspaces"]] == [True, False]
assert snap["workspaces"][0]["idx"] == 1 and snap["workspaces"][0]["output"] == ""

wa, wb = snap["windows"]
assert wa["workspaceId"] == 2
assert wa["id"] == "{wA}" and wa["address"] == "{wA}" and wa["class"] == "foot"
assert wa["focused"] is False
# the overview reads windows in `hyprctl clients -j` shape
assert wa["at"] == [0, 0] and wa["size"] == [0, 0] and wa["floating"] is True
assert wa["workspace"] == {"id": 2, "name": "Desktop 2"}
assert wb["workspace"]["name"] == "One"
# an empty desktop list means "on all desktops", so it must land on the current one
assert wb["workspaceId"] == 1 and wb["onAllDesktops"] is True
assert wa["onAllDesktops"] is False

# an unknown current uuid must not crash or invent a workspace
assert bridge.build_snapshot({}, desktops, "gone")["current"] == 1
assert bridge.build_snapshot({}, [], "gone")["current"] == 1

js = bridge.window_script("{w-1}", "move", "3")
assert '"w-1"' in js and "x11DesktopNumber === 3" in js, js
assert "workspace.activeWindow = w;" in bridge.window_script("w-1", "activate")
assert "w.closeWindow();" in bridge.window_script("w-1", "close")
try:
    bridge.window_script("w-1", "explode")
except ValueError:
    pass
else:
    raise AssertionError("an unknown action must not silently produce a script")

print("ok")
