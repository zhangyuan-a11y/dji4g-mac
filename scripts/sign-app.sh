#!/bin/sh
# 给一个 .app 签名。有固定证书就用固定证书，没有就退回临时签名。
#
# 用法： scripts/sign-app.sh /路径/DJI4G.app
#
# 为什么要固定证书：
#   系统按「签名身份」记授权（麦克风、通知）。临时签名（codesign --sign -）的
#   身份是那份二进制的 cdhash，编译一次换一个 —— 每装一次新版本，客户之前点过
#   的麦克风授权就作废，而系统的授权框一辈子只弹一次。客户看到的就是「昨天还
#   能打电话，今天没声音了」，而且没有任何提示告诉他要去点一下。
#   （2026-09-30 查了一整晚的「接通没声音」，一半是这个来的。）
#
#   固定证书把身份换成 certificate root，证书不变身份就不变，装多少遍授权都
#   还在。证书是本地自签的，不进系统信任库，只回答系统一个问题：「这是不是
#   同一个 App」。造证书：scripts/make-signing-identity.sh
#
# 为什么要 REAL_HOME：
#   钥匙串的搜索列表按用户域存。编译时 $HOME 被指到 .buildhome 去了，照 $HOME
#   找钥匙串会扑空 —— 而且 codesign 扑空时只是失败，不吭声，于是"安静地"退回
#   临时签名，正好把这件事做废（踩过一次）。
set -e

# 最后一个不是以 - 开头的参数当成要签的东西，前面那些 - 开头的原样传给
# codesign（打包脚本要传 --deep）。
APP=""
EXTRA=""
for arg in "$@"; do
    case "$arg" in
        -*) EXTRA="$EXTRA $arg" ;;
        *)  APP="$arg" ;;
    esac
done
[ -n "$APP" ] || { echo "用法：$0 [--deep] <某个二进制或 .app>" >&2; exit 2; }

SIGN_ID="DJI4G Local Signing"
REAL_HOME="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[ -n "$REAL_HOME" ] || REAL_HOME="$HOME"
SIGN_KC="${REAL_HOME}/Library/Keychains/dji4g-signing.keychain-db"

# shellcheck disable=SC2086
use_identity() {
    HOME="$REAL_HOME" security unlock-keychain -p dji4g "$SIGN_KC" >/dev/null 2>&1 || true
    HOME="$REAL_HOME" codesign --force $EXTRA --sign "$SIGN_ID" --keychain "$SIGN_KC" "$APP"
}

if [ -f "$SIGN_KC" ] && HOME="$REAL_HOME" security find-identity -p codesigning "$SIGN_KC" 2>/dev/null | grep -q "$SIGN_ID"; then
    if use_identity >/dev/null 2>&1; then
        echo "已用固定证书签名：$APP"
    else
        codesign --force --sign - "$APP" >/dev/null 2>&1 || true
        echo "！固定证书签名失败，退回临时签名：$APP"
    fi
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
    echo "· 没找到固定证书，用临时签名：$APP（重装后会要求重新授权）"
fi
