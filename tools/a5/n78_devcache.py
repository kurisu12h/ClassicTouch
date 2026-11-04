#!/usr/bin/env python3
"""Mark a 9.x or 10.x shared cache as a development cache, so dyld lets files on disk override cached dylibs.

    n78_devcache.py CACHE      (System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7 on a mounted system
                                volume, _armv7s on the A6's 10.3.4; edited in place, owner and mode kept)

dyld-433.8 (14G61) has the same test in loadPhase5 as dyld-390 (docs/reports/a6-step1.md 9).

dyld-390 (13G36) loads a file in place of the cached image of the same path only when the comm page's
development-firmware bit (0xffff4084 bit 0, PE_i_can_has_debugger: kboot forces /chosen/debug-enabled) is set and
the cache header's cacheType (+0x68, u64) is 0, development (dyld::loadPhase5); 13G36 ships 1. The old switch file
enable-dylibs-to-override-cache only picks a .development file over the production one (openSharedCacheFile).
That is what the GL front end needs: OpenGLES exists only in the cache.

The header is on the cache's first code page, which dyld maps executable and compares with what read() gave
(mapSharedCache, "mmap() page compare failed"), so the code directory's slot 0 gets the edited page's hash too.
The cache's signature is ad hoc (CodeDirectory flags 0x2, an empty CMS blob), so the new CDHash is not in the
kernel's trust cache either way; on 9.x the kboot boot-args amfi_allow_any_signature=1 cs_enforcement_disable=1
are what let it map. 10.x's AMFI wants the CDHash in a trust cache: it is printed last, as "HASH PATH" the way
cdhash.py prints them, for n41_trustcache.py.
"""
import hashlib, struct, sys

CACHE_TYPE = 0x68
CSMAGIC_EMBEDDED_SIGNATURE, CSMAGIC_CODEDIRECTORY = 0xFADE0CC0, 0xFADE0C02


def main(path):
    with open(path, "r+b") as f:
        head = f.read(0x98)
        if head[:16] not in (b"dyld_v1   armv7\0", b"dyld_v1  armv7s\0") or \
                struct.unpack_from("<I", head, 0x10)[0] < CACHE_TYPE + 8:
            sys.exit("%s: not an armv7 or armv7s cache with a cacheType field" % path)
        cs_off = struct.unpack_from("<Q", head, 0x28)[0]
        f.seek(cs_off)
        sb = f.read(12)
        magic, _, count = struct.unpack(">III", sb)
        if magic != CSMAGIC_EMBEDDED_SIGNATURE:
            sys.exit("no embedded signature at %#x" % cs_off)
        f.seek(cs_off + 12)
        index = [struct.unpack(">II", f.read(8)) for _ in range(count)]
        cd = next(cs_off + o for t, o in index if t == 0)
        f.seek(cd)
        (m, _, _, flags, hash_off, _, n_special, n_code, code_limit,
         hash_size, hash_type, _, page_log) = struct.unpack(">IIIIIIIIIBBBB", f.read(40))
        if m != CSMAGIC_CODEDIRECTORY or hash_type != 1 or hash_size != 20 or page_log != 12:
            sys.exit("unexpected code directory (magic %#x, hash type %d, size %d, page 2^%d)"
                     % (m, hash_type, hash_size, page_log))
        f.seek(0)
        page = bytearray(f.read(1 << page_log))
        f.seek(cd + hash_off)
        slot0 = f.read(20)
        if hashlib.sha1(page).digest() != slot0:
            sys.exit("slot 0 does not match the first page: not a cache this tool wrote or the stock one")
        was = struct.unpack_from("<Q", page, CACHE_TYPE)[0]
        if was == 0:
            print("already a development cache (cacheType 0)")
        else:
            struct.pack_into("<Q", page, CACHE_TYPE, 0)
            f.seek(0)
            f.write(page)
            f.seek(cd + hash_off)
            f.write(hashlib.sha1(page).digest())
            print("cacheType %d -> 0; code directory slot 0 (of %d, flags %#x) rehashed" % (was, n_code, flags))
        f.seek(cd + 4)
        n = struct.unpack(">I", f.read(4))[0]
        f.seek(cd)
        blob = f.read(n)
    print(hashlib.sha1(blob).hexdigest(), path)


if __name__ == "__main__":
    main(*sys.argv[1:])
