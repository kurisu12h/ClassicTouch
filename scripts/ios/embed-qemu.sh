#!/bin/bash
# Xcode build phase (app/project.yml): copy libqemu-arm-interp.dylib and libqemu-arm-jit.dylib, built under work/ios,
# into the app's Frameworks and sign them with the app's identity. At launch the app dlopens one of them depending on
# whether a debugger is attached.
# Adapted from upstream qemu-ios's contrib/ios-app/embed-qemu.sh (af4d255637, since deleted); the dependencies are all
# static libraries, so no other dylib has to be copied.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLATFORM="${PLATFORM_NAME:-iphoneos}"
DEST="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$DEST"
n=0
for tcg in interp jit; do
    lib="$ROOT/work/ios/build-qemu-$PLATFORM-$tcg/libqemu-arm-$tcg.dylib"
    if [ ! -f "$lib" ]; then
        echo "warning: $lib is missing"
        continue
    fi
    out="$DEST/$(basename "$lib")"
    cp -f "$lib" "$out"
    chmod u+w "$out"
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" ${OTHER_CODE_SIGN_FLAGS:-} --timestamp=none "$out"
    n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "error: no qemu-ios dylib has been built; run scripts/ios/build-qemu.sh and make-dylib.sh first" >&2; exit 1; }
echo "Embedded $n qemu-ios dylib(s) ($PLATFORM)"
