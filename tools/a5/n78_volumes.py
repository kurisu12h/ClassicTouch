#!/usr/bin/env python3
"""System and data volumes for the n78 from an IPSW rootfs, for builds FirmwareKit has no recipe for (13G36).

    n78_volumes.py ROOTFS.dmg OUTDIR [SYSTEM_GROW_MiB [DATA_MiB]]

OUTDIR/system.img: the rootfs's HFS volume (an Apple partition map's to 9.x, imgtools/ipad1_rootfs.extract_rootfs;
a GUID partition table's from 10.x: an EFI partition and the Apple_HFSX one, extract_hfs below), grown by SYSTEM_GROW_MiB
(default 512) for what goes on it later (GL front end, helpers). OUTDIR/data.img: a sparse journaled HFSX
"Data" of DATA_MiB (default 14336), seeded with the system volume's /private/var as FirmwareKit's SystemEdits
does it: copied through a noowners mount, the owners put back offline from the system catalog (else root,
mobile and ea by rule), content protection on (a restore formats the data volume with it from 5.0).
No other edits: fstab, activation, Setup and the rest are n78_diskfix.sh's. Then

    n78_usbroot.py OUTDIR/system.img DISK.img OUTDIR/data.img

Run from work/a5 (imgtools beside it).
"""
import os, shutil, struct, subprocess, sys, tempfile, types, uuid

sys.path.insert(0, "imgtools")
sys.modules.setdefault("mkpkg", types.ModuleType("mkpkg"))   # ipad1_rootfs imports it for the guest package only
import build_nand as bn
import ipad1_rootfs as rf
from ipad1_nand import make_hfs_image

MiB = 1 << 20
HFS_GUID = uuid.UUID("48465300-0000-11AA-AA11-00306543ECAC")


def extract_hfs(src, out):
    """The rootfs DMG's HFS volume as a raw image: GPT (10.x) here, an Apple partition map by imgtools."""
    work = tempfile.mkdtemp(prefix="n78_volumes.")
    try:
        bn.run(["hdiutil", "convert", src, "-format", "UDTO", "-o", os.path.join(work, "raw")])
        raw = os.path.join(work, "raw.cdr")
        with open(raw, "rb") as f:
            head = f.read(64 * 512)
        if head[:2] == b"ER" or head[512:520] != b"EFI PART":
            rf.extract_rootfs(src, out)
            return
        lba, count, size = struct.unpack_from("<QII", head, 512 + 72)
        with open(raw, "rb") as f:
            f.seek(lba * 512)
            table = f.read(count * size)
            for i in range(count):
                e = table[i * size:(i + 1) * size]
                if uuid.UUID(bytes_le=e[:16]) == HFS_GUID:
                    first, last = struct.unpack_from("<QQ", e, 32)
                    break
            else:
                raise SystemExit("%s: no Apple_HFS partition in its GPT" % src)
            f.seek(first * 512)
            left = (last - first + 1) * 512
            with open(out, "wb") as o:
                while left:
                    chunk = f.read(min(left, 1 << 24))
                    o.write(chunk)
                    left -= len(chunk)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(rootfs, out, grow="512", data_mib="14336"):
    os.makedirs(out, exist_ok=True)
    system, data = os.path.join(out, "system.img"), os.path.join(out, "data.img")
    extract_hfs(rootfs, system)
    size = os.path.getsize(system)
    rf.grow_to_partition(system, (size + int(grow) * MiB) // rf.BLOCK)
    print("system.img: %d MiB (+%s), %s" % (os.path.getsize(system) >> 20, grow, rf.hfs_info(system)))

    owners = rf.var_owners(system)
    skeleton = os.path.join(out, "var-skeleton")
    shutil.rmtree(skeleton, ignore_errors=True)
    with rf.Mounted(system, os.path.join(out, "mnt-system")) as m:
        shutil.copytree(os.path.join(m.mnt, "private/var"), skeleton, symlinks=True)

    make_hfs_image(data, int(data_mib) * MiB)
    by_owner = {}
    with rf.Mounted(data, os.path.join(out, "mnt-data")) as m:
        shutil.copytree(skeleton, m.mnt, symlinks=True, dirs_exist_ok=True)
        for root, dnames, fnames in os.walk(m.mnt):
            dnames[:] = [d for d in dnames if d not in bn.JUNK]
            for n in dnames + [f for f in fnames if f not in bn.JUNK]:
                rel = os.path.relpath(os.path.join(root, n), m.mnt)
                by_owner.setdefault(owners.get(rel) or rf.owner_for(rel), []).append(rel)
    n = sum(bn.set_owner(data, paths, uid, gid) for (uid, gid), paths in sorted(by_owner.items()))
    rf.set_content_protection(data)
    print("data.img: %s MiB sparse, owners %s (%d catalog records), content protection on"
          % (data_mib, ", ".join("%d:%d x%d" % (u, g, len(p)) for (u, g), p in sorted(by_owner.items())), n))
    for d in ("var-skeleton", "mnt-system", "mnt-data"):
        shutil.rmtree(os.path.join(out, d), ignore_errors=True)


if __name__ == "__main__":
    main(*sys.argv[1:5])
