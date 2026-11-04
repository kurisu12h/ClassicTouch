#!/bin/bash
# Cross-compile the dependencies qemu-ios needs for iOS, all as static libraries, into work/ios/sysroot-<platform>-arm64.
# Modeled on LightTouchMac's build-support/recipes/build-package-native.sh (glib, pcre2, proxy-libintl, pixman,
# libslirp and its two patches) and build-static-deps.sh (OpenSSL, Nettle); the cross settings follow UTM's
# scripts/build_dependencies.sh (-target arm64-apple-iosN, a meson cross file, needs_exe_wrapper).
# One more library than LightTouchMac builds, libffi: the iOS SDK has no ffi headers (the Simulator SDK not even the
# library), and glib's gobject needs it.
# No FFmpeg (M1 needs neither sound nor H.264 video).
#
# Usage: scripts/ios/build-deps.sh iphoneos|iphonesimulator
# Run scripts/ios/fetch-sources.sh first. Each package leaves a stamp in sysroot/.stamps once installed and is skipped
# on later runs; FORCE=1 starts over.
set -euo pipefail
PLATFORM="${1:?usage: build-deps.sh iphoneos|iphonesimulator}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/common.sh"
SRC="$IOS_ROOT/src"
BUILD="$IOS_ROOT/deps-build/$PLATFORM"
LOGS="$IOS_ROOT/logs/deps-$PLATFORM"
LTM="$ROOT/upstream/LightTouchMac"
QEMU_SRC="$ROOT/upstream/qemu-ios"
HOST=aarch64-apple-darwin

for tool in meson ninja pkg-config make perl m4; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
if [ "${FORCE:-0}" = 1 ]; then rm -rf "$SYSROOT" "$BUILD"; fi
mkdir -p "$SYSROOT/lib/pkgconfig" "$SYSROOT/include" "$SYSROOT/.stamps" "$BUILD" "$LOGS"

export CC="$CLANG -target $TARGET -isysroot $SDK"
export CXX="$CLANGXX -target $TARGET -isysroot $SDK"
export AR RANLIB NM
export CFLAGS="-O2" CXXFLAGS="-O2" LDFLAGS=""
export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig" PKG_CONFIG_PATH=
# As in LightTouchMac: some Darwin libtool probes get an empty ARG_MAX and take the piecewise link that loses private
# symbols.
export lt_cv_sys_max_cmd_len=131072

done_stamp() { [ -f "$SYSROOT/.stamps/$1" ]; }
stamp() { date > "$SYSROOT/.stamps/$1"; }
untar() {   # ARCHIVE: extract under BUILD, deleting the old extracted directory first
    local dir
    dir="$(tar -tf "$SRC/$1" | head -1 | cut -d/ -f1)"
    rm -rf "${BUILD:?}/$dir"
    tar -C "$BUILD" -xf "$SRC/$1"
}
license() {   # NAME DIR FILE...: copy the license texts into sysroot/share/licenses/NAME; GPL distribution must ship them with the app
    local name="$1" dir="$2"; shift 2
    mkdir -p "$SYSROOT/share/licenses/$name"
    (cd "$dir" && cp "$@" "$SYSROOT/share/licenses/$name/")
}
run() {   # LOG_NAME COMMAND...: output goes to logs; on failure print the tail
    local log="$LOGS/$1.log"; shift
    if ! "$@" >> "$log" 2>&1; then
        echo "Failed: $* (log $log)" >&2
        tail -40 "$log" >&2
        exit 1
    fi
}

# meson cross file: the host is darwin/ios (or ios-simulator), and test programs cannot run on this machine.
# The glib properties that can only be found by running a program have known answers for Darwin libc, so they are
# stated here.
CROSS="$BUILD/cross.meson"
cat > "$CROSS" <<EOF
[binaries]
c = ['$CLANG', '-target', '$TARGET', '-isysroot', '$SDK']
cpp = ['$CLANGXX', '-target', '$TARGET', '-isysroot', '$SDK']
objc = ['$CLANG', '-target', '$TARGET', '-isysroot', '$SDK']
ar = '$AR'
ranlib = '$RANLIB'
nm = '$NM'
strip = ['$STRIP', '-x']
pkg-config = '$(command -v pkg-config)'

[properties]
needs_exe_wrapper = true
pkg_config_libdir = ['$SYSROOT/lib/pkgconfig']
have_c99_vsnprintf = true
have_c99_snprintf = true
have_unix98_printf = true
have_strlcpy = true
growing_stack = false
have_proc_self_cmdline = false

[host_machine]
system = 'darwin'
subsystem = '$MESON_SUBSYSTEM'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
MESON_COMMON=(--cross-file "$CROSS" --buildtype=release -Ddefault_library=static)

echo "== $PLATFORM ($TARGET), sysroot: $SYSROOT"

# libffi: glib's gobject uses ffi_call; on Apple arm64 libffi uses its own static trampoline table and needs no
# executable memory.
if ! done_stamp libffi; then
    echo "-- libffi"
    untar libffi-3.8.0.tar.gz
    (cd "$BUILD/libffi-3.8.0" && run libffi ./configure --host=$HOST --prefix="$SYSROOT" \
        --disable-shared --enable-static --disable-docs --disable-multi-os-directory \
        && run libffi make -j"$JOBS" && run libffi make install)
    license libffi "$BUILD/libffi-3.8.0" LICENSE
    stamp libffi
fi

# pcre2: glib's GRegex. pcre2's own JIT stays off (it needs executable memory); pcre2grep's callout forks, so it is off
# too.
if ! done_stamp pcre2; then
    echo "-- pcre2"
    untar pcre2-10.48.tar.bz2
    (cd "$BUILD/pcre2-10.48" && run pcre2 ./configure --host=$HOST --prefix="$SYSROOT" \
        --disable-shared --enable-static --disable-pcre2grep-libz --disable-pcre2grep-libbz2 \
        --disable-pcre2grep-callout --disable-pcre2grep-callout-fork \
        && run pcre2 make -j"$JOBS" && run pcre2 make install)
    license pcre2 "$BUILD/pcre2-10.48" LICENCE.md
    stamp pcre2
fi

# glib (with the proxy-libintl subproject). As in LightTouchMac: configure for an empty neutral prefix, install into
# stage, then move it into the sysroot, so glib does not build this machine's build paths into the libraries.
# glib-pipe2-availability.patch is used as well: pipe2 is decided by the deployment target.
if ! done_stamp glib; then
    echo "-- glib"
    untar glib-2.88.3.tar.xz
    tar -xf "$SRC/proxy-libintl-0.5.tar.gz" -C "$BUILD/glib-2.88.3/subprojects"
    (cd "$BUILD/glib-2.88.3" && run glib patch -p1 < "$LTM/build-support/patches/glib-pipe2-availability.patch")
    NEUTRAL=/var/empty
    rm -rf "$BUILD/glib-out" "$BUILD/stage"
    run glib meson setup "$BUILD/glib-out" "$BUILD/glib-2.88.3" "${MESON_COMMON[@]}" --prefix="$NEUTRAL" \
        -Dnls=disabled -Dtests=false -Dintrospection=disabled -Dman-pages=disabled -Dlibmount=disabled \
        -Dselinux=disabled -Dsysprof=disabled -Dlibelf=disabled -Ddocumentation=false --wrap-mode=nodownload
    run glib ninja -C "$BUILD/glib-out" -j"$JOBS"
    run glib env DESTDIR="$BUILD/stage" ninja -C "$BUILD/glib-out" install
    for pc in "$BUILD/stage$NEUTRAL"/lib/pkgconfig/*.pc; do sed -i '' "s|$NEUTRAL|$SYSROOT|g" "$pc"; done
    cp -R "$BUILD/stage$NEUTRAL/." "$SYSROOT/"
    rm -rf "$BUILD/stage"
    license glib "$BUILD/glib-2.88.3" COPYING
    cp "$LTM/build-support/patches/glib-pipe2-availability.patch" "$SYSROOT/share/licenses/glib/"
    license proxy-libintl "$BUILD/glib-2.88.3/subprojects/proxy-libintl-0.5" COPYING
    stamp glib
fi

if ! done_stamp pixman; then
    echo "-- pixman"
    untar pixman-0.46.4.tar.gz
    rm -rf "$BUILD/pixman-out"
    run pixman meson setup "$BUILD/pixman-out" "$BUILD/pixman-0.46.4" "${MESON_COMMON[@]}" --prefix="$SYSROOT" \
        -Dtests=disabled -Ddemos=disabled -Dgtk=disabled -Dlibpng=disabled -Dopenmp=disabled --wrap-mode=nofallback
    run pixman ninja -C "$BUILD/pixman-out" -j"$JOBS"
    run pixman ninja -C "$BUILD/pixman-out" install
    license pixman "$BUILD/pixman-0.46.4" COPYING
    stamp pixman
fi

# libslirp 4.9.4 plus qemu-ios's two patches (in the diff_files order of subprojects/slirp.wrap): slirp_set_restricted()
# and slirp_add_guestfwd_connector(). qemu-ios only accepts a libslirp that has both functions.
if ! done_stamp slirp; then
    echo "-- libslirp"
    untar libslirp-v4.9.4.tar.gz
    for name in libslirp-set-restricted.patch libslirp-guestfwd-connector.patch; do
        (cd "$BUILD/libslirp-v4.9.4" && run slirp patch -p1 < "$QEMU_SRC/subprojects/packagefiles/$name")
    done
    rm -rf "$BUILD/slirp-out"
    run slirp meson setup "$BUILD/slirp-out" "$BUILD/libslirp-v4.9.4" "${MESON_COMMON[@]}" --prefix="$SYSROOT" \
        --wrap-mode=nofallback
    run slirp ninja -C "$BUILD/slirp-out" -j"$JOBS"
    run slirp ninja -C "$BUILD/slirp-out" install
    license libslirp "$BUILD/libslirp-v4.9.4" COPYRIGHT LICENSE
    cp "$QEMU_SRC"/subprojects/packagefiles/libslirp-*.patch "$SYSROOT/share/licenses/libslirp/"
    stamp slirp
fi

# OpenSSL: only libcrypto (the AES in ipod_touch_aes.c, the BIGNUM in ipod_touch_pke.c). The iOS targets imply no-async.
# The built-in engine and module directories point at an empty directory, as in LightTouchMac.
if ! done_stamp openssl; then
    echo "-- OpenSSL"
    untar openssl-3.6.3.tar.gz
    (cd "$BUILD/openssl-3.6.3" && run openssl ./Configure "$OPENSSL_TARGET" no-shared no-tests no-docs no-apps \
        no-ui-console --prefix="$SYSROOT" --libdir=lib --openssldir=/private/etc/ssl \
        && run openssl make -j"$JOBS" build_libs ENGINESDIR=/var/empty/lib/engines-3 \
            MODULESDIR=/var/empty/lib/ossl-modules \
        && run openssl make install_dev)
    license openssl "$BUILD/openssl-3.6.3" LICENSE.txt
    stamp openssl
fi

# Nettle: QEMU 11 dropped its built-in AES, and qcrypto_cipher (the CDMA AES of the iPod touch 1G and the A4 machines)
# relies on it. Only the symmetric ciphers and hashes are needed.
if ! done_stamp nettle; then
    echo "-- Nettle"
    untar nettle-3.10.2.tar.gz
    (cd "$BUILD/nettle-3.10.2" && run nettle ./configure --host=$HOST --prefix="$SYSROOT" --libdir="$SYSROOT/lib" \
        --disable-shared --enable-static --disable-public-key --disable-openssl --disable-documentation \
        && run nettle make -j"$JOBS" && run nettle make install)
    license nettle "$BUILD/nettle-3.10.2" COPYINGv2 COPYINGv3 COPYING.LESSERv3
    stamp nettle
fi

# zlib comes from the SDK's libz.tbd.
cat > "$SYSROOT/lib/pkgconfig/zlib.pc" <<'EOF'
prefix=/usr
Name: zlib
Description: iOS SDK zlib
Version: 1.2.12
Libs: -lz
Cflags:
EOF

echo "== Installed static libraries:"
ls "$SYSROOT/lib"/*.a
echo "== pkg-config:"
for m in glib-2.0 pixman-1 slirp nettle libcrypto zlib libffi libpcre2-8; do
    printf '%-12s %s\n' "$m" "$(pkg-config --modversion "$m" 2>/dev/null || echo missing)"
done
# Check the platform number of one object file: 2 (IOS) for iOS, 7 (IOSSIMULATOR) for the Simulator.
otool -lv "$SYSROOT/lib/libglib-2.0.a" 2>/dev/null | grep -m1 -A3 LC_BUILD_VERSION | grep -E 'platform|minos' || true
echo "Dependencies done: $SYSROOT"
