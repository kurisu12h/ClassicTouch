#!/usr/bin/env python3
"""cache2elf.py CACHE IMAGE OUT.elf: one image of an armv7 dyld shared cache as an ELF32 Ghidra can load.

Each of the image's segments but __LINKEDIT becomes an allocated section at its cache address (so its own C
strings, CFStrings and code line up), with the image's exports as symbols, plus Thumb function starts found as
in rawelf.py. Selector names and other images' data stay outside; resolve those addresses against the cache.
"""
import struct, sys

cache, image, out = sys.argv[1:4]
d = open(cache, "rb").read()
mo, mc, io, ic = struct.unpack_from("<4I", d, 0x10)
maps = [struct.unpack_from("<3Q", d, mo + 32 * i) for i in range(mc)]


def off(a):
    for addr, size, fo in maps:
        if addr <= a < addr + size:
            return a - addr + fo
    raise KeyError(hex(a))


def uleb(p):
    r = s = 0
    while True:
        b = d[p]; p += 1; r |= (b & 0x7f) << s; s += 7
        if b < 0x80:
            return r, p


for i in range(ic):
    a, _, _, po = struct.unpack_from("<3QI", d, io + 32 * i)
    if d[po:d.index(b"\0", po)].decode() == image:
        base = a
        break
else:
    sys.exit("no %s in the cache" % image)
h = off(base)
ncmds = struct.unpack_from("<I", d, h + 16)[0]
c, segs, exp = h + 28, [], None
for _ in range(ncmds):
    cmd, sz = struct.unpack_from("<II", d, c)
    if cmd == 1:
        name = d[c + 8:c + 24].split(b"\0")[0].decode()
        vmaddr, vmsize = struct.unpack_from("<II", d, c + 24)
        if name != "__LINKEDIT" and vmsize:
            segs.append((name, vmaddr, d[off(vmaddr):off(vmaddr) + vmsize], 5 if name == "__TEXT" else 6))
    if cmd in (0x22, 0x80000022):
        exp = struct.unpack_from("<2I", d, c + 40)
    c += sz
syms = []
if exp:
    def walk(node, prefix):
        p = exp[0] + node
        tsz, q = uleb(p)
        if tsz:
            _, q2 = uleb(q)
            addr, _ = uleb(q2)
            syms.append((base + addr, prefix))
        p = q + tsz
        n = d[p]; p += 1
        for _ in range(n):
            e = d.index(b"\0", p); s = d[p:e].decode(); p = e + 1
            ch, p = uleb(p)
            walk(ch, prefix + s)
    walk(0, "")
named = {a & ~1 for a, _ in syms}
text = next(s for s in segs if s[0] == "__TEXT")
blob, tbase = text[2], text[1]
for i in range(2, len(blob) - 4, 2):
    hw, hw2 = struct.unpack_from("<HH", blob, i)
    ph = struct.unpack_from("<H", blob, i - 2)[0]
    if ((hw & 0xff00) == 0xb500 or (hw == 0xe92d and (hw2 & 0x4000))) and (ph & 0xf800) not in (0xe800, 0xf000, 0xf800):
        if tbase + i not in named:
            syms.append((tbase + i + 1, "sub_%x" % (tbase + i)))

shstr = b"\0.shstrtab\0.symtab\0.strtab\0" + b"".join(s[0].encode() + b"\0" for s in segs)
strtab, symtab = b"\0", b"\0" * 16
for a, n in syms:
    sec = next((k + 1 for k, s in enumerate(segs) if s[1] <= (a & ~1) < s[1] + len(s[2])), 0)
    symtab += struct.pack("<IIIBBH", len(strtab), a, 0, (1 << 4) | (2 if sec == 1 else 1), 0, sec)
    strtab += n.encode() + b"\0"
body, offs = b"", []
for s in segs:
    offs.append(52 + len(body))
    body += s[2] + b"\0" * ((-len(s[2])) % 4)
symoff = 52 + len(body); body += symtab
stroff = 52 + len(body); body += strtab
shsoff = 52 + len(body); body += shstr
body += b"\0" * ((-len(body)) % 4)
shoff = 52 + len(body)
sh = b"\0" * 40
for k, s in enumerate(segs):
    sh += struct.pack("<10I", shstr.index(s[0].encode() + b"\0"), 1, 7 if s[3] == 5 else 3, s[1], offs[k],
                      len(s[2]), 0, 0, 4, 0)
nseg = len(segs)
sh += struct.pack("<10I", shstr.index(b".symtab"), 2, 0, 0, symoff, len(symtab), nseg + 2, 1, 4, 16)
sh += struct.pack("<10I", shstr.index(b".strtab"), 3, 0, 0, stroff, len(strtab), 0, 0, 1, 0)
sh += struct.pack("<10I", 1, 3, 0, 0, shsoff, len(shstr), 0, 0, 1, 0)
phoff = shoff + len(sh)
ph = b"".join(struct.pack("<8I", 1, offs[k], s[1], s[1], len(s[2]), len(s[2]), s[3], 4) for k, s in enumerate(segs))
hdr = b"\x7fELF\x01\x01\x01" + b"\0" * 9 + struct.pack("<HHIIIIIHHHHHH", 2, 40, 1, tbase, phoff, shoff, 0x5000000,
                                                       52, 32, nseg, 40, nseg + 4, nseg + 3)
open(out, "wb").write(hdr + body + sh + ph)
print("%s: %s, %d symbols" % (out, ", ".join("%s %#x+%#x" % (s[0], s[1], len(s[2])) for s in segs), len(syms)))
