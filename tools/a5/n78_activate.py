#!/usr/bin/env python3
"""Local activation for 7.1.2 (11D257) on the iPod touch 5 (n78): what FirmwareKit's CActivation does to the A4
boards' lockdownd, whose pattern matcher does not recognize this build's code ("no supported activation path").

    n78_activate.py LOCKDOWND      (the file on a mounted system volume; patched in place, owner and mode kept)

lockdownd's dealwith_activation (0xfecc) short-circuits the activation state to Activated ("Short circuiting
activation state to Activated.") when its device-type check (0x22180, MobileGestalt ShouldHactivate or a DEV
hw.model) answers 1: `bl 0x22180; cmp r0, #1; bne 0xfffc` at 0xff14. The bne (file offset 0xef1a, __TEXT at VA
0x1000) becomes a nop, so the short circuit always runs, unless the data ark says DisableHactivation. Nothing
talks to Apple; the code signature is left stale (the kboot boot-args amfi_allow_any_signature=1 and
cs_enforcement_disable=1 let it run).
"""
import hashlib, sys

STOCK_SHA1 = "261017f56cfedbeded65b996a549d02a7a1fbbed"
OFF, BEFORE, AFTER = 0xef18, bytes.fromhex("01286fd1"), bytes.fromhex("012800bf")   # cmp r0,#1; bne -> nop

path = sys.argv[1]
with open(path, "r+b") as f:
    data = f.read()
    if data[OFF:OFF + 4] == AFTER:
        print("already patched")
        sys.exit(0)
    if hashlib.sha1(data).hexdigest() != STOCK_SHA1 or data[OFF:OFF + 4] != BEFORE:
        sys.exit("not 11D257 n78's stock lockdownd")
    f.seek(OFF)
    f.write(AFTER)
print("patched: bne at 0xff1a (file 0xef1a) -> nop")
