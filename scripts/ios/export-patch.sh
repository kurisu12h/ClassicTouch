#!/bin/bash
# Export the changes to some files of the work tree (work/ios/qemu-ios) as a patch that holds only what changed "after
# the earlier patches were applied".
# How: take these files as they are in the work tree's HEAD (the upstream commit), apply the patches given with --base,
# then diff each one against the file in the work tree.
# The description at the top of the patch (the text before the first "diff --git") is kept from the existing OUT
# file; without one it is left empty for you to write.
# Usage: scripts/ios/export-patch.sh OUT.patch [--base patches/xxx.patch ...] FILE ... (paths relative to the work
# tree root)
# Example: scripts/ios/export-patch.sh patches/ios-gles-perf.patch --base patches/ios-eagl-es2.patch \
#       hw/arm/gles-host.c hw/arm/s5l8930_display.c contrib/ios-app/qemu-ios-ui.c
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU="$ROOT/work/ios/qemu-ios"
OUT="${1:?usage: export-patch.sh OUT.patch [--base PATCH ...] FILE ...}"
shift
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac
bases=()
while [ "${1:-}" = --base ]; do
    case "$2" in /*) bases+=("$2") ;; *) bases+=("$ROOT/$2") ;; esac
    shift 2
done
[ $# -gt 0 ] || { echo "No files given" >&2; exit 2; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/a"
for f in "$@"; do
    mkdir -p "$TMP/a/$(dirname "$f")"
    git -C "$QEMU" show "HEAD:$f" > "$TMP/a/$f" 2>/dev/null || rm -f "$TMP/a/$f"   # files upstream lacks are created by the patches
done
for p in ${bases[@]+"${bases[@]}"}; do
    # Apply only the parts touching these files: the other files are not in the temporary directory, and
    # git apply --include takes only the paths it is given
    inc=()
    for f in "$@"; do inc+=(--include="$f"); done
    git -C "$TMP/a" apply --unsafe-paths "${inc[@]}" "$p"
done
{
    if [ -f "$OUT" ]; then awk '/^diff --git/{exit} {print}' "$OUT"; fi
    for f in "$@"; do
        old="$TMP/a/$f" label="a/$f"
        [ -f "$old" ] || { old=/dev/null; label=/dev/null; }
        if ! cmp -s "$old" "$QEMU/$f"; then
            diff -u --label "$label" --label "b/$f" "$old" "$QEMU/$f" | sed "1i\\
diff --git a/$f b/$f" || true
        fi
    done
} > "$OUT.new"
mv "$OUT.new" "$OUT"
echo "Wrote $OUT ($(grep -c '^diff --git' "$OUT") files)"
