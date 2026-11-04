#!/usr/bin/env python3
"""Minimal QMP client for the app in the Simulator (the app gets -qemuargs "-qmp tcp:127.0.0.1:PORT,server=on,wait=off";
the Simulator app shares the Mac's network).

Usage: qmp.py HOST:PORT hmp "info registers"
       qmp.py HOST:PORT qmp query-status
"""
import json
import socket
import sys


def call(addr, kind, arg):
    host, port = addr.rsplit(":", 1)
    s = socket.create_connection((host, int(port)), timeout=10)
    f = s.makefile("rw")
    json.loads(f.readline())  # greeting
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n")
    f.flush()
    json.loads(f.readline())
    if kind == "hmp":
        msg = {"execute": "human-monitor-command", "arguments": {"command-line": arg}}
    else:
        msg = {"execute": arg}
    f.write(json.dumps(msg) + "\n")
    f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r:
            s.close()
            return r


if __name__ == "__main__":
    r = call(sys.argv[1], sys.argv[2], sys.argv[3])
    out = r.get("return", r)
    print(out if isinstance(out, str) else json.dumps(out))
