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

# position is 0-based on D-Bus, the shell wants Hyprland-style 1-based ids
assert [w["id"] for w in snap["workspaces"]] == [1, 2]
assert snap["workspaces"][1]["name"] == "Desktop 2", "unnamed desktops get a fallback label"
assert snap["current"] == 1
assert snap["activeOutput"] == "eDP-1"

wa, wb = snap["windows"]
assert wa["workspaceId"] == 2
assert wa["id"] == "{wA}" and wa["address"] == "{wA}" and wa["class"] == "foot"
# an empty desktop list means "on all desktops", so it must land on the current one
assert wb["workspaceId"] == 1 and wb["onAllDesktops"] is True
assert wa["onAllDesktops"] is False

# an unknown current uuid must not crash or invent a workspace
assert bridge.build_snapshot({}, desktops, "gone")["current"] == 1
assert bridge.build_snapshot({}, [], "gone")["current"] == 1

js = bridge.move_script("{w-1}", 3)
assert '"w-1"' in js and "want = 3" in js, js

print("ok")
