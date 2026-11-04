#!/usr/bin/env python3
"""Pack a finished device into a .ctpack, which the app unpacks once it is copied to the phone
(app/ClassicTouch/DevicePack.swift).

Why not plain devicectl copy: a device's NAND files are sparse (the iPod touch 2G's are 465 MB real, 8.1 GB apparent;
the 3GS's 1.8 GB real, 17 GB apparent), and devicectl sends the holes as zeros (about 58 MB/s measured), which really
fill up the phone too. A .ctpack holds only the extents with data (SEEK_DATA/SEEK_HOLE, also skipping all-zero 64 KiB
blocks), and the app writes them back extent by extent when unpacking, so the files stay sparse.

Format (little-endian): b"CTPACK1\\n", then entries, ending with type 0:
  u8 type (1 directory, 2 file)  u16 path length  path (UTF-8, relative to the app's Documents)  u32 mode bits
  files add: u64 size  u32 extent count  per extent u64 offset, u64 length, followed by that many bytes of data

Usage: pack-device.py OUT.ctpack SRC_DIR=PATH_IN_PACK [SRC_DIR=PATH_IN_PACK ...]
  Example: pack-device.py work/ios/packs/n72ap.ctpack work/ios/devices/n72ap-7E18=devices/n72ap-7E18
"""
import os
import stat
import struct
import sys

CHUNK = 64 * 1024
ZERO = bytes(CHUNK)


def extents(fd, size):
    """(offset, length) extents with data, dropping all-zero 64 KiB blocks."""
    off = 0
    raw = []
    while off < size:
        try:
            start = os.lseek(fd, off, os.SEEK_DATA)
        except OSError:
            break
        end = os.lseek(fd, start, os.SEEK_HOLE)
        raw.append((start, min(end, size)))
        off = end
    for start, end in raw:
        run = None
        pos = start
        while pos < end:
            n = min(CHUNK - pos % CHUNK, end - pos)
            block = os.pread(fd, n, pos)
            if block.count(0) == len(block):
                if run:
                    yield run
                    run = None
            elif run and run[0] + run[1] == pos:
                run = (run[0], run[1] + n)
            else:
                if run:
                    yield run
                run = (pos, n)
            pos += n
        if run:
            yield run


def main():
    out, pairs = sys.argv[1], sys.argv[2:]
    if not pairs:
        sys.exit(__doc__)
    total = 0
    with open(out + ".part", "wb") as f:
        f.write(b"CTPACK1\n")
        for pair in pairs:
            src, dst = pair.split("=", 1)
            for dirpath, dirnames, filenames in os.walk(src):
                dirnames.sort()
                rel = os.path.relpath(dirpath, src)
                base = dst if rel == "." else os.path.join(dst, rel)
                p = base.encode()
                f.write(struct.pack("<BH", 1, len(p)) + p + struct.pack("<I", 0o755))
                for name in sorted(filenames):
                    path = os.path.join(dirpath, name)
                    st = os.lstat(path)
                    if not stat.S_ISREG(st.st_mode):
                        continue
                    p = os.path.join(base, name).encode()
                    fd = os.open(path, os.O_RDONLY)
                    try:
                        ex = list(extents(fd, st.st_size))
                        # Writable after unpacking (QEMU writes the NOR, the overlay and the NAND in place); it does
                        # no harm for the read-only base files either
                        f.write(struct.pack("<BH", 2, len(p)) + p + struct.pack("<IQI", 0o644, st.st_size, len(ex)))
                        for off, n in ex:
                            f.write(struct.pack("<QQ", off, n))
                            pos = off
                            while pos < off + n:
                                k = min(8 << 20, off + n - pos)
                                f.write(os.pread(fd, k, pos))
                                pos += k
                            total += n
                    finally:
                        os.close(fd)
        f.write(b"\0")
    os.rename(out + ".part", out)
    print("%s: data %.0f MB, pack %.0f MB" % (out, total / 1048576, os.path.getsize(out) / 1048576))


if __name__ == "__main__":
    main()
