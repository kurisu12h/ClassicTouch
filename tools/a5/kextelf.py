#!/usr/bin/env python3
"""kextelf.py KERNEL OUT.elf BUNDLE_SUBSTR...: an ELF32 ARM file holding only the named prelinked kexts
(each kext's whole image, text and data), plus the kernel's exported symbols (nm) as absolute ELF symbols,
so a decompiler names the kernel calls. Kext images are written as PROGBITS ALLOC|EXEC|WRITE sections."""
import os, re, struct, subprocess, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "imgtools"))
from macho import Macho
path, out, want = sys.argv[1], sys.argv[2], sys.argv[3:]
m = Macho(path); d = open(path, "rb").read()
kx = subprocess.run([sys.executable, "-I", os.path.join(os.path.dirname(os.path.abspath(__file__)), "kexts.py"), path],
                    capture_output=True, text=True).stdout.split("\n")
items = []
for line in kx:
    p = line.split()
    if len(p) == 3 and any(w in p[2] for w in want):
        items.append((int(p[0], 16), int(p[1], 16), p[2]))
syms = []
for line in subprocess.run(["nm", "-n", path], capture_output=True, text=True).stdout.splitlines():
    p = line.split()
    if len(p) == 3 and p[1] in "tTdDsSbB":
        syms.append((int(p[0], 16), p[2], p[1] in "tT"))
shstr = b"\0.shstrtab\0.symtab\0.strtab\0"
secs = []
body = b""
for a, z, name in items:
    va_off = m.va2off(a)
    secs.append((len(shstr), a, 52 + len(body), z))
    shstr += name.encode() + b"\0"
    body += d[va_off:va_off + z]
    body += b"\0" * ((-len(body)) % 4)
# Function starts: Thumb `push {..., lr}` (0xb5xx) or `stmdb sp!, {..., lr}` (e92d 4xxx) at halfword
# alignment in each kext's __TEXT,__text; named sub_<addr> with the Thumb bit set.
for a, z, name in items:
    o = m.va2off(a)
    blob = d[o:o + z]
    # the kext's own Mach-O header: find __text in __TEXT
    import struct as _st
    ncmds = _st.unpack_from("<I", blob, 16)[0]; off = 28; tx = None
    for _ in range(ncmds):
        cmd, size = _st.unpack_from("<II", blob, off)
        if cmd == 1:
            nsect = _st.unpack_from("<I", blob, off + 48)[0]
            for k in range(nsect):
                so = off + 56 + 68 * k
                if blob[so:so + 16].rstrip(b"\0") == b"__text":
                    tx = _st.unpack_from("<II", blob, so + 32)
        off += size
    if not tx:
        continue
    ta, tz = tx
    prev_end = 0
    for i in range(ta - a, ta - a + tz - 2, 2):
        h = _st.unpack_from("<H", blob, i)[0]
        h2 = _st.unpack_from("<H", blob, i + 2)[0]
        if (h & 0xff00) == 0xb500 or (h == 0xe92d and (h2 & 0x4000)):
            # skip if previous halfword is a 32-bit instruction prefix (would be mid-instruction)
            ph = _st.unpack_from("<H", blob, i - 2)[0] if i >= 2 else 0
            if (ph & 0xf800) in (0xe800, 0xf000, 0xf800) and not (ph == 0xbf00):
                continue
            syms.append((a + i + 1, "sub_%x" % (a + i), True))
strtab = b"\0"; symtab = struct.pack("<IIIBBH", 0, 0, 0, 0, 0, 0)
def shndx(a):
    for k, (nm, sa, so, sz) in enumerate(secs):
        if sa <= (a & ~1) < sa + sz:
            return k + 1
    return 0xfff1
for a, n, fn in syms:
    symtab += struct.pack("<IIIBBH", len(strtab), a, 0, (1 << 4) | (2 if fn else 1), 0, shndx(a))
    strtab += n.encode() + b"\0"
symoff = 52 + len(body); body += symtab
stroff = 52 + len(body); body += strtab
shoff_rel = 52 + len(body); body += shstr
shsoff = shoff_rel
body += b"\0" * ((-len(body)) % 4)
shoff = 52 + len(body)
sh = struct.pack("<10I", *[0] * 10)
for nm, a, o, z in secs:
    sh += struct.pack("<10I", nm, 1, 7, a, o, z, 0, 0, 4, 0)
nsec = len(secs)
sh += struct.pack("<10I", shstr.index(b".symtab"), 2, 0, 0, symoff, len(symtab), nsec + 2, 1, 4, 16)
sh += struct.pack("<10I", shstr.index(b".strtab"), 3, 0, 0, stroff, len(strtab), 0, 0, 1, 0)
sh += struct.pack("<10I", 1, 3, 0, 0, shsoff, len(shstr), 0, 0, 1, 0)
# program headers after the section headers
phoff = shoff + len(sh)
ph = b"".join(struct.pack("<8I", 1, o, a, a, z, z, 7, 4) for nm, a, o, z in secs)
hdr = b"\x7fELF\x01\x01\x01" + b"\0" * 9 + struct.pack("<HHIIIIIHHHHHH", 2, 40, 1, 0, phoff, shoff, 0x5000000, 52, 32, nsec, 40, nsec + 4, nsec + 3)
open(out, "wb").write(hdr + body + sh + ph)
print(len(items), "kexts,", len(syms), "symbols ->", out)
for i in items: print("  %#x %#x %s" % i)
