#!/usr/bin/env python3
"""Get FirmwareKit to make an n78 (iPod touch 5) iOS 7 system and data volume (report §3.12).

    n78_fkprep.py BUILD OUTDIR

Writes OUTDIR/n78ap-<BUILD>.json, a catalog entry built from n90ap-11D257's (the A4 iPhone 4's iOS 7 recipe:
system_mib, data_size, ca_ogl, appsync) with the iPod5,1 IPSW's keys from work/a5/keys/<BUILD>.json, and
OUTDIR/helper/, M0's LightTouchDevice stand-in (tools/m0/helper-shim) with this checkout's paths and an n78ap
row in its machine list. Then, with FirmwareKit patched by patches/a5-firmwarekit-n78-volumes.patch:

    firmwarekit create --entry OUTDIR/n78ap-<BUILD>.json --ipsw IPSW --out OUTDIR/out --cache OUTDIR/cache \\
        --guest-tools work/guest-artifacts/ipad-guest-tools --helper OUTDIR/helper/LightTouchDevice \\
        --stop-after volumes --skip-setup --language en-US
    n78_usbroot.py OUTDIR/out/volumes/system.img DISK.img OUTDIR/out/volumes/data.img

Only the volumes are made: no seal or keybag boots (they would run the A4 machine).
"""
import hashlib, json, os, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
# ipsw.me image names -> the catalog's
RENAME = {"Kernelcache": "kernelcache", "RestoreRamdisk": "RestoreRamDisk", "UpdateRamdisk": "UpdateRamDisk",
          "RootFS": "rootfs"}


def main(build, out):
    os.makedirs(os.path.join(out, "helper"), exist_ok=True)
    catalog = json.load(open(os.path.join(ROOT, "upstream/LightTouchMac/LightTouchMac/Resources/firmware-catalog.json")))
    entries = catalog["entries"] if isinstance(catalog, dict) and "entries" in catalog else catalog
    n90 = next(e for e in entries if e.get("id") == "n90ap-11D257")
    keys = {}
    for k in json.load(open(os.path.join(ROOT, "work/a5/keys/%s.json" % build)))["keys"]:
        if k.get("key"):
            keys[RENAME.get(k["image"], k["image"])] = dict(file=os.path.basename(k["filename"]), key=k["key"],
                                                            **({"iv": k["iv"]} if k.get("iv") else {}))
    ipsw = next(os.path.join(ROOT, "work/firmware", f) for f in os.listdir(os.path.join(ROOT, "work/firmware"))
                if f.startswith("iPod5,1_") and ("_%s_" % build) in f)
    h = hashlib.sha1()
    with open(ipsw, "rb") as f:
        for b in iter(lambda: f.read(1 << 24), b""):
            h.update(b)
    entry = dict(n90, id="n78ap-" + build, board="n78ap", product_type="iPod5,1", build=build, keys=keys,
                 source={"kind": "ipsw", "url": "https://example.invalid/" + os.path.basename(ipsw),
                         "sha1": h.hexdigest(), "bytes": os.path.getsize(ipsw)})
    entry["recipe"] = dict(n90["recipe"], system_mib=1792,
                           options={"ca_ogl": True, "appsync": True, "web_proxy": False})
    json.dump(entry, open(os.path.join(out, "n78ap-%s.json" % build), "w"), indent=1)

    shim = open(os.path.join(ROOT, "tools/m0/helper-shim/shim.py")).read()
    shim = shim.replace("/path/to/classic-ios", ROOT)
    shim = "\n".join('MACHINES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "machines.json")'
                     if l.startswith("MACHINES = ") else l for l in shim.splitlines()) + "\n"
    open(os.path.join(out, "helper/shim.py"), "w").write(shim)
    launcher = os.path.join(out, "helper/LightTouchDevice")
    open(launcher, "w").write(open(os.path.join(ROOT, "tools/m0/helper-shim/LightTouchDevice")).read())
    os.chmod(launcher, 0o755)
    machines = json.load(open(os.path.join(ROOT, "upstream/LightTouchMac/tests/fixtures/machines.json")))
    rows = machines if isinstance(machines, list) else machines.get("machines", machines)
    if not any(r.get("board") == "n78ap" for r in rows):
        n90row = next(r for r in rows if r.get("board") == "n90ap")
        rows.append(dict(n90row, board="n78ap", machine="iPod-Touch-5G", screenHeight=1136))
    json.dump(machines, open(os.path.join(out, "helper/machines.json"), "w"), indent=1)
    print("entry %s, helper %s" % (os.path.join(out, "n78ap-%s.json" % build), launcher))


if __name__ == "__main__":
    main(*sys.argv[1:3])
