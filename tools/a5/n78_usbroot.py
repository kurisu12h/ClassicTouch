#!/usr/bin/env python3
"""Make a USB disk image the n78 kernel can root from: GPT, partition 1 = the IPSW's system volume.

    n78_usbroot.py ROOTFS.dmg|SYSTEM.img OUT.img [DATA.img|EXTRA_MiB]

The second form takes volumes FirmwareKit already made (firmwarekit create --stop-after volumes:
volumes/system.img, volumes/data.img), and DATA.img becomes partition 2, /dev/disk0s2, the /private/var the
fstab mounts. Both are copied sparsely (zero 1 MiB runs are skipped), so a 14 GB sparse data volume stays sparse.

ROOTFS.dmg is the IPSW's rootfs after vfdecrypt (imgtools/vfdecrypt.py with ipsw.me's RootFS key): a UDIF
image holding an Apple partition map with one Apple_HFS(X) partition. hdiutil turns it into a raw image,
the HFS volume is sliced out, and it becomes partition 1 (Apple HFS type GUID) of a GPT disk. The kernel's
IOGUIDPartitionScheme publishes it with "Partition ID" 1, which is what kboot's default root-matching asks
for. EXTRA_MiB (default 0) leaves free space after it. Attach with
    -drive if=none,id=root,file=OUT.img,format=raw -device usb-storage,bus=ehci.0,drive=root
"""
import os, shutil, struct, subprocess, sys, tempfile, uuid, zlib

SECTOR = 512
FIRST_LBA = 2048                       # partition 1 at 1 MiB
HFS_TYPE = uuid.UUID("48465300-0000-11AA-AA11-00306543ECAC")
ENTRIES, ENTRY_SIZE = 128, 128


def apm_hfs_slice(raw):
    """(byte offset, byte length) of the HFS partition in an Apple Partition Map (as imgtools/ipad1_rootfs.py)."""
    assert raw[:2] == b"ER", "not an Apple partition map"
    bs = struct.unpack_from(">H", raw, 2)[0]
    n = struct.unpack_from(">I", raw, bs + 4)[0]
    for i in range(1, n + 1):
        e = raw[bs * i:bs * (i + 1)]
        start, count = struct.unpack_from(">II", e, 8)
        if e[48:80].split(b"\0")[0] in (b"Apple_HFSX", b"Apple_HFS"):
            return start * bs, count * bs
    raise ValueError("no Apple_HFS(X) partition")


def gpt(total_lbas, parts, disk_guid):
    """(protective MBR + primary header + entries, backup entries + backup header) for [(first, last, name)]."""
    entries = b"".join(HFS_TYPE.bytes_le + uuid.uuid4().bytes_le + struct.pack("<QQQ", first, last, 0) +
                       name.encode("utf-16-le").ljust(72, b"\0") for first, last, name in parts)
    entries = entries.ljust(ENTRIES * ENTRY_SIZE, b"\0")
    ecrc = zlib.crc32(entries)
    n_entry_lbas = ENTRIES * ENTRY_SIZE // SECTOR

    def header(current, backup, entries_lba):
        h = struct.pack("<8sIIIIQQQQ16sQIII", b"EFI PART", 0x10000, 92, 0, 0, current, backup,
                        2 + n_entry_lbas, total_lbas - 2 - n_entry_lbas, disk_guid.bytes_le,
                        entries_lba, ENTRIES, ENTRY_SIZE, ecrc)
        h = h[:16] + struct.pack("<I", zlib.crc32(h)) + h[20:]
        return h.ljust(SECTOR, b"\0")

    mbr = bytearray(SECTOR)
    mbr[446:462] = struct.pack("<BBBBBBBBII", 0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF, 1,
                               min(total_lbas - 1, 0xFFFFFFFF))
    mbr[510:512] = b"\x55\xaa"
    head = bytes(mbr) + header(1, total_lbas - 1, 2) + entries
    tail = entries + header(total_lbas - 1, 1, total_lbas - 1 - n_entry_lbas)
    return head, tail


def copy_sparse(src, off, ln, o, at):
    """ln bytes of src from off to o at byte `at`, skipping all-zero 1 MiB runs (the output stays sparse)."""
    src.seek(off)
    done = 0
    while done < ln:
        chunk = src.read(min(ln - done, 1 << 20))
        if chunk.count(0) != len(chunk):
            o.seek(at + done)
            o.write(chunk)
        done += len(chunk)


def main(system, out, third="0"):
    work = tempfile.mkdtemp(prefix="n78_usbroot.")
    try:
        if system.endswith(".dmg"):
            subprocess.run(["hdiutil", "convert", system, "-format", "UDTO", "-o", os.path.join(work, "raw")],
                           check=True, stdout=subprocess.DEVNULL)
            raw = os.path.join(work, "raw.cdr")
            with open(raw, "rb") as f:
                off, ln = apm_hfs_slice(f.read(64 * SECTOR))
        else:
            raw, off, ln = system, 0, os.path.getsize(system)
        data = third if not third.isdigit() else None
        extra = 0 if data else int(third) * 1024 * 1024 // SECTOR
        parts = [(FIRST_LBA, FIRST_LBA + ln // SECTOR - 1, "System")]
        if data:
            first = (parts[0][1] + 1 + 2047) // 2048 * 2048
            parts.append((first, first + os.path.getsize(data) // SECTOR - 1, "Data"))
        total = parts[-1][1] + 1 + extra + 2048        # room for the backup GPT
        head, tail = gpt(total, parts, uuid.uuid4())
        with open(out, "wb") as o:
            o.truncate(total * SECTOR)
            o.seek(0)
            o.write(head)
            with open(raw, "rb") as f:
                copy_sparse(f, off, ln, o, FIRST_LBA * SECTOR)
            if data:
                with open(data, "rb") as f:
                    copy_sparse(f, 0, os.path.getsize(data), o, parts[1][0] * SECTOR)
            o.seek((total - len(tail) // SECTOR) * SECTOR)
            o.write(tail)
        for i, (first, last, name) in enumerate(parts, 1):
            print("%s: partition %d %s at LBA %d, %d MiB" % (out, i, name, first, (last - first + 1) * SECTOR >> 20))
        print("disk %d MiB" % (total * SECTOR >> 20))
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main(*sys.argv[1:4])
