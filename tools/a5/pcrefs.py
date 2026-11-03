#!/usr/bin/env python3
"""pcrefs.py KERNEL DISASM.txt "string" [...]: find code that builds a string's address in an
llvm-objdump Thumb listing (ldr rX,[pc,#n] or movw/movt, then add rX, pc), or names it absolutely."""
import os, re, struct, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "imgtools"))
from macho import Macho
path, lst = sys.argv[1], sys.argv[2]
m = Macho(path); d = open(path, "rb").read()
def off(va): return next(fo + (va - vm) for _, vm, _, fo, fs, _ in m.segs if vm <= va < vm + fs)
def va(o): return next(vm + (o - fo) for _, vm, _, fo, fs, _ in m.segs if fo <= o < fo + fs and fs)
def u32(a): return struct.unpack_from("<I", d, off(a))[0]
want = {}
for s in sys.argv[3:]:
    o = d.find(s.encode())
    while d[o - 1] != 0:
        o -= 1
    want[va(o)] = s
    print("%s at %#x" % (s, va(o)))
t = open(lst).read().splitlines()
lo = {}
for i, l in enumerate(t):
    mm = re.match(r"\s*([0-9a-f]+):\s+(\S+)\s+(r\d+), (.*)", l)
    if not mm:
        continue
    a, op, rd, rest = int(mm.group(1), 16), mm.group(2), mm.group(3), mm.group(4)
    val = None
    if op.startswith("ldr") and "[pc, #" in rest:
        lit = int(re.search(r"@ 0x([0-9a-f]+)", rest).group(1), 16)
        val = u32(lit)
    elif op.startswith("movw"):
        lo[rd] = (int(rest.split("#")[1], 0), a)
        continue
    elif op.startswith("movt") and rd in lo:
        val = (int(rest.split("#")[1], 0) << 16) | lo[rd][0]
    if val is None:
        continue
    if val in want:
        print("%s: absolute at %#x" % (want[val], a))
    for j in range(i + 1, min(i + 10, len(t))):
        m2 = re.match(r"\s*([0-9a-f]+):\s+add\s+%s, pc" % rd, t[j])
        if m2:
            v = (val + int(m2.group(1), 16) + 4) & 0xffffffff
            if v in want:
                print("%s: ref at %#x" % (want[v], a))
            break
