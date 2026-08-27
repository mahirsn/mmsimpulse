#!/usr/bin/env python3
"""Minimal QMP client: screendump the framebuffer, and drive the guest's mouse.

Input goes through the virtio tablet QEMU gives the guest, so the guest sees
ordinary hardware events. That is the only way to click a Wayland surface in
there: stock KWin does not offer org_kde_kwin_fake_input, and Xwayland's XTEST
never reaches Wayland clients like the shell.
"""
import json
import socket
import sys
import time


def main():
    sock_path, command, *args = sys.argv[1:]
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(20)
    s.connect(sock_path)
    f = s.makefile("rw", encoding="utf-8", newline="\n")
    f.readline()                       # greeting
    send(f, {"execute": "qmp_capabilities"})

    if command == "screendump":
        target = args[0]
        send(f, {"execute": "screendump", "arguments": {"filename": target}})
        # screendump returns before the file is fully written on some builds.
        time.sleep(0.5)
    elif command in ("move", "click"):
        # QEMU's absolute axes are 0..32767 across the whole screen.
        x, y, width, height = (int(n) for n in args[:4])
        events = [{"type": "abs", "data": {"axis": "x", "value": x * 32767 // width}},
                  {"type": "abs", "data": {"axis": "y", "value": y * 32767 // height}}]
        send(f, {"execute": "input-send-event", "arguments": {"events": events}})
        if command == "click":
            button = args[4] if len(args) > 4 else "left"
            time.sleep(0.2)
            for down in (True, False):
                send(f, {"execute": "input-send-event", "arguments": {"events": [
                    {"type": "btn", "data": {"down": down, "button": button}}]}})
                time.sleep(0.1)
    elif command == "type":
        # Only what a password or a search box needs; QEMU wants qcodes, not text.
        for char in args[0]:
            qcode = {" ": "spc", ".": "dot", "-": "minus", "_": "shift-minus",
                     "\n": "ret"}.get(char, char)
            send(f, {"execute": "send-key",
                     "arguments": {"keys": [{"type": "qcode", "data": qcode}]}})
            time.sleep(0.05)
    elif command in ("keydown", "keyup"):
        # Held modifiers: send-key always releases, which is no use for Alt+Tab.
        send(f, {"execute": "input-send-event", "arguments": {"events": [
            {"type": "key", "data": {"down": command == "keydown",
                                     "key": {"type": "qcode", "data": args[0]}}}]}})
    elif command == "key":
        send(f, {"execute": "send-key",
                 "arguments": {"keys": [{"type": "qcode", "data": name}
                                        for name in args]}})
    else:
        send(f, {"execute": command})


def send(f, msg):
    f.write(json.dumps(msg) + "\n")
    f.flush()
    while True:
        line = f.readline()
        if not line:
            raise SystemExit("qmp: connection closed")
        reply = json.loads(line)
        if "event" in reply:
            continue
        if "error" in reply:
            raise SystemExit("qmp: " + reply["error"]["desc"])
        return reply


if __name__ == "__main__":
    main()
