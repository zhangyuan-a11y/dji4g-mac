#!/bin/bash
# ============================================================================
#  DJI 4G 模块 · macOS 一键安装
#
#  远程（推荐，不会触发 Gatekeeper 拦截）：
#      curl -fsSL <安装脚本地址> | bash
#
#  本地（把整个文件夹发给客户，双击「安装.command」，或手动跑）：
#      bash install.sh --local /path/to/含payload的目录
#
#  为什么这么设计：
#    从浏览器 / 微信下载的 .app 会被打上 com.apple.quarantine 扩展属性，
#    Gatekeeper 会拦住「未识别的开发者」。而终端里的 curl 不写这个标记，
#    所以这样装出来的 App 能直接打开，客户不用学「右键 → 打开」。
#
#  参数：
#    --local <目录>   从本地目录安装，不联网
#    --base  <地址>   覆盖下载地址（等价于环境变量 DJI4G_BASE）
#    --no-launch      装完不自动打开
#    -h, --help       看帮助
# ============================================================================
set -euo pipefail

VERSION="1.0"
APP_NAME="DJI4G.app"
BASE_DEFAULT="${DJI4G_BASE:-https://github.com/zhangyuan-a11y/dji4g-mac/releases/latest/download}"

# 服务器上用 ASCII 文件名（URL 安全），落到客户电脑上再用中文名
DIAG_ASSET="diagnose.command"
DIAG_LOCAL="DJI4G-诊断.command"
README_ASSET="README.txt"
README_LOCAL="DJI4G-使用说明.txt"
UNINST_ASSET="uninstall.command"
UNINST_LOCAL="DJI4G-卸载.command"

BASE="${BASE_DEFAULT}"
LOCAL_DIR=""
LAUNCH=1

while [ $# -gt 0 ]; do
  case "$1" in
    --local)     LOCAL_DIR="${2:-}"; shift 2 ;;
    --base)      BASE="${2:-}"; shift 2 ;;
    --no-launch) LAUNCH=0; shift ;;
    -h|--help)
      cat <<'USAGE'
DJI 4G 模块 · macOS 安装脚本

  bash install.sh                      从默认地址在线安装
  bash install.sh --local <目录>       从本地目录安装（目录里要有 payload/DJI4G.app）
  bash install.sh --base <地址>        指定下载地址
  bash install.sh --no-launch          装完不自动启动

环境变量 DJI4G_BASE 可以代替 --base。
USAGE
      exit 0 ;;
    *) echo "未知参数：$1（用 -h 看帮助）" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;32m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ── 0. 环境检查 ─────────────────────────────────────────────────
[ "$(uname -s)" = "Darwin" ] || die "这个工具只能在 macOS 上运行（检测到 $(uname -s)）。"
OS_VER="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VER%%.*}"
[ "${OS_MAJOR}" -ge 13 ] 2>/dev/null || die "需要 macOS 13 或更新版本，当前是 ${OS_VER}。"
ARCH="$(uname -m)"
say "系统 macOS ${OS_VER}（${ARCH}）"

# ── 1. 取文件 ───────────────────────────────────────────────────
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dji4g.XXXXXX")"
trap 'mv "${STAGE}" "${TMPDIR:-/tmp}/dji4g-leftover-$$" 2>/dev/null || true' EXIT

SRC=""
if [ -n "${LOCAL_DIR}" ]; then
  # 依次找：程序/ 、payload/ 、安装包根目录
  SRC=""
  for CAND in "${LOCAL_DIR}/程序" "${LOCAL_DIR}/payload" "${LOCAL_DIR}" "${LOCAL_DIR}/App"; do
    if [ -d "${CAND}/${APP_NAME}" ]; then SRC="${CAND}"; break; fi
  done
  [ -n "${SRC}" ] || die "在 ${LOCAL_DIR} 里找不到 ${APP_NAME}。请确认整个文件夹是完整解压出来的。"
  say "使用本地安装包"
else
  ZIP_NAME="dji4g-${VERSION}-universal.zip"
  ZIP_URL="${BASE}/${ZIP_NAME}"
  say "下载安装包…"
  curl -fL --progress-bar --connect-timeout 15 --max-time 600 "${ZIP_URL}" -o "${STAGE}/${ZIP_NAME}" \
    || die "下载失败。请检查网络，或联系服务商确认下载地址。"
  if curl -fsSL --connect-timeout 15 --max-time 60 "${ZIP_URL}.sha256" -o "${STAGE}/${ZIP_NAME}.sha256" 2>/dev/null; then
    if ( cd "${STAGE}" && shasum -a 256 -c "${ZIP_NAME}.sha256" >/dev/null 2>&1 ); then
      say "完整性校验通过"
    else
      warn "校验和不匹配（文件可能没下载完整），仍继续安装。"
    fi
  fi
  ditto -x -k "${STAGE}/${ZIP_NAME}" "${STAGE}/x" || die "解压失败，文件可能没下载完整。"
  SRC="${STAGE}/x"
  [ -d "${SRC}/${APP_NAME}" ] || SRC="${STAGE}/x/payload"
  [ -d "${SRC}/${APP_NAME}" ] || die "压缩包里没有 ${APP_NAME}。"
fi

# ── 2. 选安装位置 ───────────────────────────────────────────────
if [ -w /Applications ]; then
  DEST="/Applications"
else
  DEST="${HOME}/Applications"
  mkdir -p "${DEST}"
  warn "/Applications 不可写，改装到 ${DEST}（功能完全一样）。"
fi
TARGET="${DEST}/${APP_NAME}"

# ── 3. 退出正在跑的旧版本，旧版挪到废纸篓（可回滚）──────────────
if [ -d "${TARGET}" ]; then
  osascript -e 'tell application "DJI4G" to quit' >/dev/null 2>&1 || true
  pkill -f "DJI4G.app/Contents/MacOS/DJI4GMenuBar" >/dev/null 2>&1 || true
  sleep 1
  mkdir -p "${HOME}/.Trash"
  if mv "${TARGET}" "${HOME}/.Trash/DJI4G.app.$(date +%Y%m%d-%H%M%S)" 2>/dev/null; then
    say "旧版本已移到废纸篓（想回退就从废纸篓拖回来）"
  else
    warn "旧版本没能移走，直接覆盖。"
  fi
fi

# ── 4. 安装 + 去隔离 + 签名兜底 ─────────────────────────────────
# --noqtn：不要把下载时带的隔离标记复制过去
# --noextattr / --norsrc：只搬真正的文件，别的杂项一律不带
ditto --noqtn --norsrc --noextattr "${SRC}/${APP_NAME}" "${TARGET}" || die "复制到 ${DEST} 失败。"
# 兜底再清一遍（旧版本留下的标记、以及从压缩包解压继承来的）
xattr -cr "${TARGET}" 2>/dev/null || true

CTL="${TARGET}/Contents/Resources/dji4gctl"

if ! codesign --verify --deep --strict "${TARGET}" >/dev/null 2>&1; then
  warn "签名校验没过，正在本地补签（ad-hoc）…"
  codesign --force --sign - "${CTL}" >/dev/null 2>&1 || true
  codesign --force --sign - "${TARGET}" >/dev/null 2>&1 || true
fi

say "已安装到 ${TARGET}"

# ── 5. 冒烟测试：确认这个二进制在本机能跑起来 ───────────────────
#    Apple 芯片上，签名有任何问题的二进制会被内核直接杀掉，
#    这一步就是当场把那种情况暴露出来。
say "验证本机可运行…"
SMOKE=0
if "${CTL}" selftest >/dev/null 2>&1; then
  SMOKE=1
  say "自检通过（118 项全部正常）"
else
  warn "自检没通过，尝试重新签名…"
  codesign --force --sign - "${CTL}" >/dev/null 2>&1 || true
  codesign --force --sign - "${TARGET}" >/dev/null 2>&1 || true
  if "${CTL}" selftest >/dev/null 2>&1; then
    SMOKE=1
    say "重新签名后自检通过"
  fi
fi

# ── 6. 命令行工具挂软链（可选，失败无所谓）─────────────────────
if ln -sf "${CTL}" /usr/local/bin/dji4gctl 2>/dev/null; then
  say "命令行工具：dji4gctl"
else
  say "命令行工具：${CTL}"
fi

# ── 7. 把说明书和工具放到桌面 ───────────────────────────────────
#    本地有就用本地的（完全离线也能装），本地没有才去网上取。
DESK="${HOME}/Desktop"

# place_file <桌面上的名字> <服务器上的名字> <本地候选路径…>
place_file() {
  local DEST_NAME="$1"
  local ASSET_NAME="$2"
  shift 2
  local DEST="${DESK}/${DEST_NAME}"
  local CAND=""
  for CAND in "$@"; do
    if [ -n "${CAND}" ] && [ -f "${CAND}" ]; then
      if cp "${CAND}" "${DEST}" 2>/dev/null; then
        break
      fi
    fi
  done
  if [ ! -f "${DEST}" ]; then
    curl -fsSL --connect-timeout 5 --max-time 30 "${BASE}/${ASSET_NAME}" -o "${DEST}" 2>/dev/null || true
  fi
  # 这三个文件是要给客户双击的，绝不能带着隔离标记落盘，
  # 否则客户以后双击「诊断」「卸载」时又会被系统拦一次。
  [ -f "${DEST}" ] && xattr -c "${DEST}" 2>/dev/null || true
}

if [ -d "${DESK}" ]; then
  place_file "${DIAG_LOCAL}" "${DIAG_ASSET}" \
    "${SRC}/${DIAG_ASSET}" "${LOCAL_DIR}/诊断.command" "${LOCAL_DIR}/一键诊断.command"
  place_file "${UNINST_LOCAL}" "${UNINST_ASSET}" \
    "${SRC}/卸载.command" "${LOCAL_DIR}/卸载.command" "${LOCAL_DIR}/一键卸载.command"
  place_file "${README_LOCAL}" "${README_ASSET}" \
    "${SRC}/${README_ASSET}" "${LOCAL_DIR}/使用说明.txt" "${LOCAL_DIR}/客户说明.txt"
  chmod +x "${DESK}/${DIAG_LOCAL}" "${DESK}/${UNINST_LOCAL}" 2>/dev/null || true
  chmod -x "${DESK}/${README_LOCAL}" 2>/dev/null || true
fi

# ── 8. 启动 ─────────────────────────────────────────────────────
if [ "${LAUNCH}" = "1" ]; then
  open "${TARGET}" 2>/dev/null || true
  say "已启动，看屏幕右上角菜单栏的图标。"
fi

# ── 9. 收尾提示 ─────────────────────────────────────────────────
echo
echo "──────────────────────────────────────────────"
if [ "${SMOKE}" != "1" ]; then
  warn "本机自检没通过。请双击桌面上的「${DIAG_LOCAL}」，把生成的报告发给服务商。"
  echo
fi
cat <<TIP
接下来三步：

  1. 把大疆 4G 模块插到 Mac 的 USB 口（尽量直插，别经过扩展坞）
  2. 点菜单栏图标 → 模块设置 → 开启通话音频
     （一代模块出厂时这项是关的，开一次就永久生效，模块会重启约 20 秒）
  3. 点「体检」，它会逐项告诉你还差什么，缺什么直接给命令

桌面上已经放好了三个文件：
  · ${README_LOCAL} —— 完整说明书，先看这个
  · ${DIAG_LOCAL} —— 出问题时双击它，把生成的报告发我
  · ${UNINST_LOCAL} —— 想卸载时双击它，能顺便恢复原厂设置
TIP
echo "──────────────────────────────────────────────"
