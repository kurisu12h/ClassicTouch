#!/usr/bin/env python3
"""Questions about an armv7 dyld shared cache (9.x, dyld_v1) without extracting it (report 3.17.4).

    cacheinfo.py CACHE exports IMAGE                 every name IMAGE exports (its export trie)
    cacheinfo.py CACHE binds NAME...                 which images bind NAME, from which library, weak or not
    cacheinfo.py CACHE methods IMAGE CLASS...        CLASS's instance (-) and class (+) methods, IMAGE exporting it
    cacheinfo.py CACHE selrefs SEL[,SEL...]          which images send SEL (their __objc_selrefs)

How the 9.3.5 GL front end's gaps were found: `exports` against contrib/gles-public/opengles.exports, `binds` for
who needs a missing one, `methods` for EAGLContext against the front end, `selrefs` for who sends the rest.
cache2elf.py turns one image into an ELF for Ghidra.
"""
import struct, sys

LOAD_DYLIBS = (0xc, 0x18, 0x1f, 0x80000018, 0x80000023)
DYLD_INFO = (0x22, 0x80000022)


class Cache:
    def __init__(self, path):
        self.d = d = open(path, "rb").read()
        mo, mc, io, ic = struct.unpack_from("<4I", d, 0x10)
        self.maps = [struct.unpack_from("<3Q", d, mo + 32 * i) for i in range(mc)]
        self.images = []
        for i in range(ic):
            a, _, _, po = struct.unpack_from("<3QI", d, io + 32 * i)
            self.images.append((d[po:d.index(b"\0", po)].decode(), a))

    def off(self, a):
        for addr, size, fo in self.maps:
            if addr <= a < addr + size:
                return a - addr + fo
        return None

    def u32(self, a):
        return struct.unpack_from("<I", self.d, self.off(a))[0]

    def cstr(self, a):
        o = self.off(a)
        return self.d[o:self.d.index(b"\0", o)].decode("latin1")

    def uleb(self, p):
        r = s = 0
        while True:
            b = self.d[p]; p += 1; r |= (b & 0x7f) << s; s += 7
            if b < 0x80:
                return r, p

    def sleb(self, p):
        r = s = 0
        while True:
            b = self.d[p]; p += 1; r |= (b & 0x7f) << s; s += 7
            if b < 0x80:
                return (r - (1 << s) if b & 0x40 else r), p

    def commands(self, base):
        h = self.off(base)
        if h is None:
            return
        c = h + 28
        for _ in range(struct.unpack_from("<I", self.d, h + 16)[0]):
            cmd, sz = struct.unpack_from("<II", self.d, c)
            yield cmd, c
            c += sz

    def base(self, image):
        return next(a for p, a in self.images if p == image)

    def exports(self, base):
        """{name: address offset from the image's header}"""
        info = next((struct.unpack_from("<10I", self.d, c + 8) for cmd, c in self.commands(base) if cmd in DYLD_INFO),
                    None)
        out = {}
        if not info or not info[9]:
            return out
        eo = info[8]

        def walk(node, prefix):
            p = eo + node
            tsz, q = self.uleb(p)
            if tsz:
                _, q2 = self.uleb(q)
                out[prefix] = self.uleb(q2)[0]
            p = q + tsz
            n = self.d[p]; p += 1
            for _ in range(n):
                e = self.d.index(b"\0", p); s = self.d[p:e].decode(); p = e + 1
                ch, p = self.uleb(p)
                walk(ch, prefix + s)
        walk(0, "")
        return out

    def binds(self, names):
        for path, base in self.images:
            libs, info = [], None
            for cmd, c in self.commands(base):
                if cmd in LOAD_DYLIBS:
                    no = struct.unpack_from("<I", self.d, c + 8)[0]
                    libs.append(self.d[c + no:self.d.index(b"\0", c + no)].decode())
                if cmd in DYLD_INFO:
                    info = struct.unpack_from("<10I", self.d, c + 8)
            if not info:
                continue
            for kind, (bo, bs) in (("bind", info[2:4]), ("weak", info[4:6]), ("lazy", info[6:8])):
                p, end, ordn = bo, bo + bs, 0
                while bs and p < end:
                    b = self.d[p]; p += 1
                    op, imm = b & 0xf0, b & 0x0f
                    if op in (0x10, 0x30):
                        ordn = imm
                    elif op == 0x20:
                        ordn, p = self.uleb(p)
                    elif op == 0x40:
                        e = self.d.index(b"\0", p); sym = self.d[p:e].decode(); p = e + 1
                        if sym in names:
                            lib = libs[ordn - 1] if 0 < ordn <= len(libs) else ordn
                            yield path, kind, sym, "weak-import" if imm & 1 else "strong", lib
                    elif op == 0x60:
                        p = self.sleb(p)[1]
                    elif op in (0x70, 0x80, 0xa0):
                        p = self.uleb(p)[1]
                    elif op == 0xc0:
                        p = self.uleb(self.uleb(p)[1])[1]

    def methods(self, cls):
        ml = self.u32((self.u32(cls + 16) & ~3) + 20)
        if not ml:
            return []
        ent, cnt = struct.unpack_from("<II", self.d, self.off(ml))
        return [self.cstr(self.u32(ml + 8 + k * (ent & 0xfffc))) for k in range(cnt)]

    def selrefs(self, want):
        for path, base in self.images:
            hits = set()
            for cmd, c in self.commands(base):
                if cmd != 1:
                    continue
                for k in range(struct.unpack_from("<I", self.d, c + 48)[0]):
                    s = c + 56 + 68 * k
                    if self.d[s:s + 16].split(b"\0")[0] == b"__objc_selrefs":
                        addr, size = struct.unpack_from("<II", self.d, s + 32)
                        for j in range(0, size, 4):
                            if self.off(self.u32(addr + j)) is not None and self.cstr(self.u32(addr + j)) in want:
                                hits.add(self.cstr(self.u32(addr + j)))
            if hits:
                yield path, sorted(hits)


def main(cache, what, *args):
    c = Cache(cache)
    if what == "exports":
        print("\n".join(sorted(c.exports(c.base(args[0])))))
    elif what == "binds":
        for row in c.binds(set(args)):
            print(*row)
    elif what == "methods":
        base = c.base(args[0])
        ex = c.exports(base)
        for cn in args[1:]:
            cls = base + ex["_OBJC_CLASS_$_" + cn]
            for m in c.methods(cls):
                print(cn, "-" + m)
            for m in c.methods(c.u32(cls)):
                print(cn, "+" + m)
    elif what == "selrefs":
        for path, hits in c.selrefs(set(args[0].split(","))):
            print(path, " ".join(hits))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(*sys.argv[1:])
