#!/usr/bin/env python3
"""kstr.py KERNEL START SIZE [MINLEN]: printable strings in a VA range with their addresses."""
import os, re, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "imgtools"))
from macho import Macho
m = Macho(sys.argv[1]); d = open(sys.argv[1], "rb").read()
a, z = int(sys.argv[2], 16), int(sys.argv[3], 16); n = int(sys.argv[4]) if len(sys.argv) > 4 else 5
o = m.va2off(a)
for mm in re.finditer(rb'[\x20-\x7e\t\n]{%d,}' % n, d[o:o + z]):
    print("%#x %s" % (a + mm.start(), mm.group().decode().replace("\n", "\\n")))
