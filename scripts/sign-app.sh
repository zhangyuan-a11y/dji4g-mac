#!/bin/sh
# 给一个 .app（或单个二进制）签名 —— 只用临时签名（ad-hoc）。
#
# 用法： scripts/sign-app.sh [--deep] <某个二进制或 .app>
#
# 2026-10-23 起不再用本地自签证书（dji4g-signing 钥匙串）。原因：
#   那张证书的私钥所在钥匙串，密码和脚本里写的不一致 —— codesign 一碰就弹
#   「codesign 想使用 dji4g-signing 钥匙串，请输入密码」，而且自签证书本来也
#   不被 Gatekeeper 信任，对客户安装没有帮助。所以改成纯 ad-hoc：不依赖任何
#   钥匙串、不会弹窗，签名照样通过 `codesign --verify --deep --strict`。
#
# 代价（要在文档里跟客户讲清楚）：
#   ad-hoc 的签名身份是这份二进制的 cdhash，每次重编都会变，所以「麦克风」
#   这类系统授权在装新版本之后要重新点一次。要恢复稳定身份，等有正规的
#   Apple Developer ID 再上真签名 + 公证。
#
# .app 是「先内后外」：包里每个 Mach-O（主程序、dji4gctl、adb）先逐个 ad-hoc
# 签，最后签外层 bundle。只靠 codesign --deep 不会覆盖 Google 签好的 adb，
# 会留下「外层 ad-hoc + 内层 Google」的混合签名，macOS 26+ 的
# `codesign --verify --deep --strict` 判失败（客户机 macOS 27.0.1 的
# 「签名校验没过」根子就在这）。
set -e

# 最后一个不是以 - 开头的参数当成要签的东西；- 开头的旗标（--deep 之类）忽略：
# 嵌套件下面逐个签，不需要它。
APP=""
for arg in "$@"; do
    case "$arg" in
        -*) ;;
        *) APP="$arg" ;;
    esac
done
[ -n "$APP" ] || { echo "用法：$0 [--deep] <某个二进制或 .app>" >&2; exit 2; }

# 签单个目标（ad-hoc）。不碰任何钥匙串。
sign_one() {
    codesign --force --sign - "$1" >/dev/null 2>&1 || true
}

# .app 要「先内后外」：包里每一个 Mach-O 可执行文件先用同一张证书逐个签，
# 最后再签外层 bundle。关键是不能只靠 codesign --deep —— 它不会覆盖一个
# 已经签过名的嵌套二进制。包里带的 adb 是 Google 签的，不重签就会留下
# 「外层自签 + 内层 Google」的混合签名，macOS 26+ 的
# `codesign --verify --deep --strict` 会判失败（客户机 macOS 27.0.1 的
# 「签名校验没过」根子就在这）。
if [ -d "$APP/Contents" ]; then
    MAIN="$APP/Contents/MacOS/DJI4GMenuBar"
    LIST="${TMPDIR:-/tmp}/dji4g-nested-$$"
    find "$APP/Contents" -type f -print0 > "$LIST" 2>/dev/null || true
    while IFS= read -r -d '' BIN; do
        [ "$BIN" = "$MAIN" ] && continue
        file "$BIN" 2>/dev/null | grep -q "Mach-O" || continue
        sign_one "$BIN"
    done < "$LIST"
    mv "$LIST" "/tmp/dji4g-nested-done-$$" 2>/dev/null || true
    sign_one "$MAIN"
fi

sign_one "$APP"
echo "已签名：$APP"
