#!/usr/bin/env python3
"""Unpack what an A5/A6 kboot needs out of an IPSW: kernelcache.mach, DeviceTree.bin (+ .txt), iBoot.bin,
RestoreRamDisk.dmg and AppleLogo.bin (the iBootIm iBoot draws; n78_kboot.py puts it in vram the same way).

    n78_unpack.py IPSW KEYS.json|- OUTDIR [BOARD]

KEYS.json is ipsw.me's /v4/keys/ipsw/<device>/<build> answer, for the encrypted images (iPod5,1 7.1.2, 9.3.5);
"-" when none are: A6's iOS 10 images carry no KBAG, so their DATA is taken as it is (docs/reports/a6-step1.md).
BOARD picks the build identity by DeviceClass when one IPSW serves several boards (iPhone_4.0_32bit_10.3.4:
n41ap, n42ap, n48ap, n49ap); default the manifest's first. Reuses imgtools/ipad1_fw.py (qemu-ios, at
22f4f72746^) for IMG3, AES and LZSS. The root filesystem is left for later steps.
"""
import json, os, plistlib, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
# imgtools as of qemu-ios 22f4f72746^: next to this script, or where tools/a5/README.md unpacks it.
IMGTOOLS = os.environ.get("IMGTOOLS") or next(
    (p for p in (os.path.join(HERE, "imgtools"), os.path.join(HERE, "../../work/a5/imgtools"))
     if os.path.isdir(p)), os.path.join(HERE, "imgtools"))
sys.path.insert(0, IMGTOOLS)
from ipad1_fw import components, img3_decrypt, img3_tags, complzss, dt_dump  # noqa: E402


def board_components(z, board):
    """{component: IPSW path} of the Erase identity whose DeviceClass is `board`."""
    ids = plistlib.loads(z.read("BuildManifest.plist"))["BuildIdentities"]
    for bi in ids:
        if bi["Info"].get("DeviceClass") == board and bi["Info"].get("RestoreBehavior") == "Erase":
            return {k: v["Info"]["Path"] for k, v in bi["Manifest"].items() if "Path" in v.get("Info", {})}
    raise SystemExit("no Erase identity for %s in the BuildManifest" % board)


def main(ipsw, keys_json, out, board=None):
    keys = {}
    if keys_json != "-":
        for k in json.load(open(keys_json))["keys"]:
            if k.get("iv") and k.get("key"):
                keys[os.path.basename(k["filename"])] = (bytes.fromhex(k["iv"]), bytes.fromhex(k["key"]))
    os.makedirs(out, exist_ok=True)
    z = zipfile.ZipFile(ipsw)
    comp = board_components(z, board) if board else components(z)

    def payload(path):
        data = z.read(path)
        if "KBAG" not in img3_tags(data):
            off, dlen = img3_tags(data)["DATA"]
            return data[off + 12:off + 12 + dlen]
        return img3_decrypt(data, *keys[os.path.basename(path)])

    for c, name in (("KernelCache", "kernelcache.mach"), ("DeviceTree", "DeviceTree.bin"), ("iBoot", "iBoot.bin")):
        path = comp[c]
        data = payload(path)
        if c == "KernelCache":
            data = complzss(data)
        open(os.path.join(out, name), "wb").write(data)
        if c == "DeviceTree":
            open(os.path.join(out, "DeviceTree.txt"), "w").write(dt_dump(data))
        print("ok", c, path, len(data))
    # The restore ramdisk, a raw HFS+ image: bootable as md0 (n78_kboot.py N78_RAMDISK=...).
    for c, name in (("RestoreRamDisk", "RestoreRamDisk.dmg"), ("AppleLogo", "AppleLogo.bin")):
        path = comp[c]
        data = payload(path)
        open(os.path.join(out, name), "wb").write(data)
        print("ok", c, path, len(data))


if __name__ == "__main__":
    main(*sys.argv[1:5])
