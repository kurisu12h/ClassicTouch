# scripts/ios 下各脚本共用的平台设置。用法：PLATFORM=iphoneos|iphonesimulator; source common.sh
# 只在 Apple Silicon Mac 上交叉编译 arm64；最低系统版本跟上游 8 月的 build-ios.sh 一样是 iOS 16。

IOS_MIN="${IOS_MIN:-16.0}"
# 这台 Mac 同时在跑 M0 测速，并行度最多 8。
JOBS="${IOS_JOBS:-8}"
[[ "$JOBS" =~ ^[1-8]$ ]] || { echo "IOS_JOBS 只能是 1 到 8" >&2; exit 1; }

case "${PLATFORM:?}" in
    iphoneos)
        TARGET="arm64-apple-ios$IOS_MIN"
        MESON_SUBSYSTEM=ios
        OPENSSL_TARGET=ios64-xcrun
        ;;
    iphonesimulator)
        TARGET="arm64-apple-ios$IOS_MIN-simulator"
        MESON_SUBSYSTEM=ios-simulator
        OPENSSL_TARGET=iossimulator-arm64-xcrun
        ;;
    *) echo "平台只能是 iphoneos 或 iphonesimulator：$PLATFORM" >&2; exit 2 ;;
esac

IOS_ROOT="$ROOT/work/ios"
SDK="$(xcrun --sdk "$PLATFORM" --show-sdk-path)"
CLANG="$(xcrun -f clang)"
CLANGXX="$(xcrun -f clang++)"
AR="$(xcrun -f ar)"
RANLIB="$(xcrun -f ranlib)"
STRIP="$(xcrun -f strip)"
NM="$(xcrun -f nm)"
SYSROOT="$IOS_ROOT/sysroot-$PLATFORM-arm64"
# QEMU 的 configure 要 3.10 以上的 Python；和 M0 的 Mac 构建用同一个。
QEMU_PYTHON="${QEMU_PYTHON:-/opt/homebrew/opt/python@3.12/libexec/bin/python3}"

unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH MACOSX_DEPLOYMENT_TARGET
