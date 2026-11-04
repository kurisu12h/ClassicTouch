#!/bin/bash
# Relink the qemu-system-arm built by build-qemu.sh into a dylib an iOS app can dlopen: libqemu-arm-<jit|interp>.dylib.
#
# Adapted from upstream qemu-ios's contrib/ios-app/make-dylib.sh (af4d255637, since deleted) and the current
# contrib/macos-app/make-dylib-macos.sh: it takes the command line ninja uses to link qemu-system-arm, so it cannot
# drift from the real build, and replaces system/main.c (its main() takes the main thread to run CFRunLoopRun) with
# contrib/ios-app/qemu-ios-entry.c, so the app calls qemu_ios_main() on a background thread. Compared with the August
# iOS version:
#   - it also links in contrib/macos-app/qemu-macos-extras.c (plain C, no macOS-only code) and exports exactly the same
#     ABI as the Mac build, so pause, quit, two-finger touch, rotation, the version number and so on are ready when the
#     app needs them;
#   - no more -undefined dynamic_lookup: a missing symbol is reported at link time instead of crashing halfway through
#     a run on the phone;
#   - the compiler and CPU are read from meson-info (as the Mac build does) instead of a hand-written -target.
#
# Usage: TCG=jit|interp [HOST_GLES=enabled|disabled] scripts/ios/make-dylib.sh iphoneos|iphonesimulator
# HOST_GLES=disabled takes the stub build from build-qemu.sh (build-qemu-<platform>-<backend>-stub).
set -euo pipefail
PLATFORM="${1:?usage: TCG=jit|interp make-dylib.sh iphoneos|iphonesimulator}"
TCG="${TCG:-jit}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/common.sh"
QEMU="$IOS_ROOT/qemu-ios"
case "${HOST_GLES:-enabled}" in
    enabled) SUFFIX= ;;
    disabled) SUFFIX=-stub ;;
    *) echo "HOST_GLES must be enabled or disabled" >&2; exit 2 ;;
esac
BUILD="${BUILD_DIR:-$IOS_ROOT/build-qemu-$PLATFORM-$TCG$SUFFIX}"
LIBNAME="libqemu-arm-$TCG.dylib"
OUT="$BUILD/$LIBNAME"
export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig" PKG_CONFIG_PATH=

cd "$BUILD"
DEP_CFLAGS="$(pkg-config --cflags glib-2.0 pixman-1)"
eval "CC_ARGV=($(jq -r '.host.c.exelist | @sh' meson-info/intro-compilers.json))"
case "$TCG" in
    jit) TCG_HOST=aarch64 ;;
    interp) TCG_HOST=tci ;;
    *) echo "TCG must be jit or interp" >&2; exit 2 ;;
esac
for f in "$QEMU/contrib/ios-app/qemu-ios-entry.c" \
         "$QEMU/contrib/ios-app/qemu-ios-ui.c" \
         "$QEMU/contrib/macos-app/qemu-macos-extras.c"; do
    o="$(basename "${f%.c}").o"
    "${CC_ARGV[@]}" -c "$f" -o "$o" \
        -I. -I.. -Iqapi -Itrace -Iui \
        -I"$QEMU/contrib/ios-app" -I"$QEMU/contrib/macos-app" \
        $DEP_CFLAGS \
        -iquote . -iquote "$QEMU" -iquote "$QEMU/include" \
        -iquote "$QEMU/host/include/aarch64" -iquote "$QEMU/host/include/generic" \
        -iquote "$QEMU/tcg/$TCG_HOST" \
        -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -std=gnu11 -O2 \
        -fmacro-prefix-map="$QEMU/=" -fmacro-prefix-map="$BUILD/="
done

ninja qemu-system-arm >/dev/null
eval "LINK=($(ninja -t commands qemu-system-arm-unsigned | tail -1))"
ARGS=()
skip=0
for a in "${LINK[@]}"; do
    if [ $skip = 1 ]; then skip=0; continue; fi
    case "$a" in
        -o) skip=1 ;;                                          # drop the executable name
        *system_main.c.o) ARGS+=(qemu-ios-entry.o qemu-ios-ui.o qemu-macos-extras.o) ;;
        @*) ;;   # @block.syms / @qemu.syms export symbols for the executable; the dylib exports only the app ABI
        *) ARGS+=("$a") ;;
    esac
done
ARGS+=(-dynamiclib -o "$OUT" -install_name "@rpath/$LIBNAME"
      "-Wl,-exported_symbols_list,$BUILD/ios-exports.syms")
printf '%q ' "${ARGS[@]}" > ios-link-dylib.sh
echo >> ios-link-dylib.sh

# Export list = all of make-dylib-macos.sh's macos-exports.syms, plus the two the August iOS build exported that the
# Mac build does not need (qemu_ios_set_foreground: iOS foreground/background; qemu_ios_ui_frame_size). Everything else
# stays private, which also avoids clashing with the host app's symbols.
sed -n '/^cat > macos-exports.syms/,/^SYMS$/p' "$QEMU/contrib/macos-app/make-dylib-macos.sh" \
    | sed '1d;$d' > ios-exports.syms
[ "$(wc -l < ios-exports.syms)" -gt 40 ] || { echo "Did not get the export list from make-dylib-macos.sh" >&2; exit 1; }
printf '%s\n' _qemu_ios_set_foreground _qemu_ios_ui_frame_size >> ios-exports.syms

bash ios-link-dylib.sh
codesign -f -s - "$OUT"
echo "Built: $OUT"
otool -L "$OUT"
echo "Exports $(nm -gU "$OUT" | grep -c ' T _qemu_ios_') qemu_ios_* functions"
