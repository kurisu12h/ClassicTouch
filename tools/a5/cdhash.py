#!/usr/bin/env python3
"""cdhash.py FILE|DIR...: the CodeDirectory hash (what AMFI's trust caches hold) of each Mach-O slice, as
"HASH PATH[:arch]" lines; a directory is walked. For the A6's static trust cache (tools/a5/n41_trustcache.py,
docs/reports/a6-step1.md).

The CodeDirectory is the one in slot 0. ldid adds a SHA-256 alternate (slot 0x1000) beside a SHA-1 one there;
10.3.4's AMFI looks up the slot 0 hash: it_nandfmt ran with that in the trust cache, and a re-signed
mobileactivationd with only the alternate's hash added was not a platform binary ("unexpected exec of
non-platform binary", a6-step1.md 9). 14G61's own files have one SHA-1 directory."""
import hashlib, os, struct, sys

FAT, MH, LC_CODE_SIGNATURE = 0xCAFEBABE, 0xFEEDFACE, 0x1D


def slices(d):
    if len(d) >= 8 and struct.unpack_from(">I", d)[0] == FAT:
        for i in range(struct.unpack_from(">I", d, 4)[0]):
            cpu, sub, o, n = struct.unpack_from(">IIII", d, 8 + 20 * i)
            yield "%d.%d" % (cpu, sub), d[o:o + n]
    elif len(d) >= 28 and struct.unpack_from("<I", d)[0] == MH:
        yield "", d


def cdhash(m):
    ncmds, c = struct.unpack_from("<I", m, 16)[0], 28
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", m, c)
        if cmd == LC_CODE_SIGNATURE:
            so, sn = struct.unpack_from("<II", m, c + 8)
            blob = m[so:so + sn]
            if len(blob) < 12 or struct.unpack_from(">I", blob)[0] != 0xFADE0CC0:
                return None
            for k in range(struct.unpack_from(">I", blob, 8)[0]):
                t, o = struct.unpack_from(">II", blob, 12 + 8 * k)
                if t == 0:
                    n = struct.unpack_from(">I", blob, o + 4)[0]
                    cd = blob[o:o + n]
                    return hashlib.sha1(cd).hexdigest() if cd[37] == 1 else hashlib.sha256(cd).hexdigest()[:40]
        c += size
    return None


def scan(path, rel):
    try:
        with open(path, "rb") as f:
            head = f.read(4)
            if head not in (b"\xca\xfe\xba\xbe", b"\xce\xfa\xed\xfe"):
                return
            d = head + f.read()
    except OSError:
        return
    for arch, m in slices(d):
        h = cdhash(m)
        if h:
            print(h, rel + (":" + arch if arch else ""))


for top in sys.argv[1:]:
    if os.path.isdir(top):
        for root, dirs, files in os.walk(top):
            for n in files:
                p = os.path.join(root, n)
                if os.path.isfile(p) and not os.path.islink(p):
                    scan(p, os.path.relpath(p, top))
    else:
        scan(top, top)
