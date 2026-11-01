#!/bin/bash
# 把 build-qemu.sh 编好的 qemu-system-arm 重链成 iOS App 能 dlopen 的 dylib：libqemu-arm-<jit|interp>.dylib。
#
# 改自上游 qemu-ios 的 contrib/ios-app/make-dylib.sh（af4d255637，已删）和现行的
# contrib/macos-app/make-dylib-macos.sh：取 ninja 链接 qemu-system-arm 的那一行命令，不会和真正的构建脱节；
# 把 system/main.c（main() 要占主线程跑 CFRunLoopRun）换成 contrib/ios-app/qemu-ios-entry.c，App 在后台线程
# 调 qemu_ios_main()。和 8 月的 iOS 版相比：
#   - 也链进 contrib/macos-app/qemu-macos-extras.c（纯 C，没有 macOS 专用代码），导出和 Mac 版完全相同的 ABI，
#     以后 App 要的暂停、退出、双指、旋转、版本号等都现成；
#   - 不再用 -undefined dynamic_lookup：少了符号要在链接时报出来，而不是在手机上运行到一半才崩；
#   - 编译器和 CPU 从 meson-info 读（Mac 版的做法），不再手写 -target。
#
# 用法：TCG=jit|interp [HOST_GLES=enabled|disabled] scripts/ios/make-dylib.sh iphoneos|iphonesimulator
# HOST_GLES=disabled 取 build-qemu.sh 编的 stub 版（build-qemu-<平台>-<后端>-stub）。
set -euo pipefail
PLATFORM="${1:?用法：TCG=jit|interp make-dylib.sh iphoneos|iphonesimulator}"
TCG="${TCG:-jit}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/common.sh"
QEMU="$IOS_ROOT/qemu-ios"
case "${HOST_GLES:-enabled}" in
    enabled) SUFFIX= ;;
    disabled) SUFFIX=-stub ;;
    *) echo "HOST_GLES 只能是 enabled 或 disabled" >&2; exit 2 ;;
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
    *) echo "TCG 只能是 jit 或 interp" >&2; exit 2 ;;
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
        -o) skip=1 ;;                                          # 去掉可执行文件名
        *system_main.c.o) ARGS+=(qemu-ios-entry.o qemu-ios-ui.o qemu-macos-extras.o) ;;
        @*) ;;   # @block.syms / @qemu.syms 是给可执行文件导出符号的；dylib 只导出 App ABI
        *) ARGS+=("$a") ;;
    esac
done
ARGS+=(-dynamiclib -o "$OUT" -install_name "@rpath/$LIBNAME"
      "-Wl,-exported_symbols_list,$BUILD/ios-exports.syms")
printf '%q ' "${ARGS[@]}" > ios-link-dylib.sh
echo >> ios-link-dylib.sh

# 导出表 = make-dylib-macos.sh 的 macos-exports.syms 全部，加上 8 月 iOS 版导出、Mac 版不需要的两个
# （qemu_ios_set_foreground：iOS 前后台；qemu_ios_ui_frame_size）。其余全部私有，也免得和宿主 App 的符号撞名。
sed -n '/^cat > macos-exports.syms/,/^SYMS$/p' "$QEMU/contrib/macos-app/make-dylib-macos.sh" \
    | sed '1d;$d' > ios-exports.syms
[ "$(wc -l < ios-exports.syms)" -gt 40 ] || { echo "没从 make-dylib-macos.sh 取到导出表" >&2; exit 1; }
printf '%s\n' _qemu_ios_set_foreground _qemu_ios_ui_frame_size >> ios-exports.syms

bash ios-link-dylib.sh
codesign -f -s - "$OUT"
echo "编好：$OUT"
otool -L "$OUT"
echo "导出 $(nm -gU "$OUT" | grep -c ' T _qemu_ios_') 个 qemu_ios_* 函数"
