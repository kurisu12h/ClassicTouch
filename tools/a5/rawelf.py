#!/usr/bin/env python3
"""rawelf.py BLOB BASE OUT.elf [ENTRY]: wrap a raw ARM image at BASE in an ELF32 with Thumb function-start
symbols (push {..,lr} / stmdb sp!,{..,lr}) so Ghidra finds the functions."""
import struct, sys
blob = open(sys.argv[1], "rb").read(); base = int(sys.argv[2], 16); out = sys.argv[3]
entry = int(sys.argv[4], 16) if len(sys.argv) > 4 else base
syms = [(entry, "entry")]
for i in range(0, len(blob) - 4, 2):
    h, h2 = struct.unpack_from("<HH", blob, i)
    ph = struct.unpack_from("<H", blob, i - 2)[0] if i >= 2 else 0
    if ((h & 0xff00) == 0xb500 or (h == 0xe92d and (h2 & 0x4000))) and (ph & 0xf800) not in (0xe800, 0xf000, 0xf800):
        syms.append((base + i + 1, "sub_%x" % (base + i)))
shstr = b"\0.shstrtab\0.symtab\0.strtab\0.text\0"
strtab = b"\0"; symtab = b"\0" * 16
for a, n in syms:
    symtab += struct.pack("<IIIBBH", len(strtab), a, 0, (1 << 4) | 2, 0, 1)
    strtab += n.encode() + b"\0"
body = blob + b"\0" * ((-len(blob)) % 4)
symoff = 52 + len(body); body += symtab
stroff = 52 + len(body); body += strtab
shsoff = 52 + len(body); body += shstr
body += b"\0" * ((-len(body)) % 4)
shoff = 52 + len(body)
sh = b"\0" * 40
sh += struct.pack("<10I", shstr.index(b".text"), 1, 7, base, 52, len(blob), 0, 0, 4, 0)
sh += struct.pack("<10I", shstr.index(b".symtab"), 2, 0, 0, symoff, len(symtab), 3, 1, 4, 16)
sh += struct.pack("<10I", shstr.index(b".strtab"), 3, 0, 0, stroff, len(strtab), 0, 0, 1, 0)
sh += struct.pack("<10I", 1, 3, 0, 0, shsoff, len(shstr), 0, 0, 1, 0)
phoff = shoff + len(sh)
ph = struct.pack("<8I", 1, 52, base, base, len(blob), len(blob), 7, 4)
hdr = b"\x7fELF\x01\x01\x01" + b"\0" * 9 + struct.pack("<HHIIIIIHHHHHH", 2, 40, 1, entry, phoff, shoff, 0x5000000, 52, 32, 1, 40, 5, 4)
open(out, "wb").write(hdr + body + sh + ph)
print(len(syms), "symbols")
