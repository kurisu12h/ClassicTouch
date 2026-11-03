#!/usr/bin/env python3
"""kexts.py KERNEL [ADDR...]: list prelinked kexts (load address, size, bundle id); with ADDRs, name their kext."""
import os, re, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "imgtools"))
from macho import Macho
path = sys.argv[1]
m = Macho(path); d = open(path, "rb").read()
_, vm, _, fo, fs, _ = [s for s in m.segs if s[0] == '__PRELINK_INFO'][0]
info = d[fo:fo + fs].decode('latin1')
ids = {}
for mm in re.finditer(r'<(integer|string)[^>]*ID="(\d+)"[^>]*>([^<]*)</', info):
    ids[mm.group(2)] = mm.group(3)
def val(key, chunk):
    mm = re.search(r'<key>%s</key>\s*<(?:integer|string)([^>]*?)(/?)>([^<]*)' % key, chunk)
    if not mm:
        return None
    ref = re.search(r'IDREF="(\d+)"', mm.group(1))
    return ids[ref.group(1)] if ref else mm.group(3)
items = []
starts = [mm.start() for mm in re.finditer(r'<key>CFBundleName</key>', info)]
for i, s in enumerate(starts):
    chunk = info[s:starts[i + 1] if i + 1 < len(starts) else len(info)]
    a, z, b = val('_PrelinkExecutableLoadAddr', chunk), val('_PrelinkExecutableSize', chunk), val('CFBundleIdentifier', chunk)
    if a and z:
        items.append((int(a, 0), int(z, 0), b))
items.sort()
if len(sys.argv) > 2:
    for x in sys.argv[2:]:
        x = int(x, 16)
        hit = [i for i in items if i[0] <= x < i[0] + i[1]]
        print("%#x %s" % (x, "%s +%#x" % (hit[0][2], x - hit[0][0]) if hit else "kernel?"))
else:
    for i in items:
        print("%#x %#x %s" % i)
