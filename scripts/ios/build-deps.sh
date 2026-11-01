#!/bin/bash
# 为 iOS 交叉编译 qemu-ios 需要的依赖，全部静态库，装进 work/ios/sysroot-<平台>-arm64。
# 模板是 LightTouchMac 的 build-support/recipes/build-package-native.sh（glib、pcre2、proxy-libintl、pixman、
# libslirp 及其两个补丁）和 build-static-deps.sh（OpenSSL、Nettle）；交叉参数参考 UTM 的
# scripts/build_dependencies.sh（-target arm64-apple-iosN、meson 交叉文件、needs_exe_wrapper）。
# 比 LightTouchMac 多编一个 libffi：iOS SDK 里没有 ffi 头文件（模拟器 SDK 连库都没有），glib 的 gobject 要它。
# 不编 FFmpeg（M1 不要声音和 H.264 视频）。
#
# 用法：scripts/ios/build-deps.sh iphoneos|iphonesimulator
# 先跑 scripts/ios/fetch-sources.sh。每个包装完在 sysroot/.stamps 留记号，重跑时跳过；FORCE=1 从头来。
set -euo pipefail
PLATFORM="${1:?用法：build-deps.sh iphoneos|iphonesimulator}"
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
    command -v "$tool" >/dev/null || { echo "缺构建工具：$tool" >&2; exit 1; }
done
if [ "${FORCE:-0}" = 1 ]; then rm -rf "$SYSROOT" "$BUILD"; fi
mkdir -p "$SYSROOT/lib/pkgconfig" "$SYSROOT/include" "$SYSROOT/.stamps" "$BUILD" "$LOGS"

export CC="$CLANG -target $TARGET -isysroot $SDK"
export CXX="$CLANGXX -target $TARGET -isysroot $SDK"
export AR RANLIB NM
export CFLAGS="-O2" CXXFLAGS="-O2" LDFLAGS=""
export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig" PKG_CONFIG_PATH=
# 照 LightTouchMac：有的 Darwin libtool 探测拿到空的 ARG_MAX，会走丢私有符号的分段链接。
export lt_cv_sys_max_cmd_len=131072

done_stamp() { [ -f "$SYSROOT/.stamps/$1" ]; }
stamp() { date > "$SYSROOT/.stamps/$1"; }
untar() {   # ARCHIVE：解到 BUILD 下，旧的解压目录先删
    local dir
    dir="$(tar -tf "$SRC/$1" | head -1 | cut -d/ -f1)"
    rm -rf "${BUILD:?}/$dir"
    tar -C "$BUILD" -xf "$SRC/$1"
}
license() {   # 名字 目录 文件...：许可证原文放进 sysroot/share/licenses/名字，GPL 分发时要随 App 带上
    local name="$1" dir="$2"; shift 2
    mkdir -p "$SYSROOT/share/licenses/$name"
    (cd "$dir" && cp "$@" "$SYSROOT/share/licenses/$name/")
}
run() {   # 日志名 命令...：输出进 logs，失败时打印末尾
    local log="$LOGS/$1.log"; shift
    if ! "$@" >> "$log" 2>&1; then
        echo "失败：$*（日志 $log）" >&2
        tail -40 "$log" >&2
        exit 1
    fi
}

# meson 交叉文件：host 是 darwin/ios（或 ios-simulator），测试程序不能在本机跑。
# glib 那几个只能靠运行来判断的属性，Darwin libc 的答案是确定的，直接写明。
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

echo "== $PLATFORM（$TARGET），sysroot：$SYSROOT"

# libffi：glib 的 gobject 用 ffi_call；Apple arm64 上 libffi 自己用静态跳板表，不要可执行内存。
if ! done_stamp libffi; then
    echo "-- libffi"
    untar libffi-3.8.0.tar.gz
    (cd "$BUILD/libffi-3.8.0" && run libffi ./configure --host=$HOST --prefix="$SYSROOT" \
        --disable-shared --enable-static --disable-docs --disable-multi-os-directory \
        && run libffi make -j"$JOBS" && run libffi make install)
    license libffi "$BUILD/libffi-3.8.0" LICENSE
    stamp libffi
fi

# pcre2：glib 的 GRegex。不开 pcre2 自己的 JIT（要可执行内存），pcre2grep 的 callout 会 fork，也关掉。
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

# glib（带 proxy-libintl 子项目）。照 LightTouchMac：配置到一个什么都没有的中立前缀，装到 stage 再搬进 sysroot，
# 免得 glib 把这台机器的构建路径编进库里。glib-pipe2-availability.patch 也照用：pipe2 按部署目标判断。
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

# libslirp 4.9.4 加 qemu-ios 的两个补丁（subprojects/slirp.wrap 的 diff_files 顺序）：slirp_set_restricted() 和
# slirp_add_guestfwd_connector()。qemu-ios 只认两个函数都有的 libslirp。
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

# OpenSSL 只要 libcrypto（ipod_touch_aes.c 的 AES、ipod_touch_pke.c 的 BIGNUM）。iOS 目标自带 no-async。
# 编进去的引擎和模块目录指向一个空目录，和 LightTouchMac 一样。
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

# Nettle：QEMU 11 去掉了内置 AES，qcrypto_cipher（iPod touch 1 代和 A4 机型的 CDMA AES）靠它。只要对称算法和哈希。
if ! done_stamp nettle; then
    echo "-- Nettle"
    untar nettle-3.10.2.tar.gz
    (cd "$BUILD/nettle-3.10.2" && run nettle ./configure --host=$HOST --prefix="$SYSROOT" --libdir="$SYSROOT/lib" \
        --disable-shared --enable-static --disable-public-key --disable-openssl --disable-documentation \
        && run nettle make -j"$JOBS" && run nettle make install)
    license nettle "$BUILD/nettle-3.10.2" COPYINGv2 COPYINGv3 COPYING.LESSERv3
    stamp nettle
fi

# zlib 用 SDK 自带的 libz.tbd。
cat > "$SYSROOT/lib/pkgconfig/zlib.pc" <<'EOF'
prefix=/usr
Name: zlib
Description: iOS SDK zlib
Version: 1.2.12
Libs: -lz
Cflags:
EOF

echo "== 装好的静态库："
ls "$SYSROOT/lib"/*.a
echo "== pkg-config："
for m in glib-2.0 pixman-1 slirp nettle libcrypto zlib libffi libpcre2-8; do
    printf '%-12s %s\n' "$m" "$(pkg-config --modversion "$m" 2>/dev/null || echo 缺)"
done
# 抽一个目标文件看平台号：iOS 是 2（IOS），模拟器是 7（IOSSIMULATOR）。
otool -lv "$SYSROOT/lib/libglib-2.0.a" 2>/dev/null | grep -m1 -A3 LC_BUILD_VERSION | grep -E 'platform|minos' || true
echo "依赖完成：$SYSROOT"
