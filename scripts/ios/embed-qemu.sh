#!/bin/bash
# Xcode 构建阶段（app/project.yml）：把 work/ios 下编好的 libqemu-arm-interp.dylib 和 libqemu-arm-jit.dylib
# 拷进 App 的 Frameworks 并用 App 的身份签名。App 启动时按有没有调试器选一个 dlopen。
# 改自上游 qemu-ios 的 contrib/ios-app/embed-qemu.sh（af4d255637，已删）；依赖全是静态库，不用再拷别的 dylib。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLATFORM="${PLATFORM_NAME:-iphoneos}"
DEST="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$DEST"
n=0
for tcg in interp jit; do
    lib="$ROOT/work/ios/build-qemu-$PLATFORM-$tcg/libqemu-arm-$tcg.dylib"
    if [ ! -f "$lib" ]; then
        echo "warning: 没有 $lib"
        continue
    fi
    out="$DEST/$(basename "$lib")"
    cp -f "$lib" "$out"
    chmod u+w "$out"
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" ${OTHER_CODE_SIGN_FLAGS:-} --timestamp=none "$out"
    n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "error: 没有编好的 qemu-ios dylib，先跑 scripts/ios/build-qemu.sh 和 make-dylib.sh" >&2; exit 1; }
echo "嵌入了 $n 个 qemu-ios dylib（$PLATFORM）"
