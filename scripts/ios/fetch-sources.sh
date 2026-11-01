#!/bin/bash
# 按 sources.tsv 下载依赖源码包到 work/ios/src，逐个核对 sha256。已下载且校验通过的跳过。
# 用法：scripts/ios/fetch-sources.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DEST="${IOS_SOURCES:-$ROOT/work/ios/src}"
mkdir -p "$DEST"
grep -v '^#' "$HERE/sources.tsv" | while IFS=$'\t' read -r name version archive url sha; do
    [ -n "$name" ] || continue
    file="$DEST/$archive"
    if [ -f "$file" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sha" ]; then
        echo "已有 $archive"
        continue
    fi
    echo "下载 $name $version"
    curl -fL --retry 3 -o "$file.part" "$url"
    got="$(shasum -a 256 "$file.part" | cut -d' ' -f1)"
    [ "$got" = "$sha" ] || { echo "$archive 校验失败：$got，应为 $sha" >&2; rm -f "$file.part"; exit 1; }
    mv "$file.part" "$file"
done
du -sh "$DEST"
