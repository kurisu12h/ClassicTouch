#!/usr/bin/env python3
"""mkelf.py KERNEL OUT.elf: wrap the kernelcache's __TEXT and __PRELINK_TEXT in an ELF32 ARM file so
llvm-objdump --start-address/--stop-address can disassemble any range (kexts included)."""
import os, struct, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "imgtools"))
from macho import Macho
m = Macho(sys.argv[1]); d = open(sys.argv[1], "rb").read()
segs = [s for s in m.segs if s[0] in ("__TEXT", "__PRELINK_TEXT")]
names = b"\0.shstrtab\0" + b"".join(s[0].encode() + b"\0" for s in segs)
body, shdrs, off = b"", [], 52
for s in segs:
    name, vm, _, fo, fs, _ = s
    shdrs.append((names.index(name.encode()), 1, 6, vm, off + len(body), fs))   # PROGBITS, ALLOC|EXEC
    body += d[fo:fo + fs]
stroff = off + len(body)
body += names
shoff = (off + len(body) + 3) & ~3
body += b"\0" * (shoff - off - len(body))
sh = struct.pack("<10I", *[0] * 10)
for nm, typ, flg, addr, o, sz in shdrs:
    sh += struct.pack("<10I", nm, typ, flg, addr, o, sz, 0, 0, 4, 0)
sh += struct.pack("<10I", 1, 3, 0, 0, stroff, len(names), 0, 0, 1, 0)
hdr = b"\x7fELF\x01\x01\x01" + b"\0" * 9 + struct.pack("<HHIIIIIHHHHHH", 2, 40, 1, 0, 0, shoff, 0x5000000, 52, 0, 0, 40, len(shdrs) + 2, len(shdrs) + 1)
open(sys.argv[2], "wb").write(hdr + body + sh)
