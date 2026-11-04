# scripts/ios 下的真机脚本共用：App 容器（Documents）里的文件操作。用法：PHONE=… BUNDLE=… ROOT=…; source devfiles.sh
# 远端路径都写成 /Documents/… 的样子。
#   dls DIR           DIR 下一层的名字，一行一个
#   dget 远端 本地    先下到临时文件，成功才改名，免得留下半截文件；失败不报错（下一轮再来）
#   dput 本地 远端    上传，缺的目录自动建
# 两种后端，FILES 选：
#   afc        idevice 工具包的 afc --documents（经 usbmuxd，要插着线）。M1 第三阶段开着 LocalDevVPN 时 CoreDevice 的文件
#              服务先变慢、后卡死，AFC 不受影响，所以有 work/ios/tools/idevice-tools-0.1.68 时默认用它。
#   devicectl xcrun devicectl device copy、device info files，不用另装工具（docs/reports/ios-device-14pro.md）。没有
#              idevice-tools 时默认用它；没有删除，`devicectl copy` 也拿不到剩余空间。
IDT="$ROOT/work/ios/tools/idevice-tools-0.1.68/bin/idevice-tools"
if [ -z "${FILES:-}" ]; then
    if [ -x "$IDT" ]; then FILES=afc; else FILES=devicectl; fi
fi
case "$FILES" in
afc)
    # idevice-tools 偶尔会崩（Abort trap，多半是赶上正在写的文件）：失败不让脚本退出
    afc() { { "$IDT" --udid "$PHONE" afc --documents "$BUNDLE" "$@" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; } || true; }
    dls() { afc list "$1" | grep -o '"[^"]*"' | tr -d '"' || true; }
    dget() {
        if "$IDT" --udid "$PHONE" afc --documents "$BUNDLE" download "$1" "$2.part" >/dev/null 2>&1; then
            mv "$2.part" "$2"
        else
            rm -f "$2.part"
        fi
    }
    dput() { afc mkdir "$(dirname "$2")" >/dev/null; afc upload "$1" "$2" >/dev/null; }
    ;;
devicectl)
    DC=(--device "$PHONE" --domain-type appDataContainer --domain-identifier "$BUNDLE")
    dls() {
        local j; j="$(mktemp)"
        xcrun devicectl device info files "${DC[@]}" --subdirectory "${1#/}" --json-output "$j" >/dev/null 2>&1 || true
        jq -r '.result.files[]?.relativePath // empty' "$j" 2>/dev/null | grep -v / || true
        rm -f "$j"
    }
    dget() {
        if xcrun devicectl device copy from "${DC[@]}" --source "${1#/}" --destination "$2.part" >/dev/null 2>&1; then
            mv "$2.part" "$2"
        else
            rm -f "$2.part"
        fi
    }
    dput() { xcrun devicectl device copy to "${DC[@]}" --source "$1" --destination "${2#/}" >/dev/null 2>&1 || true; }
    ;;
*) echo "FILES 只能是 afc 或 devicectl" >&2; exit 2 ;;
esac
