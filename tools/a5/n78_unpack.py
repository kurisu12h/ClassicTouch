#!/usr/bin/env python3
"""Decrypt what an A5 kboot needs out of an iPod5,1 IPSW: kernelcache.mach, DeviceTree.bin (+ .txt), iBoot.bin,
RestoreRamDisk.dmg and AppleLogo.bin (the iBootIm iBoot draws; n78_kboot.py puts it in vram the same way).

    n78_unpack.py IPSW KEYS.json OUTDIR

KEYS.json is ipsw.me's /v4/keys/ipsw/iPod5,1/<build> answer. Reuses imgtools/ipad1_fw.py (qemu-ios, at
22f4f72746^) for IMG3, AES and LZSS. The root filesystem and the ramdisks are left for later steps.
"""
import json, os, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
# imgtools as of qemu-ios 22f4f72746^: next to this script, or where tools/a5/README.md unpacks it.
IMGTOOLS = os.environ.get("IMGTOOLS") or next(
    (p for p in (os.path.join(HERE, "imgtools"), os.path.join(HERE, "../../work/a5/imgtools"))
     if os.path.isdir(p)), os.path.join(HERE, "imgtools"))
sys.path.insert(0, IMGTOOLS)
from ipad1_fw import components, img3_decrypt, complzss, dt_dump  # noqa: E402


def main(ipsw, keys_json, out):
    keys = {}
    for k in json.load(open(keys_json))["keys"]:
        if k.get("iv") and k.get("key"):
            keys[os.path.basename(k["filename"])] = (bytes.fromhex(k["iv"]), bytes.fromhex(k["key"]))
    os.makedirs(out, exist_ok=True)
    z = zipfile.ZipFile(ipsw)
    comp = components(z)
    for c, name in (("KernelCache", "kernelcache.mach"), ("DeviceTree", "DeviceTree.bin"), ("iBoot", "iBoot.bin")):
        path = comp[c]
        payload = img3_decrypt(z.read(path), *keys[os.path.basename(path)])
        if c == "KernelCache":
            payload = complzss(payload)
        open(os.path.join(out, name), "wb").write(payload)
        if c == "DeviceTree":
            open(os.path.join(out, "DeviceTree.txt"), "w").write(dt_dump(payload))
        print("ok", c, path, len(payload))
    # The restore ramdisk, a raw HFS+ image: bootable as md0 (n78_kboot.py N78_RAMDISK=...).
    path = comp["RestoreRamDisk"]
    payload = img3_decrypt(z.read(path), *keys[os.path.basename(path)])
    open(os.path.join(out, "RestoreRamDisk.dmg"), "wb").write(payload)
    print("ok RestoreRamDisk", path, len(payload))
    path = comp["AppleLogo"]
    payload = img3_decrypt(z.read(path), *keys[os.path.basename(path)])
    open(os.path.join(out, "AppleLogo.bin"), "wb").write(payload)
    print("ok AppleLogo", path, len(payload))


if __name__ == "__main__":
    main(*sys.argv[1:4])
