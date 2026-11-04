#!/usr/bin/env python3
"""Name the user frames of a watchdog stackshot (bug_type 288, e.g. stacks+backboardd-*.ips) (a6-step1.md 13.2).

    stacksym.py CACHE STACKS.ips PROCNAME...

For each thread of each PROCNAME: its name and wait info, then up to 60 frames, a frame in the shared cache as
IMAGE:SYMBOL+off (the nearest name the image exports at or below it, cacheinfo.Cache), any other as IMAGE+off.
Private methods have no export, so a frame can land on the export before it: check against the image's own
disassembly (cache2elf.py) before trusting the name. CACHE: the device's dyld_shared_cache_armv7s (10.x) or armv7.
"""
import bisect, json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cacheinfo  # noqa: E402


def main(cache_path, ips, procs):
    cache = cacheinfo.Cache(cache_path)
    j = json.loads(open(ips).read().partition("\n")[2])    # line 1: the report header
    imgs = j["binaryImages"]
    cbase = cache.maps[0][0]
    order = sorted((a, p) for p, a in cache.images)
    starts = [a for a, _ in order]
    syms = {}

    def name(off):
        a = cbase + off
        i = bisect.bisect_right(starts, a) - 1
        if i < 0:
            return "S+%#x" % off
        base, path = order[i]
        if path not in syms:
            try:
                e = cache.exports(base)
            except Exception:
                e = {}
            syms[path] = sorted((v, k) for k, v in e.items())
        s = syms[path]
        k = bisect.bisect_right([v for v, _ in s], a - base) - 1
        sym = "%s+%#x" % (s[k][1], a - base - s[k][0]) if k >= 0 else "%#x" % (a - base)
        return "%s:%s" % (path.split("/")[-1], sym)

    for pid, p in j["processByPid"].items():
        if p.get("procname") not in procs:
            continue
        print("==", pid, p.get("procname"))
        for tid, t in p["threadById"].items():
            print(" t%s %s %s" % (tid, t.get("name", ""), t.get("waitInfo") or ""))
            for f in t.get("userFrames", [])[:60]:
                im = imgs[f[0]]
                print("     ", name(f[1]) if im[2] == "S" else "%s+%#x" % (im[2], f[1]))


if __name__ == "__main__":
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3:])
