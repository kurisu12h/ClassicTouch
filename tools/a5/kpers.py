#!/usr/bin/env python3
"""kpers.py KERNEL [SUBSTR...]: print IOKitPersonalities (and OSBundleLibraries) of prelinked kexts whose bundle id contains SUBSTR."""
import os, re, sys, plistlib
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "imgtools"))
from macho import Macho
path = sys.argv[1]
m = Macho(path); d = open(path, "rb").read()
_, vm, _, fo, fs, _ = [s for s in m.segs if s[0] == '__PRELINK_INFO'][0]
info = d[fo:fo + fs].split(b'\0')[0].decode('latin1')
# resolve ID/IDREF: record every element carrying ID="n", then substitute IDREF="n"/> with the full element
ids = {}
for mm in re.finditer(r'<(integer|string|data|true|false|dict|array)([^>]*?) ID="(\d+)"([^>]*?)>([^<]*)</\1>', info):
    ids[mm.group(3)] = '<%s%s%s>%s</%s>' % (mm.group(1), mm.group(2), mm.group(4), mm.group(5), mm.group(1))
info = re.sub(r'<(\w+)[^>]*IDREF="(\d+)"\s*/>', lambda mm: ids.get(mm.group(2), '<string>?</string>'), info)
info = re.sub(r' ID="\d+"', '', info)
info = re.sub(r'<integer size="\d+">', '<integer>', info)
info = re.sub(r'<integer>0x([0-9a-fA-F]+)</integer>', lambda mm: '<integer>%d</integer>' % int(mm.group(1), 16), info)
if not info.startswith('<?xml'):
    info = '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0">' + info + '</plist>'
p = plistlib.loads(info.encode('latin1'))
for k in p['_PrelinkInfoDictionary']:
    b = k.get('CFBundleIdentifier', '')
    if any(s in b for s in sys.argv[2:]):
        print('==', b, hex(k.get('_PrelinkExecutableLoadAddr', 0)))
        for n, pers in (k.get('IOKitPersonalities') or {}).items():
            print('  [%s]' % n, {x: y for x, y in pers.items() if x not in ('CFBundleIdentifier',)})
        print('  libs:', list((k.get('OSBundleLibraries') or {}).keys()))
