#!/usr/bin/env python3
"""Make a USB disk image the n78 kernel can root from: GPT, partition 1 = the IPSW's system volume.

    n78_usbroot.py ROOTFS.dmg OUT.img [EXTRA_MiB]

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


def gpt(total_lbas, part_first, part_last, disk_guid, part_guid):
    """(protective MBR + primary header + entries, backup entries + backup header) for one partition."""
    entry = HFS_TYPE.bytes_le + part_guid.bytes_le + struct.pack("<QQQ", part_first, part_last, 0)
    entry += "System".encode("utf-16-le").ljust(72, b"\0")
    entries = entry.ljust(ENTRIES * ENTRY_SIZE, b"\0")
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


def main(dmg, out, extra_mib="0"):
    work = tempfile.mkdtemp(prefix="n78_usbroot.")
    try:
        subprocess.run(["hdiutil", "convert", dmg, "-format", "UDTO", "-o", os.path.join(work, "raw")],
                       check=True, stdout=subprocess.DEVNULL)
        raw = os.path.join(work, "raw.cdr")
        with open(raw, "rb") as f:
            off, ln = apm_hfs_slice(f.read(64 * SECTOR))
        part_lbas = ln // SECTOR
        extra = int(extra_mib) * 1024 * 1024 // SECTOR
        total = FIRST_LBA + part_lbas + extra + 2048        # room for the backup GPT
        head, tail = gpt(total, FIRST_LBA, FIRST_LBA + part_lbas - 1, uuid.uuid4(), uuid.uuid4())
        with open(raw, "rb") as f, open(out, "wb") as o:
            o.write(head)
            o.seek(FIRST_LBA * SECTOR)
            f.seek(off)
            left = ln
            while left:
                chunk = f.read(min(left, 1 << 24))
                o.write(chunk)
                left -= len(chunk)
            o.seek((total - len(tail) // SECTOR) * SECTOR)
            o.write(tail)
        print("%s: GPT, partition 1 HFS at LBA %d, %d MiB; disk %d MiB" %
              (out, FIRST_LBA, ln >> 20, total * SECTOR >> 20))
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main(*sys.argv[1:4])
