#!/usr/bin/env python3
"""pcfix.py KERNEL DIR: rewrite Ghidra pseudocode files in DIR in place, resolving the Thumb PIC idiom
`DAT_<lit> + -0x<k>` (ldr from a literal pool, add pc) to the string or address it computes."""
import os, re, sys, struct
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "imgtools"))
from macho import Macho
m = Macho(sys.argv[1]); d = open(sys.argv[1], "rb").read()
def u32(va):
    try:
        o = m.va2off(va)
        return None if o is None else struct.unpack_from("<I", d, o)[0]
    except Exception:
        return None
def cstr(va):
    try:
        o = m.va2off(va)
        if o is None: return None
    except Exception:
        return None
    e = d.find(b"\0", o, o + 400)
    s = d[o:e] if e > 0 else b""
    if len(s) >= 3 and all(32 <= c < 127 or c in (9, 10) for c in s):
        return s.decode().replace("\n", "\\n").replace('"', '\\"')
    return None
pat = re.compile(r'(?:\(int\)&)?DAT_([0-9a-f]{8}) \+ (-?)0x([0-9a-f]+)')
def rep(mm):
    lit = u32(int(mm.group(1), 16))
    if lit is None:
        return mm.group(0)
    k = int(mm.group(3), 16)
    va = (lit - k if mm.group(2) else lit + k) & 0xffffffff
    s = cstr(va)
    return '"%s"' % s if s else "0x%08x" % va
for root, _, fs in os.walk(sys.argv[2]):
  for f in fs:
    if not f.endswith(".c"):
        continue
    p = os.path.join(root, f)
    t = open(p).read()
    open(p, "w").write(pat.sub(rep, t))
