#!/usr/bin/env python3
"""fwfix.py BLOB BASE DIR: in Ghidra pseudocode under DIR, replace DAT_<addr> (a literal-pool word) with
the C string it points to (or its value), for a raw image loaded at BASE."""
import os, re, struct, sys
blob = open(sys.argv[1], "rb").read(); base = int(sys.argv[2], 16)
def word(a):
    o = a - base
    return struct.unpack_from("<I", blob, o)[0] if 0 <= o <= len(blob) - 4 else None
def cstr(a):
    o = a - base
    if not 0 <= o < len(blob):
        return None
    e = blob.find(b"\0", o, o + 300)
    s = blob[o:e] if e > o else b""
    if len(s) >= 3 and all(32 <= c < 127 or c in (9, 10) for c in s):
        return s.decode().replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')
    return None
pat = re.compile(r'DAT_([0-9a-f]{8})')
def rep(mm):
    v = word(int(mm.group(1), 16))
    if v is None:
        return mm.group(0)
    s = cstr(v)
    return '"%s"' % s if s else "0x%x" % v
for root, _, fs in os.walk(sys.argv[3]):
    for f in fs:
        if f.endswith(".c"):
            p = os.path.join(root, f); t = open(p).read()
            t = "\n".join(l for l in t.split("\n") if not l.startswith("// limitations"))
            open(p, "w").write(pat.sub(rep, t))
