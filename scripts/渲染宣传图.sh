#!/bin/bash
# ============================================================================
#  渲染宣传图 —— 一条命令把改完的文案变成桌面上的 PNG。
#
#  为什么要写成脚本：
#    这些图是 SwiftUI 画的，资源目录 `./work/promo/assets` 是**相对当前目录**
#    解析的（见 Promo.swift 的 Assets.dir）。在源码目录里直接跑二进制，路径
#    会落到 work/dji4g-menubar/work/promo/assets —— 那里当然没有截图，于是
#    每一页的英雄图区都渲染成一块空白，而且程序不会报错，只是安静地出一张
#    白板。2026-09-26 实际踩过一次。所以这里把工作目录钉死在仓库根。
#
#  它做这些事：
#    1. 编译 DJI4GPromo
#    2. 从仓库根渲染 8 张（浅色纸感那套）
#    3. 跑 work/promo/dark/cover-dark.py，出深色电影感封面（第 9 张）
#    4. 覆盖到桌面的 `大疆4g模块项目/宣传图/`
#
#  用法：bash scripts/渲染宣传图.sh
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$(cd "${ROOT}/../.." && pwd)"
STAGE="/tmp/dji4g-promo-$$"
DARK_OUT="${G}/work/promo/dark/out"

REAL_HOME="$(/usr/bin/python3 -c 'import os,pwd;print(pwd.getpwuid(os.getuid()).pw_dir)' 2>/dev/null || true)"
[ -n "${REAL_HOME}" ] && [ -d "${REAL_HOME}/Desktop" ] || REAL_HOME="${HOME}"
DEST="${REAL_HOME}/Desktop/大疆4g模块项目/宣传图"

say() { printf '\033[1;32m▸\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' >&2 "$*"; exit 1; }

say "编译 DJI4GPromo"
cd "${ROOT}"
HOME="${ROOT}/.buildhome" CLANG_MODULE_CACHE_PATH="${ROOT}/.buildhome/clangcache" \
  swift build -c release --disable-sandbox --scratch-path .build >/dev/null

say "渲染浅色 8 张（工作目录 = ${G}）"
cd "${G}"
[ -d "${G}/work/promo/assets/ui" ] || die "找不到截图资源 work/promo/assets/ui —— 先跑界面截图那一步"
"${ROOT}/.build/release/DJI4GPromo" --out "${STAGE}"

say "渲染深色封面"
cd "${G}/work/promo/dark" && python3 cover-dark.py >/dev/null
[ -f "${DARK_OUT}/cover-dark.png" ] || die "深色封面没出图"

say "覆盖到桌面"
[ -d "${DEST}" ] || die "桌面没有 宣传图/ 目录：${DEST}"
mkdir -p "${DEST}"
cp "${STAGE}"/*.png "${DEST}/"
cp "${DARK_OUT}/cover-dark.png" "${DEST}/alt-cover-dark.png"

say "完成，共 9 张："
ls -la "${DEST}"
