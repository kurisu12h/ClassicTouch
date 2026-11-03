#!/usr/bin/env python3
"""Drive QEMU's QMP socket (-qmp unix:SOCK,server,nowait): run human-monitor commands at set times.

    qmon.py SOCK OUTDIR T1 [T2 ...]

At each time (seconds after connecting) it saves a screendump OUTDIR/shot-T.png and appends to
OUTDIR/pipe.txt the A5 DisplayPipe0's global block, its two UI layers and their H4P tables (xp). Times must increase.
"""
import json, os, socket, sys, time

PIPE0 = 0x3a100000            # S5L8940_DISP_PIPE0_BASE
DUMPS = [(PIPE0 + 0x1000, 32), (PIPE0 + 0x4000, 48), (PIPE0 + 0x5000, 48)]


class QMP:
    def __init__(self, path):
        for _ in range(100):
            try:
                self.s = socket.socket(socket.AF_UNIX)
                self.s.connect(path)
                break
            except OSError:
                time.sleep(0.05)
        self.f = self.s.makefile("rw")
        json.loads(self.f.readline())
        self.cmd("qmp_capabilities")

    def cmd(self, name, **args):
        self.f.write(json.dumps({"execute": name, "arguments": args}) + "\n")
        self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if "return" in r or "error" in r:
                return r

    def hmp(self, line):
        return self.cmd("human-monitor-command", **{"command-line": line}).get("return", "")


def main(sock, out, *times):
    q = QMP(sock)
    t0 = time.time()
    with open(os.path.join(out, "pipe.txt"), "w") as log:
        for t in map(float, times):
            time.sleep(max(0, t0 + t - time.time()))
            ppm = os.path.join(out, "shot-%g.ppm" % t)
            q.hmp("screendump " + ppm)
            log.write("== %gs\n" % t)
            for base, n in DUMPS:
                log.write(q.hmp("xp /%dwx %#x" % (n, base)))
            # each UI layer's table (H4P +0x98), when there is one
            for layer in (0, 1):
                tbl = q.hmp("xp /1wx %#x" % (PIPE0 + 0x4098 + layer * 0x1000)).split()
                if len(tbl) > 1 and int(tbl[1], 16):
                    log.write("table %d\n" % layer + q.hmp("xp /64wx %s" % tbl[1]))
            log.flush()
    try:
        from PIL import Image
        for t in map(float, times):
            ppm = os.path.join(out, "shot-%g.ppm" % t)
            if os.path.exists(ppm):
                im = Image.open(ppm)
                im.save(ppm[:-4] + ".png")
                os.remove(ppm)
                print("%s %s" % (os.path.basename(ppm[:-4]), im.getextrema()))
    except ImportError:
        pass


if __name__ == "__main__":
    main(*sys.argv[1:])
