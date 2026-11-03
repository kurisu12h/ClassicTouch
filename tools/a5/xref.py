#!/usr/bin/env python3
"""Find Thumb-2 code that computes a string's address with movw/movt + add rX, pc (the iOS 6+ PIC shape).

    xref.py KERNEL.mach "string"

Prints each referencing address. Segment table via imgtools/macho.py.
"""
import os, struct, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "imgtools"))
from macho import Macho  # noqa: E402


def imm16(hw1, hw2):
    return ((hw1 & 0xf) << 12) | (((hw1 >> 10) & 1) << 11) | (((hw2 >> 12) & 7) << 8) | (hw2 & 0xff)


def main(path, needle):
    m = Macho(path)
    data = m.data
    so = data.find(needle.encode())
    if so < 0:
        raise SystemExit("string not found")
    va_of = lambda off: next(vm + (off - fo) for _, vm, _, fo, fs, _ in m.segs if fo <= off < fo + fs)
    sva = va_of(so)
    print("string at %#x" % sva)
    for _, vmaddr, _, fileoff, filesize, _ in m.segs:
        seg = data[fileoff:fileoff + filesize]
        n = len(seg) - 12
        o = 0
        while o < n:
            hw1, hw2 = struct.unpack_from("<HH", seg, o)
            if hw1 & 0xfbf0 == 0xf240:                    # movw rd, #imm16
                rd, lo = (hw2 >> 8) & 0xf, imm16(hw1, hw2)
                for k in range(4, 14, 2):                 # movt within a few halfwords
                    h1, h2 = struct.unpack_from("<HH", seg, o + k)
                    if h1 & 0xfbf0 == 0xf2c0 and (h2 >> 8) & 0xf == rd:
                        for a in range(k + 4, k + 10, 2):
                            add = struct.unpack_from("<H", seg, o + a)[0]
                            if add == 0x4478 | (rd & 7) | ((rd & 8) << 4):
                                pc = vmaddr + o + a + 4
                                if ((imm16(h1, h2) << 16 | lo) + pc) & 0xffffffff == sva:
                                    print("xref %#x" % (vmaddr + o))
                        break
            # ldr rd, [pc, #imm8*4] ... add rd, pc: the literal holds the offset from the add's pc.
            if hw1 & 0xff78 == 0x4478 and hw1 & 0x80 == 0 or (hw1 & 0xff78) == 0x44f8:
                rd = (hw1 & 7) | ((hw1 >> 4) & 8)
                need = (sva - (vmaddr + o + 4)) & 0xffffffff
                for back in range(2, 40, 2):
                    if o - back < 0:
                        break
                    h = struct.unpack_from("<H", seg, o - back)[0]
                    if h & 0xf800 == 0x4800 and (h >> 8) & 7 == rd:
                        lit = ((vmaddr + o - back + 4) & ~3) + (h & 0xff) * 4
                        lo = lit - vmaddr
                        if 0 <= lo < len(seg) - 4 and struct.unpack_from("<I", seg, lo)[0] == need:
                            print("xref %#x (ldr+add pc)" % (vmaddr + o - back))
                        break
            o += 2


if __name__ == "__main__":
    main(*sys.argv[1:3])
