#!/usr/bin/env python3
"""Minimal QMP client: enough to screendump the VM's framebuffer."""
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
