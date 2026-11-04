#!/bin/bash
# Cross-compile qemu-system-arm for an iOS device or the iOS Simulator. make-dylib.sh then relinks it into a dylib the
# app can dlopen.
#
# Adapted from upstream qemu-ios's contrib/ios-app/build-ios.sh (af4d255637, deleted on 10-13 as "Dead contrib tools"):
#   - the dependencies come from the sysroot build-deps.sh builds, not UTM CI's prebuilt artifacts;
#   - no TCTI (it never built on QEMU 11; upstream deleted it on 10-08);
#   - the QEMU 11 way: --without-default-features, then enable what is needed one by one (as LightTouchMac's Mac
#     build does) instead of listing a long run of --disable-xxx, so renamed options do no harm;
#   - host GL on by default (EAGL, with ES 1.1 and ES 2.0 created separately per guest context,
#     patches/ios-eagl-es2.patch). HOST_GLES=disabled builds the stub (patches/ios-host-gles-option.patch) and the
#     guest composites in software, kept for comparison: fine for iOS 3 and 6, but iOS 7's SpringBoard crashes over
#     and over and never gets to the lock screen (docs/reports/m1-stage4-ios7.md). The stub build goes to
#     build-qemu-<platform>-<backend>-stub by default, apart from the GL build;
#   - the meson subprojects (dtc, keycodemapdb, berkeley-softfloat/testfloat) are copied from upstream/qemu-ios into
#     the work tree beforehand, so meson does not fetch sources. --disable-download cannot be used: configure always
#     installs Python's tooling group (qemu.qmp, setuptools) and fails offline when it cannot find them, so as in the
#     M0 Mac build pip installs these build tools from PyPI;
#   - no PGO for now (in M1 it first has to boot).
#
# The TCG backend is picked with TCG=jit (default) or TCG=interp; both are needed:
#   jit     native arm64 code generation. iOS has executable memory only while a debugger is attached; the app must
#           pass -accel tcg,split-wx=on.
#   interp  the TCI interpreter; needs no executable memory and also runs when opened straight from the home screen.
# The coroutine backend is picked with COROUTINE=sigaltstack (default, upstream ran it on a device in August) or
# ucontext.
#
# Usage: TCG=jit|interp [HOST_GLES=enabled|disabled] scripts/ios/build-qemu.sh iphoneos|iphonesimulator
# Output: work/ios/build-qemu-<platform>-<backend>[-stub]/qemu-system-arm (a link product; it cannot run on iOS as is)
set -euo pipefail
PLATFORM="${1:?usage: TCG=jit|interp build-qemu.sh iphoneos|iphonesimulator}"
TCG="${TCG:-jit}"
COROUTINE="${COROUTINE:-sigaltstack}"
HOST_GLES="${HOST_GLES:-enabled}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/common.sh"
QEMU="$IOS_ROOT/qemu-ios"
case "$HOST_GLES" in
    enabled) SUFFIX= ;;
    disabled) SUFFIX=-stub ;;
    *) echo "HOST_GLES must be enabled or disabled" >&2; exit 2 ;;
esac
BUILD="${BUILD_DIR:-$IOS_ROOT/build-qemu-$PLATFORM-$TCG$SUFFIX}"

case "$TCG" in
    jit) TCG_FLAGS=() ;;
    interp) TCG_FLAGS=(--enable-tcg-interpreter) ;;
    *) echo "TCG must be jit or interp" >&2; exit 2 ;;
esac
[ -f "$QEMU/configure" ] || { echo "No QEMU work tree: $QEMU (see the build commands in docs/reports/m1-stage1.md)" >&2; exit 1; }
[ -f "$SYSROOT/.stamps/nettle" ] || { echo "No dependency sysroot: $SYSROOT; run build-deps.sh $PLATFORM first" >&2; exit 1; }

# Apply patches/ios-*.patch (in file name order) plus the two A5 ones (a5-n78-skeleton: the iPod touch 5G machine and
# the 9.x additions to the GL front end; a5-n78-ios-ui: its buttons, screen-off check and machine table rows in the app
# bridge, docs/reports/a5-app.md) to the work tree. The set is checked as a whole, without reverse-checking each patch:
# when several patches change the same file (ios-eagl-es2 and ios-gles-perf both change gles-host.c), reverse-checking
# the earlier one alone fails. How: in a temporary directory, take these files as upstream has them and apply all the
# patches in order; if the work tree matches that, they are already applied; if the work tree is still pristine, apply
# the whole set; if it is neither (the work tree has changes not yet exported as patches, or the patches changed), stop.
# SKIP_PATCHES=1: a patch is being edited in the work tree (not exported yet); leave the work tree alone.
PATCHES=("$ROOT"/patches/ios-*.patch "$ROOT/patches/a5-n78-skeleton.patch" "$ROOT/patches/a5-n78-ios-ui.patch")
if [ "${SKIP_PATCHES:-0}" != 1 ]; then
    patch_files=()
    while IFS= read -r f; do patch_files+=("$f"); done < <(grep -h '^+++ b/' "${PATCHES[@]}" | sed 's|^+++ b/||' | sort -u)
    PT="$(mktemp -d)"
    for f in "${patch_files[@]}"; do
        mkdir -p "$PT/a/$(dirname "$f")" "$PT/b/$(dirname "$f")"
        if git -C "$QEMU" cat-file -e "HEAD:$f" 2>/dev/null; then
            git -C "$QEMU" show "HEAD:$f" > "$PT/a/$f"
            cp "$PT/a/$f" "$PT/b/$f"
        fi
    done
    for patch in "${PATCHES[@]}"; do (cd "$PT/b" && git apply "$patch"); done
    same() {   # whether these files in temporary directory $1 match the work tree (missing from both counts as a match)
        local f
        for f in "${patch_files[@]}"; do
            if [ -f "$1/$f" ] || [ -f "$QEMU/$f" ]; then cmp -s "$1/$f" "$QEMU/$f" || return 1; fi
        done
    }
    if same "$PT/b"; then
        :
    elif same "$PT/a"; then
        for patch in "${PATCHES[@]}"; do
            echo "Applying $(basename "$patch")"
            git -C "$QEMU" apply "$patch"
        done
    else
        rm -rf "$PT"
        echo "The files the patches touch in work tree $QEMU are neither upstream's originals nor the result of applying patches/ios-*.patch and a5-n78-*.patch:" >&2
        echo "there are changes not yet exported as patches (export them with scripts/ios/export-patch.sh, or build the work tree as it is with SKIP_PATCHES=1)" >&2
        exit 1
    fi
    rm -rf "$PT"
fi

export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig" PKG_CONFIG_PATH=
COMPILER="$CLANG -target $TARGET -isysroot $SDK"
mkdir -p "$BUILD"
cd "$BUILD"
if [ ! -f build.ninja ] || [ "${RECONFIGURE:-0}" = 1 ]; then
    # --cross-prefix= (empty) makes configure treat this as a cross build without prefixing the tool names; the target
    # triple goes in --cc.
    # The device build's test programs cannot run on this machine, so the CPU has to be given explicitly.
    "$QEMU/configure" \
        --cross-prefix= \
        --cpu=aarch64 \
        --cc="$COMPILER" \
        --cxx="$CLANGXX -target $TARGET -isysroot $SDK" \
        --objcc="$COMPILER" \
        --host-cc=/usr/bin/clang \
        --python="$QEMU_PYTHON" \
        --target-list=arm-softmmu \
        --without-default-features \
        --enable-pixman --enable-slirp --enable-nettle \
        ${TCG_FLAGS[@]+"${TCG_FLAGS[@]}"} \
        --with-coroutine="$COROUTINE" \
        --enable-trace-backends=nop \
        --disable-werror \
        -Dhost_gles="$HOST_GLES" \
        --extra-cflags="-I$SYSROOT/include -fmacro-prefix-map=$QEMU/= -fmacro-prefix-map=$BUILD/=" \
        --extra-ldflags="-L$SYSROOT/lib $SYSROOT/lib/libcrypto.a"
fi
ninja -j"$JOBS" qemu-system-arm
echo "Built: $BUILD/qemu-system-arm"
