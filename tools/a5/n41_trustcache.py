#!/usr/bin/env python3
"""Put our own CDHashes into the iPhone 5 (14G61) kernel's static trust cache.

    n41_trustcache.py KERNEL OUT HASHFILE... [--keep KEEPFILE...]

iOS 10.3.4's AMFI (AppleMobileFileIntegrity's vnode_check_signature, 0x807eb810) trusts a code directory whose
hash is in the static trust cache (0x807e934c) and otherwise asks amfid, which neither the restore RAM disk nor
early boot has: an ad hoc signature (our helpers, a patched and re-signed daemon, the development shared cache,
the GL front end) fails with "_validateCodeDirectoryHashInDaemon ... no registered daemon port" / "AMFI: code
signature validation failed". 9.3.5's "Invalid signature but permitting execution" is gone.

The cache: a 256-entry index by the hash's first byte, {u16 count, u16 first}, at 0x807edfd4, then the sorted
entries, the other 19 bytes each, at 0x807ee3d4; 5635 of them, followed by a certificate, so there is no room
to grow. 4112 of them match no Mach-O slice of 14G61's root filesystem or restore RAM disk (tools/a5/cdhash.py);
as many of those as there are new hashes are dropped (the last ones in order), the rest re-sorted and the index
rebuilt. KEEPFILEs (cdhash.py output, default work/a6/cdhash-rootfs.txt and cdhash-ramdisk.txt) say what must
stay. HASHFILEs: one CDHash (40 hex digits) at the start of each line, as cdhash.py prints them.
"""
import struct, sys

IDX, HASH, COUNT = 0x807EDFD4, 0x807EE3D4, 5635       # in AMFI, prelinked into __PRELINK_TEXT


def file_offset(k, va):
    """VA -> kernelcache file offset, from its LC_SEGMENTs."""
    ncmds, c = struct.unpack_from("<I", k, 16)[0], 28
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", k, c)
        if cmd == 1:
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<IIII", k, c + 24)
            if vmaddr <= va < vmaddr + vmsize and va - vmaddr < filesize:
                return va - vmaddr + fileoff
        c += size
    raise SystemExit("%#x is in no segment of the kernelcache" % va)


def read_hashes(path):
    out = []
    for line in open(path):
        w = line.split()
        if w and len(w[0]) == 40:
            out.append(bytes.fromhex(w[0]))
    return out


def entries(k):
    idx_off, hash_off = file_offset(k, IDX), file_offset(k, HASH)
    idx = [struct.unpack_from("<HH", k, idx_off + 4 * b) for b in range(256)]
    if sum(c for c, _ in idx) != COUNT or any(s != sum(c for c, _ in idx[:b]) for b, (c, s) in enumerate(idx)):
        raise SystemExit("not 14G61's trust cache layout at %#x" % IDX)
    out = []
    for b, (c, s) in enumerate(idx):
        for i in range(s, s + c):
            out.append(bytes([b]) + bytes(k[hash_off + 19 * i:hash_off + 19 * (i + 1)]))
    return out


def patch(k, add, keep):
    """k: the kernelcache (bytearray, file layout). Returns how many entries were replaced."""
    have = entries(k)
    idx_off, hash_off = file_offset(k, IDX), file_offset(k, HASH)
    add = [h for h in dict.fromkeys(add) if h not in set(have)]
    spare = [h for h in have if h not in keep]
    if len(add) > len(spare):
        raise SystemExit("only %d spare trust cache slots for %d hashes" % (len(spare), len(add)))
    drop = set(spare[len(spare) - len(add):]) if add else set()
    new = sorted([h for h in have if h not in drop] + add)
    assert len(new) == COUNT
    first = 0
    for b in range(256):
        n = sum(1 for h in new if h[0] == b)
        struct.pack_into("<HH", k, idx_off + 4 * b, n, first)
        first += n
    for i, h in enumerate(new):
        k[hash_off + 19 * i:hash_off + 19 * (i + 1)] = h[1:]
    return len(add)


def main(argv):
    kernel, out, rest = argv[0], argv[1], argv[2:]
    keepfiles = ["work/a6/cdhash-rootfs.txt", "work/a6/cdhash-ramdisk.txt"]
    if "--keep" in rest:
        i = rest.index("--keep")
        rest, keepfiles = rest[:i], rest[i + 1:]
    keep = {h for f in keepfiles for h in read_hashes(f)}
    add = [h for f in rest for h in read_hashes(f)]
    k = bytearray(open(kernel, "rb").read())
    n = patch(k, add, keep)
    open(out, "wb").write(k)
    print("trust cache: %d hashes added, %d slots replaced" % (n, n))


if __name__ == "__main__":
    main(sys.argv[1:])
