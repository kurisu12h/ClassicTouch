#!/usr/bin/env python3
"""M0 workaround: a stand-in for the iPhoneOS 3.1.3 / 3.2 SDKs that qemu-ios' guest tools build against.

Upstream's contrib/armv6-toolchain only takes two things from those SDKs:
  * usr/include (C headers; cc6 passes -nostdinc -isystem $SDK/usr/include)
  * usr/lib/libSystem stub with an armv7 slice (link6: -syslibroot $SDK -L$SDK/usr/lib -lSystem)
The old SDKs are Apple downloads we are not allowed to fetch. This script builds the same two things from
the locally installed Xcode's iPhoneOS SDK: its headers (copied, with _FORTIFY_SOURCE forced off, because
the 3.x libSystem has no __*_chk entry points), and a flat text stub re-declaring every libSystem export
for armv7-ios. Nothing from the SDK is shipped: the stub only lets ld resolve names, dyld binds them on the
guest against the firmware's own libSystem.

usage: make-substitute-sdk.py OUT.sdk
"""
import os, re, shutil, subprocess, sys

out = sys.argv[1]
sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
inc = os.path.join(out, "usr", "include")
lib = os.path.join(out, "usr", "lib")
if os.path.exists(out):
    shutil.rmtree(out)
shutil.copytree(os.path.join(sdk, "usr", "include"), inc, symlinks=True)
subprocess.check_call(["chmod", "-R", "u+w", inc])
os.makedirs(lib)

# The compiler's own freestanding headers (stdbool.h, stdarg.h, stddef.h, float.h ...): the old SDKs' usr/include
# carried them, the modern SDK expects the compiler's, and cc6 compiles with -nostdinc.
res = os.path.join(subprocess.check_output(["xcrun", "clang", "-print-resource-dir"], text=True).strip(), "include")
for name in sorted(os.listdir(res)):
    if not name.endswith(".h") or os.path.exists(os.path.join(inc, name)):
        continue
    if re.match(r"^(std\w*|__std\w*|__float\w*|float|iso646|varargs|ptrauth)\.h$", name):
        shutil.copy(os.path.join(res, name), os.path.join(inc, name))

# _FORTIFY_SOURCE off by default: the 3.x/6.x libSystem lacks the __*_chk family on armv7 for 3.x.
cdefs = os.path.join(inc, "sys", "cdefs.h")
with open(cdefs) as f:
    text = f.read()
marker = "#ifndef _CDEFS_H_\n#define _CDEFS_H_\n"
assert marker in text, "unexpected sys/cdefs.h layout"
text = text.replace(marker, marker + "#ifndef _FORTIFY_SOURCE\n#define _FORTIFY_SOURCE 0 /* M0 substitute SDK */\n#endif\n", 1)
with open(cdefs, "w") as f:
    f.write(text)

# Every symbol any document of libSystem.B.tbd exports (libSystem re-exports libsystem_*), flattened.
with open(os.path.join(sdk, "usr", "lib", "libSystem.B.tbd")) as f:
    tbd = f.read()
syms = set()
for key in ("symbols", "weak-symbols", "thread-local-symbols"):
    for m in re.finditer(r"(?<![\w-])" + re.escape(key) + r":\s*\[(.*?)\]", tbd, re.S):
        for s in m.group(1).split(","):
            s = s.strip().strip("'\"")
            if s and not s.startswith("$ld$"):  # linker directives (hide-before-OS) would hide names
                syms.add(s)
syms = sorted(syms)
def q(s):
    return "'" + s.replace("'", "''") + "'"
stub = ["--- !tapi-tbd", "tbd-version: 4", "targets: [ armv7-ios ]",
        "install-name: '/usr/lib/libSystem.B.dylib'", "current-version: 111", "compatibility-version: 1",
        "exports:", "  - targets: [ armv7-ios ]", "    symbols: [ " + ", ".join(q(s) for s in syms) + " ]", "..."]
with open(os.path.join(lib, "libSystem.tbd"), "w") as f:
    f.write("\n".join(stub) + "\n")
# the guest-package scripts test for $SDK/usr/lib/libSystem.dylib
# (ld refuses a .tbd next to a non-Mach-O .dylib, but takes the text stub under the .dylib name: a symlink)
os.symlink("libSystem.tbd", os.path.join(lib, "libSystem.dylib"))
print(f"{out}: {len(syms)} libSystem symbols from {sdk}")
