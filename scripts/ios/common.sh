# Platform settings shared by the scripts in scripts/ios. Usage: PLATFORM=iphoneos|iphonesimulator; source common.sh
# Cross-compiles arm64 on Apple Silicon Macs only; the minimum OS is iOS 16, as in upstream's August build-ios.sh.

IOS_MIN="${IOS_MIN:-16.0}"
# This Mac is running the M0 speed tests at the same time, so use at most 8 jobs.
JOBS="${IOS_JOBS:-8}"
[[ "$JOBS" =~ ^[1-8]$ ]] || { echo "IOS_JOBS must be 1 to 8" >&2; exit 1; }

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
    *) echo "The platform must be iphoneos or iphonesimulator: $PLATFORM" >&2; exit 2 ;;
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
# QEMU's configure needs Python 3.10 or later; use the same one as the M0 Mac build.
QEMU_PYTHON="${QEMU_PYTHON:-/opt/homebrew/opt/python@3.12/libexec/bin/python3}"

unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH MACOSX_DEPLOYMENT_TARGET
