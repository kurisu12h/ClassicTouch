#!/bin/bash
# M0: patched FFmpeg 9.0.1 for qemu-ios (options copied from LightTouchMac build-support/recipes/build-package-native.sh)
set -euo pipefail
W=/path/to/classic-ios/work/ffmpeg
Q=/path/to/classic-ios/upstream/qemu-ios
cd "$W"
[ -f ffmpeg-9.0.1.tar.xz ] || curl -fL --retry 8 --retry-all-errors --retry-delay 5 -o ffmpeg-9.0.1.tar.xz https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz
echo "cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635  ffmpeg-9.0.1.tar.xz" | shasum -a 256 -c -
rm -rf ffmpeg-9.0.1 && tar xf ffmpeg-9.0.1.tar.xz
cd ffmpeg-9.0.1
patch -p1 < "$Q/contrib/ffmpeg/h264-chunk-er.patch"
patch -p1 < "$Q/contrib/ffmpeg/h264-cavlc-pcm-offset.patch"
./configure --prefix="$W/prefix" \
    --disable-everything --disable-autodetect --disable-programs --disable-doc \
    --disable-avdevice --disable-avformat --disable-avfilter --disable-swscale --disable-swresample \
    --enable-decoder=aac,mp3,alac,h264 --enable-shared --disable-static --install-name-dir="$W/prefix/lib" \
    --extra-cflags="-mmacosx-version-min=14.0" --extra-ldflags="-mmacosx-version-min=14.0"
make -j12
make install
ls -la "$W/prefix/lib"
