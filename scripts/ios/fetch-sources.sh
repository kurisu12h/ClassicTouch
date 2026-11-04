#!/bin/bash
# Download the dependency source archives listed in sources.tsv into work/ios/src, checking each sha256. Archives
# already downloaded that pass the check are skipped.
# Usage: scripts/ios/fetch-sources.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DEST="${IOS_SOURCES:-$ROOT/work/ios/src}"
mkdir -p "$DEST"
grep -v '^#' "$HERE/sources.tsv" | while IFS=$'\t' read -r name version archive url sha; do
    [ -n "$name" ] || continue
    file="$DEST/$archive"
    if [ -f "$file" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sha" ]; then
        echo "Already have $archive"
        continue
    fi
    echo "Downloading $name $version"
    curl -fL --retry 3 -o "$file.part" "$url"
    got="$(shasum -a 256 "$file.part" | cut -d' ' -f1)"
    [ "$got" = "$sha" ] || { echo "$archive checksum mismatch: $got, expected $sha" >&2; rm -f "$file.part"; exit 1; }
    mv "$file.part" "$file"
done
du -sh "$DEST"
