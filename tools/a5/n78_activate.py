#!/usr/bin/env python3
"""Local activation for the iPod touch 5 (n78) and the iPhone 5 (n41): what FirmwareKit's CActivation does to the
A4 boards' lockdownd, whose pattern matcher does not recognize these builds' code ("no supported activation path").

    n78_activate.py FILE      (the file on a mounted system volume; patched in place, owner and mode kept)

dealwith_activation short-circuits the activation state to Activated when its device-type check (MobileGestalt
ShouldHactivate, or a DEV hw.model) answers 1, unless the data ark says DisableHactivation. The check's
`cmp r0, #1; bne` becomes `cmp r0, #1; nop`, so the short circuit always runs:

    11D257 (7.1.2)  /usr/libexec/lockdownd           dealwith_activation 0xfecc, bne at 0xff1a (file 0xef1a)
    13G36 (9.3.5)   /usr/libexec/mobileactivationd   dealwith_activation 0xb428, bne at 0xb448 (file 0x7448);
                    from 8.x lockdownd asks mobileactivationd (MAEGate_GetActivationState)
    14G61 (10.3.4)  /usr/libexec/mobileactivationd   the check is -[DeviceType should_hactivate] (0x245e6, file
                    0x205e6), a property getter: it becomes movs r0, #1; bx lr

Each stock file is recognized by its SHA-1 and the four bytes at the patch; a patched one by the patch and, for
14G61 (signed again, so its SHA-1 is new each time), the 12 bytes after it. Nothing talks to Apple. Up to 9.x the
code signature is left stale (the kboot boot-args amfi_allow_any_signature=1 and cs_enforcement_disable=1 let it
run); 10.x's AMFI kills a page that does not match, so n78_diskfix.sh signs the patched file again (ad hoc, same
entitlements) and the new CDHash goes into the kernel's trust cache (n41_trustcache.py).
"""
import hashlib, sys

CMP_BNE_NOP = "012800bf"                               # cmp r0,#1; nop
RET_YES = "01207047"                                   # movs r0,#1; bx lr
STOCK = {   # sha1 -> (name, file offset, the stock bytes there, what they become)
    "261017f56cfedbeded65b996a549d02a7a1fbbed": ("11D257 lockdownd, bne at 0xff1a", 0xef18, "01286fd1", CMP_BNE_NOP),
    "b2f628f369e265a0a62317658d55f59cb7c7a22b": ("13G36 mobileactivationd, bne at 0xb448", 0x7446, "012803d1",
                                                 CMP_BNE_NOP),
    "8f3a3b82f47febaea79fea8f189ebbafadd96156": ("14G61 mobileactivationd, should_hactivate at 0x245e6", 0x205e6,
                                                 "42f25231", RET_YES),
}
FOLLOW = {"8f3a3b82f47febaea79fea8f189ebbafadd96156": "c0f217017944096840567047"}   # the stock bytes after the patch

path = sys.argv[1]
with open(path, "r+b") as f:
    data = f.read()
    for sha, (name, off, before, after) in STOCK.items():
        if data[off:off + 4] == bytes.fromhex(after) and len(data) > off + 4:
            stock = bytearray(data)
            stock[off:off + 4] = bytes.fromhex(before)
            if hashlib.sha1(stock).hexdigest() in STOCK or \
                    (sha in FOLLOW and data[off + 4:off + 16] == bytes.fromhex(FOLLOW[sha])):
                print("already patched (%s)" % name)
                sys.exit(0)
    hit = STOCK.get(hashlib.sha1(data).hexdigest())
    if not hit or data[hit[1]:hit[1] + 4] != bytes.fromhex(hit[2]):
        sys.exit("not a stock lockdownd (11D257) or mobileactivationd (13G36, 14G61)")
    name, off, _, after = hit
    f.seek(off)
    f.write(bytes.fromhex(after))
print("patched: %s -> %s" % (name, after))
