#!/bin/bash
# 把工作树（work/ios/qemu-ios）里某几个文件的改动导出成补丁，只含「打完前面那些补丁之后」又改的部分。
# 做法：从工作树的 HEAD（上游提交）取这些文件的原样，打上 --base 给的补丁，再和工作树里的文件逐个 diff。
# 补丁开头的说明（第一个「diff --git」之前的文字）从 OUT 原有的文件里保留；没有就留空，自己补上。
# 用法：scripts/ios/export-patch.sh OUT.patch [--base patches/xxx.patch ...] 文件 ...（文件路径相对工作树根目录）
# 例：scripts/ios/export-patch.sh patches/ios-gles-perf.patch --base patches/ios-eagl-es2.patch \
#       hw/arm/gles-host.c hw/arm/s5l8930_display.c contrib/ios-app/qemu-ios-ui.c
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU="$ROOT/work/ios/qemu-ios"
OUT="${1:?用法：export-patch.sh OUT.patch [--base 补丁 ...] 文件 ...}"
shift
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac
bases=()
while [ "${1:-}" = --base ]; do
    case "$2" in /*) bases+=("$2") ;; *) bases+=("$ROOT/$2") ;; esac
    shift 2
done
[ $# -gt 0 ] || { echo "没给文件" >&2; exit 2; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/a"
for f in "$@"; do
    mkdir -p "$TMP/a/$(dirname "$f")"
    git -C "$QEMU" show "HEAD:$f" > "$TMP/a/$f" 2>/dev/null || rm -f "$TMP/a/$f"   # 上游没有的文件由补丁新建
done
for p in ${bases[@]+"${bases[@]}"}; do
    # 只打和这些文件有关的部分：别的文件不在临时目录里，git apply --include 只认给出的路径
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
echo "写好：$OUT（$(grep -c '^diff --git' "$OUT") 个文件）"
