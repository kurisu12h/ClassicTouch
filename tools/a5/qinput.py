#!/usr/bin/env python3
"""Scripted input for the n78 machine over QMP (-qmp unix:SOCK,server,nowait): touches and buttons at set times.

    qinput.py SOCK OUTDIR ACTION...

Each ACTION is T:WHAT, T in seconds after connecting:
    T:shot              screendump OUTDIR/in-T.png
    T:key:K[:MS]        press and release QEMU key K (h = Home, l = hold/power, equal/minus = volume) for MS ms
    T:chord:K1+K2..[:MS]  press keys together, release together after MS ms (default 1500): equal+minus+l is
                        iOS 10's sysdiagnose, whose stackshot of every process lands in the data volume's logs
    T:tap:X,Y[,MS]      one finger down at panel pixel X,Y (640x1136, top-left origin), held MS ms (default 300)
    T:swipe:X0,Y0,X1,Y1[,MS]   drag from X0,Y0 to X1,Y1 over MS ms (default 600)
Touches go through input-send-event as an absolute pointer (abs 0..32767) plus the left button, which the
machine turns into one finger on its multi-touch sensor (hw/arm/ipod_touch_5g.c n78_mouse_event).
"""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qmon import QMP  # noqa: E402

W, H = 640, 1136


def pointer(q, x, y, down=None):
    ev = [{"type": "abs", "data": {"axis": "x", "value": int(x * 32767 / (W - 1))}},
          {"type": "abs", "data": {"axis": "y", "value": int(y * 32767 / (H - 1))}}]
    if down is not None:
        ev.append({"type": "btn", "data": {"down": down, "button": "left"}})
    q.cmd("input-send-event", events=ev)


def shot(q, out, t):
    ppm = os.path.join(out, "in-%g.ppm" % t)
    q.hmp("screendump " + ppm)
    try:
        from PIL import Image
        Image.open(ppm).save(ppm[:-4] + ".png")
        os.unlink(ppm)
    except Exception:
        pass


def main(sock, out, *actions):
    q = QMP(sock)
    t0 = time.time()
    for a in actions:
        t, what, *rest = a.split(":")
        t = float(t)
        time.sleep(max(0, t0 + t - time.time()))
        if what == "shot":
            shot(q, out, t)
        elif what == "key":
            ms = float(rest[1]) if len(rest) > 1 else 150
            q.cmd("input-send-event", events=[{"type": "key", "data": {"down": True, "key": {"type": "qcode", "data": rest[0]}}}])
            time.sleep(ms / 1000)
            q.cmd("input-send-event", events=[{"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": rest[0]}}}])
        elif what == "chord":
            keys = rest[0].split("+")
            ms = float(rest[1]) if len(rest) > 1 else 1500
            q.cmd("input-send-event", events=[{"type": "key", "data": {"down": True, "key": {"type": "qcode", "data": k}}}
                                              for k in keys])
            time.sleep(ms / 1000)
            q.cmd("input-send-event", events=[{"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": k}}}
                                              for k in keys])
        elif what == "tap":
            v = list(map(float, rest[0].split(",")))
            x, y = v[:2]
            ms = v[2] if len(v) > 2 else 300
            pointer(q, x, y, True)
            for _ in range(max(int(ms / 50), 1)):     # the sensor reports a held finger frame by frame
                time.sleep(0.05)
                pointer(q, x, y)
            pointer(q, x, y, False)
        elif what == "swipe":
            v = list(map(float, rest[0].split(",")))
            x0, y0, x1, y1 = v[:4]
            ms = v[4] if len(v) > 4 else 600
            steps = max(int(ms / 16), 2)
            pointer(q, x0, y0, True)
            for i in range(1, steps + 1):
                time.sleep(ms / 1000 / steps)
                pointer(q, x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps)
            time.sleep(0.05)
            pointer(q, x1, y1, False)
        print("%.1fs %s" % (time.time() - t0, a), flush=True)


if __name__ == "__main__":
    main(*sys.argv[1:])
