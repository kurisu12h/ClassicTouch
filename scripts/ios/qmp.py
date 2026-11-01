#!/usr/bin/env python3
"""极简 QMP 客户端，给模拟器里的 App 用（App 带 -qemuargs "-qmp tcp:127.0.0.1:端口,server=on,wait=off"，
模拟器 App 和 Mac 共用网络）。

用法：qmp.py 主机:端口 hmp "info registers"
      qmp.py 主机:端口 qmp query-status
"""
import json
import socket
import sys


def call(addr, kind, arg):
    host, port = addr.rsplit(":", 1)
    s = socket.create_connection((host, int(port)), timeout=10)
    f = s.makefile("rw")
    json.loads(f.readline())  # 问候
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
