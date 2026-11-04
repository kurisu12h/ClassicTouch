#!/usr/bin/env python3
"""dtcmp.py A.bin B.bin [PREFIX]: compare two device trees' nodes under PREFIX (default arm-io): each node's
compatible, first reg (base, size), interrupts and device_type, side by side; nodes only in one marked.
For bringing up a board from a sibling's (A5 n78 -> A6 n41, docs/reports/a6-step1.md). Run from the project root."""
import struct, sys, types
sys.path.insert(0, "work/a5/imgtools")
sys.modules.setdefault("mkpkg", types.ModuleType("mkpkg"))
import ipad1_kboot as kb


def val(dt, path, prop):
    off, _ = dt.props[path][prop]
    n = struct.unpack_from("<I", dt.buf, off + 32)[0] & 0x7FFFFFFF
    return dt.buf[off + 36:off + 36 + n]


def summary(dt, path):
    p = dt.props[path]
    out = []
    if "compatible" in p:
        out.append(val(dt, path, "compatible").split(b"\0")[0].decode("latin1"))
    if "reg" in p:
        r = val(dt, path, "reg")
        if len(r) >= 8:
            out.append("reg %#x+%#x" % struct.unpack_from("<II", r))
    if "interrupts" in p:
        r = val(dt, path, "interrupts")
        out.append("irq " + ",".join("%#x" % v for v in struct.unpack_from("<%dI" % (len(r) // 4), r)[:4]))
    return " ".join(out)


def main(a, b, prefix="arm-io"):
    A = kb.DeviceTree(open(a, "rb").read())
    B = kb.DeviceTree(open(b, "rb").read())
    pa = {p for p in A.props if p.startswith(prefix + "/") and p.count("/") == prefix.count("/") + 1}
    pb = {p for p in B.props if p.startswith(prefix + "/") and p.count("/") == prefix.count("/") + 1}
    for p in sorted(pa | pb):
        sa = summary(A, p) if p in pa else "-"
        sb = summary(B, p) if p in pb else "-"
        mark = "  " if sa == sb else ("A " if p not in pb else "B " if p not in pa else "* ")
        print("%s%-28s %-58s | %s" % (mark, p[len(prefix) + 1:], sa[:58], sb[:70]))


if __name__ == "__main__":
    main(*sys.argv[1:4])
