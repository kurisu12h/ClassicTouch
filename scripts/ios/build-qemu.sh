#!/bin/bash
# 把 qemu-system-arm 交叉编译到 iOS 真机或 iOS 模拟器。之后 make-dylib.sh 把它重链成 App 能 dlopen 的 dylib。
#
# 改自上游 qemu-ios 的 contrib/ios-app/build-ios.sh（af4d255637，10-13 作为「Dead contrib tools」删掉）：
#   - 依赖用 build-deps.sh 自己编的 sysroot，不用 UTM CI 的预编译产物；
#   - 不要 TCTI（QEMU 11 上从来没编过，上游 10-08 已删）；
#   - QEMU 11 的写法：--without-default-features 再逐个打开要的（同 LightTouchMac 的 Mac 构建），
#     不再罗列一长串 --disable-xxx，选项改名也不怕；
#   - 宿主 GL 默认开（EAGL，ES 1.1 和 ES 2.0 按客体上下文分别建，patches/ios-eagl-es2.patch）。
#     HOST_GLES=disabled 编 stub（patches/ios-host-gles-option.patch），客体走软件合成，留作对照：
#     iOS 3、6 可以，iOS 7 的 SpringBoard 会反复崩溃、开不到锁屏（docs/reports/m1-stage4-ios7.md）。
#     stub 版默认放在 build-qemu-<平台>-<后端>-stub，和 GL 版分开；
#   - meson 子项目（dtc、keycodemapdb、berkeley-softfloat/testfloat）事先从 upstream/qemu-ios 本地复制到工作树，
#     meson 不会再去拉源码。不能用 --disable-download：configure 无条件要装 Python 的 tooling 组（qemu.qmp、
#     setuptools），离线时找不到就失败，所以和 M0 的 Mac 构建一样让 pip 从 PyPI 装这几个构建工具；
#   - PGO 那套先不带（M1 先求能开机）。
#
# TCG 后端用 TCG=jit（默认）或 TCG=interp 选，两份都要：
#   jit     原生 arm64 代码生成。iOS 上只有调试器挂着时才有可执行内存，App 要传 -accel tcg,split-wx=on。
#   interp  TCI 解释器，不要可执行内存，从主屏直接打开也能跑。
# 协程后端用 COROUTINE=sigaltstack（默认，上游 8 月真机跑过）或 ucontext。
#
# 用法：TCG=jit|interp [HOST_GLES=enabled|disabled] scripts/ios/build-qemu.sh iphoneos|iphonesimulator
# 输出：work/ios/build-qemu-<平台>-<后端>[-stub]/qemu-system-arm（链接产物，不能直接在 iOS 上跑）
set -euo pipefail
PLATFORM="${1:?用法：TCG=jit|interp build-qemu.sh iphoneos|iphonesimulator}"
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
    *) echo "HOST_GLES 只能是 enabled 或 disabled" >&2; exit 2 ;;
esac
BUILD="${BUILD_DIR:-$IOS_ROOT/build-qemu-$PLATFORM-$TCG$SUFFIX}"

case "$TCG" in
    jit) TCG_FLAGS=() ;;
    interp) TCG_FLAGS=(--enable-tcg-interpreter) ;;
    *) echo "TCG 只能是 jit 或 interp" >&2; exit 2 ;;
esac
[ -f "$QEMU/configure" ] || { echo "没有 QEMU 工作树：$QEMU（见 docs/reports/m1-stage1.md 的构建命令）" >&2; exit 1; }
[ -f "$SYSROOT/.stamps/nettle" ] || { echo "没有依赖 sysroot：$SYSROOT，先跑 build-deps.sh $PLATFORM" >&2; exit 1; }

# patches/ios-*.patch（按文件名顺序），再加 A5 的两个（a5-n78-skeleton：iPod touch 5 代机型和 GL 前端的 9.x 补充；
# a5-n78-ios-ui：App 桥里它的按键、熄屏判断和机型表，docs/reports/a5-app.md）打到工作树上。整套一起判断，不逐个
# 反向检查：几个补丁改同一个文件时（ios-eagl-es2 和 ios-gles-perf 都改 gles-host.c），单独反向检查前一个会失败。做法：在临时目录里取这些文件的
# 上游原样、按顺序打上全部补丁，和工作树一致就是已经打好；工作树还是原样就整套打上；两样都不是（工作树里有还没
# 导出成补丁的改动，或补丁换过）就停下。SKIP_PATCHES=1：工作树里正在改补丁（还没导出），不碰工作树。
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
    same() {   # 临时目录 $1 和工作树里这些文件是否一致（都没有也算）
        local f
        for f in "${patch_files[@]}"; do
            if [ -f "$1/$f" ] || [ -f "$QEMU/$f" ]; then cmp -s "$1/$f" "$QEMU/$f" || return 1; fi
        done
    }
    if same "$PT/b"; then
        :
    elif same "$PT/a"; then
        for patch in "${PATCHES[@]}"; do
            echo "打补丁 $(basename "$patch")"
            git -C "$QEMU" apply "$patch"
        done
    else
        rm -rf "$PT"
        echo "工作树 $QEMU 里补丁改过的文件既不是上游原样，也不是打完 patches/ios-*.patch 和 a5-n78-*.patch 的样子：" >&2
        echo "有还没导出成补丁的改动（用 scripts/ios/export-patch.sh 导出，或 SKIP_PATCHES=1 先照工作树编）" >&2
        exit 1
    fi
    rm -rf "$PT"
fi

export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig" PKG_CONFIG_PATH=
COMPILER="$CLANG -target $TARGET -isysroot $SDK"
mkdir -p "$BUILD"
cd "$BUILD"
if [ ! -f build.ninja ] || [ "${RECONFIGURE:-0}" = 1 ]; then
    # --cross-prefix=（空）让 configure 当作交叉编译又不给工具名加前缀；目标三元组放在 --cc 里。
    # 真机版的测试程序不能在本机跑，所以 CPU 要明说。
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
echo "编好：$BUILD/qemu-system-arm"
