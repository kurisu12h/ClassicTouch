#!/usr/bin/env python3
"""把一台做好的设备打成 .ctpack，拷进手机后由 App 解开（app/ClassicTouch/DevicePack.swift）。

为什么不直接用 devicectl copy：设备的 NAND 文件是稀疏文件（iPod touch 2 代实际 465 MB、表观 8.1 GB；
3GS 实际 1.8 GB、表观 17 GB），devicectl 会把空洞当零照传（实测约 58 MB/s），手机上也会真的占满。
.ctpack 只装有数据的区段（SEEK_DATA/SEEK_HOLE，再跳过全零的 64 KiB 块），App 解包时按区段写回，
文件还是稀疏的。

格式（小端）：b"CTPACK1\\n"，然后若干条目，以类型 0 结尾：
  u8 类型（1 目录，2 文件）  u16 路径长度  路径（UTF-8，相对 App 的 Documents）  u32 权限位
  文件再加：u64 大小  u32 区段数  每个区段 u64 偏移、u64 长度，紧跟着这么多字节的数据

用法：pack-device.py 输出.ctpack 源目录=包内路径 [源目录=包内路径 ...]
  例：pack-device.py work/ios/packs/n72ap.ctpack work/ios/devices/n72ap-7E18=devices/n72ap-7E18
"""
import os
import stat
import struct
import sys

CHUNK = 64 * 1024
ZERO = bytes(CHUNK)


def extents(fd, size):
    """(偏移, 长度) 的有数据区段，去掉全零的 64 KiB 块。"""
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
                        # 解包后要可写（QEMU 写 NOR、overlay、就地写的 NAND），只读的本体也没关系
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
    print("%s：数据 %.0f MB，包 %.0f MB" % (out, total / 1048576, os.path.getsize(out) / 1048576))


if __name__ == "__main__":
    main()
