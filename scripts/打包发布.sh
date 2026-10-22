#!/bin/bash
# ============================================================================
#  打包发布 —— 一条命令把「改完代码」变成「能发给客户的包」。
#
#  为什么要写成脚本：
#    这一步以前是手工做的，结果三处 zip 里躺过两个版本的包（交付根目录那个
#    3156741 字节的 DJI4G-installer.zip 就是漏掉的一次）。打包是纯机械动作，
#    交给脚本，人手只负责最后点一遍发布。
#
#  它做这些事：
#    1. 把 x86_64 与 arm64 两个产物 lipo 成 universal
#    2. 装进两个 .app（源码目录那个 / 交付用的 payload）
#    3. 重签（有固定证书就用固定证书，重装不用重新授权），并按安装脚本的
#       口径 codesign --verify --deep --strict 验一遍
#    4. 打两个 zip：App 单包、含安装器的完整安装包
#    5. 刷新 .sha256（内容里写的永远是服务器上的 ASCII 名）
#    6. 同步到 发布资产/ 和桌面
#
#  用法：bash Scripts/打包发布.sh
#  前置：两个架构都编译过（见文件末尾的编译命令）
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$(cd "${ROOT}/../.." && pwd)"
OUT="${G}/outputs"
DEL="${OUT}/dji4g-delivery"
# 「源码目录那个壳」直接认仓库自己家里那一个。
# 以前这里写的是 ${OUT}/dji4g-menubar/DJI4G.app —— 那是仓库早先摆在 outputs/
# 时的路径，仓库搬进 work/ 之后它成了一个没人维护的 9 月 22 号副本。脚本
# 照样会往里写，只是写进去的东西谁也没看；真正发给客户的是下面那个
# payload 壳，所以一直没暴露。改成跟着仓库走：无论仓库摆在 g/ 下面哪一层，
# 这个壳都和源码同一份树。
SRC_APP="${ROOT}/DJI4G.app"
PAYLOAD_APP="${DEL}/payload/DJI4G.app"
STAGE_BIN="${ROOT}/build-universal"
# 桌面路径不要用 $HOME 推：编译时 HOME 会被指到沙箱里的一次性目录
# （.buildhome），那里没有 Desktop，于是下面「同步桌面」整段被静默跳过 ——
# 实际发生过一次：交付目录出了新包，桌面还是上一轮的旧包，谁都没发现。
# 这里按 uid 问系统要真实家目录，问不到再退回 $HOME。
REAL_HOME="$(/usr/bin/python3 -c 'import os,pwd;print(pwd.getpwuid(os.getuid()).pw_dir)' 2>/dev/null || true)"
[ -n "${REAL_HOME}" ] && [ -d "${REAL_HOME}/Desktop" ] || REAL_HOME="${HOME}"
DESK="${REAL_HOME}/Desktop/大疆4g模块项目"
TOOLS="${DESK}/交付工具"
# 桌面上给客户的那个文件夹 —— 只有两样：安装包 zip + 说明书。
# 以前这里往桌面根目录散着放四样（zip / .sha256 / 客户说明.txt / 安装图解/）：
# 卖家自己在 Finder 里都分不清该发哪个；而 .sha256、安装图解 在微信这条线上
# 客户根本用不到 —— zip 里本来就自带一份 客户说明.txt 和 安装图解/。
# 说明书仍然在外面再放一份：客户在手机上要先读得到，不必先把包解开。
HAND="${DESK}/发给客户"

VERSION="1.0"
ZIP_APP="dji4g-${VERSION}-universal.zip"
ZIP_INSTALLER_LOCAL="DJI4G-安装包.zip"
ZIP_INSTALLER_ASSET="DJI4G-installer.zip"
# 第四个资产：桌面那三个文件（诊断/卸载/说明）打成的带图标 tar.gz。
# 名字是 ASCII，install.sh 里按这个名字取成员。
TOOLS_TARBALL="desktop-tools.tar.gz"
BUNDLE_RES="DJI4G_DJI4GMenuBar.bundle"
FOLDER_INSTALLER="DJI4G-安装包"

say()  { printf '\033[1;32m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

X86="${ROOT}/.build/release"
ARM="${ROOT}/.build-arm64/release"

# ── 0. 两个架构的产物都要在 ─────────────────────────────────────
for ARCH_DIR in "${X86}" "${ARM}"; do
  for BIN in DJI4GMenuBar dji4gctl; do
    [ -f "${ARCH_DIR}/${BIN}" ] || die "缺少 ${ARCH_DIR}/${BIN}。先把两个架构都编译一遍（见脚本末尾）。"
  done
done
[ -d "${SRC_APP}" ]     || die "找不到 ${SRC_APP}"
[ -d "${PAYLOAD_APP}" ] || die "找不到 ${PAYLOAD_APP}"

# ── 0.5 两个架构的产物不许比源码旧 ──────────────────────────────
# 2026-09-26 交付当天真踩了这个：只重编了 x86_64（开发机是 Intel），arm64
# 那个产物停在 16:25，而修复是 16:44 进的源码树。lipo 出来的包「两个架构
# 都在」、四道闸门全绿、校验和一致 —— 可客人是 M4，跑的是没修过的那半边。
#
# 上面那条「文件在不在」拦不住它，因为文件确实在，只是旧。所以这一道问的
# 是「它到底是不是这一版源码编出来的」。开发机是 Intel 的时候，这个坑是
# **完全静默**的：本机跑得好好的，只有客人才会撞上。
#
# 每个产物只跟**它自己那个 target 的源码**比：拿全树最新时刻当基准的话，
# 改一句 App 的话就会把 dji4gctl 也判成旧的，而那种假警报只会教人学会
# 无视这道闸门 —— 一道会被无视的闸门等于没有。
newest_epoch() { find "$@" -type f -exec stat -f '%m' {} + 2>/dev/null | sort -rn | head -1; }
check_fresh() {  # $1=产物路径  $2=它的源码里最新那一刻
  [ "$(stat -f '%m' "$1")" -lt "$2" ] || return 0
  die "${1#${ROOT}/} 比它自己的源码旧：
   产物 $(stat -f '%Sm' -t '%m-%d %H:%M' "$1")
   源码 $(date -r "$2" '+%m-%d %H:%M')
   这个架构上跑的是改之前的代码。重编：见脚本末尾那两条命令（两个架构都要）。"
}
APP_SRC_EPOCH="$(newest_epoch "${ROOT}/Sources/DJI4GMenuBar" "${ROOT}/Sources/DJI4GCore" \
                             "${ROOT}/Sources/CMacNet" "${ROOT}/Package.swift")"
CTL_SRC_EPOCH="$(newest_epoch "${ROOT}/Sources/dji4gctl" "${ROOT}/Sources/DJI4GCore" \
                             "${ROOT}/Sources/CMacNet" "${ROOT}/Package.swift")"
for ARCH_DIR in "${X86}" "${ARM}"; do
  check_fresh "${ARCH_DIR}/DJI4GMenuBar" "${APP_SRC_EPOCH}"
  check_fresh "${ARCH_DIR}/dji4gctl"     "${CTL_SRC_EPOCH}"
done
say "闸门 0/5 通过：两个架构的产物都比自己的源码新"

# ── 1. lipo ─────────────────────────────────────────────────────
mkdir -p "${STAGE_BIN}"
for BIN in DJI4GMenuBar dji4gctl; do
  lipo -create "${X86}/${BIN}" "${ARM}/${BIN}" -output "${STAGE_BIN}/${BIN}"
  ARCHS="$(lipo -archs "${STAGE_BIN}/${BIN}")"
  case "${ARCHS}" in
    *x86_64*arm64*|*arm64*x86_64*) ;;
    *) die "${BIN} 合成后只有 ${ARCHS}，不是 universal。" ;;
  esac
  say "${BIN}：${ARCHS}"
done

# ── 2. 装进两个 .app ────────────────────────────────────────────
# 源码目录那个 .app 不带 dji4gctl（它是构建产物，不是交付物）；交付用的
# payload 里两样都要，安装脚本会把 CLI 一起装上。
cp "${STAGE_BIN}/DJI4GMenuBar" "${SRC_APP}/Contents/MacOS/DJI4GMenuBar"
mkdir -p "${PAYLOAD_APP}/Contents/Resources"
cp "${STAGE_BIN}/DJI4GMenuBar" "${PAYLOAD_APP}/Contents/MacOS/DJI4GMenuBar"
cp "${STAGE_BIN}/dji4gctl"     "${PAYLOAD_APP}/Contents/Resources/dji4gctl"
chmod +x "${PAYLOAD_APP}/Contents/Resources/dji4gctl"

# ── 2a. 通话语音的模块侧资源 ────────────────────────────────────
# 两个 .ko、PCM 桥、出厂校准，加一份自带的 adb —— 全部要跟着 app 走。
# 客户机上既没有源码树也没有 platform-tools；少了这个目录，面板里那个
# 「一键安装」只会回一句「安装包缺少 ModuleVoice 目录」。
# 2026-09-25 就是这么发出去过一版：在源码目录里跑得好好的，交付包里根本
# 没有这个目录（*.bundle 里只有点阵字），而本机因为 resources/ 就在手边，
# 一直看不出问题。
for APP in "${SRC_APP}" "${PAYLOAD_APP}"; do
  mkdir -p "${APP}/Contents/Resources"
  # 老的那一份挪走而不是删（沙箱里 rm -rf 会被拒，脚本得能反复跑）。
  mv "${APP}/Contents/Resources/ModuleVoice" "${TMPDIR:-/tmp}/dji4g-mv-old-$$" 2>/dev/null || true
  cp -R "${ROOT}/resources/ModuleVoice" "${APP}/Contents/Resources/ModuleVoice"
  # 打包会丢掉可执行位的情况见过一次（zip 的锅），这里明写一次。
  chmod 755 "${APP}/Contents/Resources/ModuleVoice/adb" 2>/dev/null || true
done
say "通话语音资源已就位（ModuleVoice/，含自带的 adb）"

# ── 2a-2. 点阵字资源包 ──────────────────────────────────────────
# 2026-09-26：两个 .app 壳里的 doto.ttf 都还是上一版的，而这一版刚修过
# 字形（M 被画成 H，ECM 显示成 ECH）。原因是壳里的 *.bundle 从来没人刷：
# make-app.sh 只把资源包拷给「源码目录那个壳」，而交付用的 payload 壳是
# 手工摆的，打包脚本此前只往里放二进制和图标 —— 点阵字就一直停在摆壳那
# 天的版本。本机跑不出来：AppResources 会顺着 Bundle.main.resourceURL 读
# 到壳里那份旧字，照样显示得出来，只是字形是旧的。
# 两道保险：先把两个架构的 release 资源包刷进去，再拿源码树的 doto.ttf
# 逐个比对哈希，对不上就拦下来。
FONT_SRC="${ROOT}/Sources/DJI4GMenuBar/Resources/doto.ttf"
[ -f "${FONT_SRC}" ] || die "找不到 ${FONT_SRC}"
FONT_SHA="$(shasum -a 256 "${FONT_SRC}" | awk '{print $1}')"
for APP in "${SRC_APP}" "${PAYLOAD_APP}"; do
  DEST="${APP}/Contents/Resources/${BUNDLE_RES}"
  # 老的那一份挪走而不是删（沙箱里 rm -rf 会被拒，脚本得能反复跑）。
  mv "${DEST}" "${TMPDIR:-/tmp}/dji4g-font-old-$$" 2>/dev/null || true
  mkdir -p "${DEST}"
  cp "${FONT_SRC}" "${DEST}/doto.ttf"
  GOT="$(shasum -a 256 "${DEST}/doto.ttf" | awk '{print $1}')"
  [ "${GOT}" = "${FONT_SHA}" ] \
    || die "${APP} 里的点阵字刷新后仍对不上（拿到 ${GOT}）"
done
say "点阵字已刷新（doto.ttf ${FONT_SHA:0:16}…）"

# ── 2b. 图标 ────────────────────────────────────────────────────
# 交付的那个 .app 是早就摆好的壳，Info.plist 是手工写的 —— 它的图标得在这里
# 补，光在 make-app.sh 里加只够源码目录那个壳用。少一步的后果很具体：客户装完
# 在「应用程序」里看到的还是那个空白方框。
ICNS="${ROOT}/resources/AppIcon.icns"
[ -f "${ICNS}" ] || die "找不到 ${ICNS}（跑一下 /usr/local/bin/python3 scripts/make-icon.py）"
for APP in "${SRC_APP}" "${PAYLOAD_APP}"; do
  mkdir -p "${APP}/Contents/Resources"
  cp "${ICNS}" "${APP}/Contents/Resources/AppIcon.icns"
  PLIST="${APP}/Contents/Info.plist"
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "${PLIST}" 2>/dev/null || true)" != "AppIcon" ]; then
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "${PLIST}" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon' "${PLIST}" >/dev/null 2>&1 \
      || die "${PLIST} 写不进 CFBundleIconFile"
  fi
  # 和图标同一个道理：payload 那个壳的 Info.plist 也是手工写的。少了这个键，
  # 客户双击两下 App 图标就会多出一份连不上模块的第二实例 —— 两个菜单栏图标，
  # 一个正常一个带斜杠，他点到哪个全看运气。运行时那条兜底在代码里，但先让
  # 系统压根不要起第二份。
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :LSMultipleInstancesProhibited' "${PLIST}" 2>/dev/null || true)" != "true" ]; then
    /usr/libexec/PlistBuddy -c 'Add :LSMultipleInstancesProhibited bool true' "${PLIST}" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c 'Set :LSMultipleInstancesProhibited true' "${PLIST}" >/dev/null 2>&1 \
      || die "${PLIST} 写不进 LSMultipleInstancesProhibited"
  fi
  # 第三次同样的道理：麦克风用途说明。make-app.sh 写的全文 plist 只管到源码
  # 目录那个壳，交付壳的 plist 是手工摆的，不改这里就永远补不上。少了这条，
  # 客户打第一通电话时系统会按 TCC 直接拒绝麦克风（判的是「进程要不要用麦克风」，
  # 与走 CoreAudio 还是 AVFoundation 无关，见 CallAudioBridge.swift）——
  # 而这件事只在客户机上、只有到打电话那一刻才暴露。2026-09-26 补。
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "${PLIST}" 2>/dev/null || true)" != "打电话时把您的声音送到 4G 模块" ]; then
    /usr/libexec/PlistBuddy -c 'Add :NSMicrophoneUsageDescription string 打电话时把您的声音送到 4G 模块' "${PLIST}" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c 'Set :NSMicrophoneUsageDescription 打电话时把您的声音送到 4G 模块' "${PLIST}" >/dev/null 2>&1 \
      || die "${PLIST} 写不进 NSMicrophoneUsageDescription"
  fi
  # 第四次同样的道理：不休眠票。这个 App 是 LSUIElement，平时没有窗口，正是
  # App Nap 的典型目标 —— 被节流时主线程会被挂起几秒，症状就是日志里那条
  # 「主线程卡住：4 秒没有响应」（2026-09-28 查到的根因）。这个键让系统层不
  # 挑它节流，运行时那半张票在 AppNap.swift，两边各补一半。交付壳的 plist 是
  # 手工摆的，不写这里就永远补不上。
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :NSAppSleepDisabled' "${PLIST}" 2>/dev/null || true)" != "true" ]; then
    /usr/libexec/PlistBuddy -c 'Add :NSAppSleepDisabled bool true' "${PLIST}" >/dev/null 2>&1 \
      || /usr/libexec/PlistBuddy -c 'Set :NSAppSleepDisabled true' "${PLIST}" >/dev/null 2>&1 \
      || die "${PLIST} 写不进 NSAppSleepDisabled"
  fi
done
say "图标已就位（AppIcon.icns + CFBundleIconFile）"

# ── 3. 重签 ─────────────────────────────────────────────────────
# 顺序不能反：bundle 的签名覆盖里面的可执行文件，先签里面那个再签外层，
# 否则 --verify --deep --strict 会说「资源被改过」。
# 2026-09-30：改走 scripts/sign-app.sh —— 有固定证书就用固定证书。临时签名的
# 身份是 cdhash，客户每装一次新版本，之前点过的麦克风授权就作废（系统的授权框
# 一辈子只弹一次），表现成「昨天还能打电话，今天没声音」。固定证书的身份是
# certificate root，装多少遍授权都还在。没有证书时它自己退回临时签名。
sign_one() {
  local APP="$1"
  [ -f "${APP}/Contents/Resources/dji4gctl" ] && \
    "${ROOT}/scripts/sign-app.sh" "${APP}/Contents/Resources/dji4gctl" >/dev/null 2>&1 || true
  "${ROOT}/scripts/sign-app.sh" "${APP}/Contents/MacOS/DJI4GMenuBar" >/dev/null 2>&1 || true
  "${ROOT}/scripts/sign-app.sh" --deep "${APP}" >/dev/null 2>&1 || true
  codesign --verify --deep --strict "${APP}" >/dev/null 2>&1 \
    || die "${APP} 签名校验没过，装到客户机器上会被系统杀掉。"
  say "已重签并验证：${APP}"
}
sign_one "${SRC_APP}"
sign_one "${PAYLOAD_APP}"

# ── 3b. 客户机上才暴露的坑 ──────────────────────────────────────
# 2026-09-25：一位客户装了 15:46 那一版，点开面板就闪退。根因不在打码，
# 在 SwiftPM 自动生成的 Bundle.module —— 它只认「app 根目录」和「编译那台
# 机器上的 .build 目录」，资源明明躺在 Contents/Resources 里它也不看。本机
# 因为 .build 还在，一直看不出问题；客户机上两条都落空，直接 fatalError。
# 教训是「只在本机能跑」的包必须在上传前拦下来，所以下面两道闸：
#   1. 源码里不许再出现 Bundle.module（它是上面那条坑的唯一入口）
#   2. 拿交付的那个 app 跑一遍 fontcheck，按客户机的布局确认字体找得到
# 只认真正的调用（Bundle.module.xxx）。注释里提到这个名字是允许的 ——
# 上面那段解释和 AppResources 的文档都写着它。
if grep -rn "Bundle\.module\." "${ROOT}/Sources" >/dev/null 2>&1; then
  grep -rn "Bundle\.module\." "${ROOT}/Sources" >&2 || true
  die "Sources/ 里还有 Bundle.module：它在客户机上找不到资源包会直接崩。改用 AppResources。"
fi
say "闸门 1/5 通过：源码里没有 Bundle.module 调用"

# 就算哪天有人绕开源码检查，二进制里也不该出现「编译机的资源包路径」。
# 这正是 2026-09-25 那份崩溃报告里打印出来的第二行。
if strings -a "${STAGE_BIN}/DJI4GMenuBar" | grep -qE "\.build/.*DJI4GMenuBar\.bundle"; then
  strings -a "${STAGE_BIN}/DJI4GMenuBar" | grep -E "\.build/.*DJI4GMenuBar\.bundle" >&2 || true
  die "二进制里写死了编译机的资源包路径，客户机上会闪退。"
fi
say "闸门 2/5 通过：二进制里没有编译机路径"

# fontcheck 只看文件布局，与架构无关 —— 客户机上跑同一条命令也是这个结果。
if ! "${STAGE_BIN}/dji4gctl" fontcheck "${PAYLOAD_APP}" >/tmp/dji4g-fontcheck.txt 2>&1; then
  cat /tmp/dji4g-fontcheck.txt >&2
  die "交付的 app 自己找不到点阵字，装到客户机上会闪退。"
fi
grep -E "字体|✓" /tmp/dji4g-fontcheck.txt | sed 's/^/    /'
say "闸门 3/5 通过：交付的 app 自带点阵字"

# 前三条管的是「App 能不能启动」。这一条管的是「语音能不能装上」——它同样是
# 「只在本机能跑」的一类：源码树里躺着的资源不会自己进包，而本机永远测不出来。
# 所以逐个数一遍，连 adb 的架构一起看：客户的 M 系列 Mac 上，x86_64 的 adb
# 是跑不起来的（Rosetta 只在个别机器上装了）。
for F in manifest.json qdc507_aprv3.ko qdc507_voice.ko mavo-pcm-bridge.armv7 adb; do
  [ -f "${PAYLOAD_APP}/Contents/Resources/ModuleVoice/${F}" ] \
    || die "交付的 app 里缺 ModuleVoice/${F}：客户点「一键安装」会失败。"
done
[ -x "${PAYLOAD_APP}/Contents/Resources/ModuleVoice/adb" ] \
  || die "交付的 app 里自带的 adb 没有可执行位，客户机上点不动。"
lipo -archs "${PAYLOAD_APP}/Contents/Resources/ModuleVoice/adb" 2>/dev/null | grep -q arm64 \
  || die "自带的 adb 里没有 arm64 —— 客户的 M 系列 Mac 上跑不了。"
say "闸门 4/5 通过：通话语音资源与自带 adb 都在包里"

# ── 4. zip ──────────────────────────────────────────────────────
# 「双击安装」要在客户机器上改 App 的壳，所以两个包都用 ditto 打：
# 它保住可执行位、符号链接和 xattr，用 zip 命令则会丢。
say "打 App 单包…"
ditto -c -k --keepParent --norsrc --noextattr --noacl --noqtn "${PAYLOAD_APP}" "${DEL}/${ZIP_APP}"

say "打完整安装包…"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dji4g-pack.XXXXXX")"
PKG="${STAGE}/${FOLDER_INSTALLER}"
mkdir -p "${PKG}"
cp "${DEL}/客户说明.txt" "${PKG}/使用说明.txt"
cp "${DEL}/install.sh"   "${PKG}/install.sh"
cp "${DEL}/双击安装.command" "${PKG}/双击安装.command"
cp "${DEL}/卸载.command"     "${PKG}/卸载.command"
cp "${DEL}/诊断.command"     "${PKG}/诊断.command"
ditto "${DEL}/安装图解" "${PKG}/安装图解"
# 目录名用「程序」而不是 payload：客户解开压缩包时会看到这个目录，
# install.sh 找 App 的地方里「程序」排在第一位。交付文档写的也是它。
ditto --noqtn --norsrc --noextattr "${PAYLOAD_APP}" "${PKG}/程序/DJI4G.app"
chmod +x "${PKG}/双击安装.command" "${PKG}/卸载.command" "${PKG}/诊断.command"
# 给客户双击的三个文件绝不能带隔离标记，否则他以后双击「诊断」会被系统拦下。
# 这一步放在设图标之前：xattr -cr 会连图标一起抹掉。
xattr -cr "${PKG}" 2>/dev/null || true

# ── 4b. 三个 .command 的图标 ─────────────────────────────────────
# 客户解开压缩包看到的是三张白纸 —— Finder 对 .command 显示的是脚本内容的
# 缩略图，「双击安装」和「卸载」长得一模一样，全靠读文件名。这里给它们各挂一个
# 图标（安装=往托盘里放、卸载=拿出来、诊断=心电波形）。
# 图标存在扩展属性里，所以下面打 zip 时不能再带 --norsrc --noextattr。
SETICON="${STAGE_BIN}/set-fileicon"
if [ ! -x "${SETICON}" ]; then
  say "编译 set-fileicon…"
  /usr/bin/xcrun swiftc -O -o "${SETICON}" "${ROOT}/scripts/set-fileicon.swift" \
    || die "编译 set-fileicon 失败"
fi
"${SETICON}" "${ROOT}/resources/FileIcons/install.icns"   "${PKG}/双击安装.command" \
  && "${SETICON}" "${ROOT}/resources/FileIcons/uninstall.icns" "${PKG}/卸载.command" \
  && "${SETICON}" "${ROOT}/resources/FileIcons/diagnose.icns"  "${PKG}/诊断.command" \
  || die "给 .command 设图标失败"
say "三个 .command 已带上图标"

# ── 4c. 另打一份「带图标」的桌面工具 tar.gz ─────────────────────
# 为什么还要多这一个资产：install.sh 从服务器取这三个文件走的是 HTTP。
# HTTP 传的是纯字节，资源分支（Finder 图标就住在那里）根本过不去 ——
# 客户装完，桌面上是三个一模一样的白板文件，只能靠读文件名分辨。
# zip 那条路之所以没事，是因为客户拿浏览器下载完整 zip 再用 Finder 解开，
# 一路上资源分支都还在。
#
# macOS 自带的 tar 默认走 copyfile(3)，扩展属性和资源分支一起进包、一起出来。
# 整包 20 KB 上下，单独当第四个资产发，代价可以忽略。
# 它是可选的：服务器上取不到，install.sh 会退回单文件直下，只是没图标。
#
# 成员名必须是 ASCII。install.sh 里是
#   tar -xzf … diagnose.command
# 这种写法按名字点成员；中文名进了包，那边就永远找不到。
# 所以先 ditto 到暂存目录换成 ASCII 名再打 —— 路径上每一步都得是 ditto，
# cp(1) 只搬数据分支，搬到一半图标就掉了，等于白设。
TOOLS_STAGE="${STAGE}/桌面工具"
mkdir -p "${TOOLS_STAGE}"
ditto "${PKG}/诊断.command"  "${TOOLS_STAGE}/diagnose.command"
ditto "${PKG}/卸载.command"  "${TOOLS_STAGE}/uninstall.command"
ditto "${PKG}/使用说明.txt"  "${TOOLS_STAGE}/README.txt"
# COPYFILE_DISABLE=0 本来就是 macOS tar 的默认值，这里显式写出来是防着外层
# 环境里被人设过 1 —— 那个值一开，图标就没了。
#
# --mac-metadata 这个开关看着像废话，其实是这条路上唯一真正管用的东西。
# 实测（bsdtar 3.5.3 / libarchive 3.7.4，2026-09-26）：
#   不加 → 包 141801 字节，资源分支「看上去」也写进去了，可 tar -xzf 解出来
#          xattr 干干净净，图标没了，而且不报任何错；
#   加   → 包 194125 字节，解出来 ResourceFork 与源文件逐字节相同
#          （252103 个十六进制字符全等），FinderInfo 也一致。
# 也就是说：不写这个开关，打出来的包是个安静的坏包 —— 这正是当初
# 「安装包里明明有图标、客户桌面上却是三个白板」那类事故的形状。
COPYFILE_DISABLE=0 tar --mac-metadata -czf "${DEL}/${TOOLS_TARBALL}" \
  -C "${TOOLS_STAGE}" diagnose.command uninstall.command README.txt
say "桌面工具 ${TOOLS_TARBALL}（$(wc -c < "${DEL}/${TOOLS_TARBALL}" | tr -d ' ') 字节）"

# --noqtn 不打隔离标记：客户那边解压出来的东西越干净，Gatekeeper 越没有机会插嘴。
# 资源分叉这次要留着（--norsrc/--noextattr 去掉），图标就在里面。
ditto -c -k --keepParent --noacl --noqtn "${PKG}" "${DEL}/${ZIP_INSTALLER_LOCAL}"

# ── 5. 校验和 ───────────────────────────────────────────────────
# 文件内容里写的名字永远是服务器上的 ASCII 名 —— 客户下载后跑的是
# `shasum -a 256 -c dji4g-1.0-universal.zip.sha256`，名字对不上会报错。
hash_line() {
  local FILE="$1" NAME="$2"
  ( cd "$(dirname "${FILE}")" && shasum -a 256 "$(basename "${FILE}")" | sed "s|$(basename "${FILE}")$|${NAME}|" )
}
APP_HASH="$(hash_line "${DEL}/${ZIP_APP}" "${ZIP_APP}")"
INS_HASH="$(hash_line "${DEL}/${ZIP_INSTALLER_LOCAL}" "${ZIP_INSTALLER_LOCAL}")"
INS_HASH_ASSET="$(hash_line "${DEL}/${ZIP_INSTALLER_LOCAL}" "${ZIP_INSTALLER_ASSET}")"
printf '%s\n' "${APP_HASH}" > "${DEL}/${ZIP_APP}.sha256"
# 校验和里写的名字必须和它旁边那个文件同名，否则客户（或我们自己）
# `shasum -a 256 -c` 会直接报 FAILED —— 本地这份写中文名，只有放到
# 发布资产里的那一份才写服务器上的 ASCII 名。
printf '%s\n' "${INS_HASH}" > "${DEL}/${ZIP_INSTALLER_LOCAL}.sha256"
# ASCII 名的那一份只属于 发布资产/（服务器上的名字）——交付根目录里绝不写它，
# 否则会留下「ASCII 名 .sha256 配着上一个版本的旧 zip」这种对不上的组合。
say "App 单包  ${APP_HASH%% *}"
say "安装包    ${INS_HASH%% *}"

# ── 6. 同步：发布资产 / 桌面 ────────────────────────────────────
ASSETS="${DEL}/发布资产"
PUB="${ASSETS}/DJI4G-installer.zip"
cp "${DEL}/${ZIP_INSTALLER_LOCAL}" "${PUB}"
cp "${DEL}/${ZIP_APP}" "${ASSETS}/${ZIP_APP}"
cp "${DEL}/客户说明.txt"   "${ASSETS}/README.txt"
cp "${DEL}/诊断.command"   "${ASSETS}/diagnose.command"
cp "${DEL}/卸载.command"   "${ASSETS}/uninstall.command"
cp "${DEL}/install.sh"     "${ASSETS}/install.sh"
cp "${DEL}/双击安装.command" "${ASSETS}/双击安装.command"
cp "${DEL}/${TOOLS_TARBALL}"      "${ASSETS}/${TOOLS_TARBALL}"
printf '%s\n' "${APP_HASH}" > "${ASSETS}/${ZIP_APP}.sha256"
printf '%s\n' "${INS_HASH_ASSET}" > "${ASSETS}/${ZIP_INSTALLER_ASSET}.sha256"
chmod +x "${ASSETS}/diagnose.command" "${ASSETS}/uninstall.command" \
         "${ASSETS}/install.sh" "${ASSETS}/双击安装.command"
say "发布资产已刷新"

if [ -d "${DESK}" ]; then
  mkdir -p "${HAND}"
  cp "${DEL}/${ZIP_INSTALLER_LOCAL}" "${HAND}/${ZIP_INSTALLER_LOCAL}"
  cp "${DEL}/客户说明.txt"          "${HAND}/客户说明.txt"
  # 「发给客户」里常常还躺着上一轮解开的那份同名文件夹，而 Finder 解压遇到
  # 重名只会另起「DJI4G-安装包 2」，从不覆盖 —— 于是 zip 是新的、文件夹是旧的，
  # 谁去双击里面那个 .command，装进去的就是上一轮的 App。
  # 这个坑真踩过：07:05 从旧文件夹装了一份 4773136 字节的构建进 /Applications，
  # 界面上的改动人眼一个都看不见，还以为是没改对。这里跟着 zip 一起刷。
  if [ -d "${HAND}/${FOLDER_INSTALLER}" ]; then
    OLD_HAND="${DESK}/_旧副本-20260924"
    mkdir -p "${OLD_HAND}"
    mv "${HAND}/${FOLDER_INSTALLER}" \
       "${OLD_HAND}/${FOLDER_INSTALLER}-旧解压-$(date +%Y%m%d-%H%M%S)"
    ditto -x -k "${DEL}/${ZIP_INSTALLER_LOCAL}" "${HAND}"
    say "发给客户/ 里已解开的那份已刷成新包（旧的挪进 _旧副本）"
  fi
  if [ -d "${TOOLS}" ]; then
    for F in "${ZIP_INSTALLER_LOCAL}" "${ZIP_INSTALLER_LOCAL}.sha256" \
             "${ZIP_APP}" "${ZIP_APP}.sha256" "客户说明.txt" "README.txt" \
             "诊断.command" "diagnose.command" "卸载.command" "uninstall.command" \
             "install.sh" "双击安装.command" "交付流程.md" "README.md" \
             "${TOOLS_TARBALL}"; do
      [ -f "${DEL}/${F}" ] && cp "${DEL}/${F}" "${TOOLS}/${F}"
    done
    # ASCII 名的那一对要单独从发布资产取：交付目录里没有这个名字，
    # 之前这行是静默跳过的，桌面上就留下了一个几轮之前的旧安装包。
    cp "${ASSETS}/${ZIP_INSTALLER_ASSET}"          "${TOOLS}/${ZIP_INSTALLER_ASSET}"
    cp "${ASSETS}/${ZIP_INSTALLER_ASSET}.sha256"   "${TOOLS}/${ZIP_INSTALLER_ASSET}.sha256"
    # 同一个坑还埋着第二处：上面 for 循环里的 ASCII 名（diagnose/uninstall/README）
    # 在交付目录里也不存在 → 同样静默跳过。实测桌面上的 diagnose.command
    # 就这样落后过一轮（6959 字节 vs 8874）。这里显式补上。
    cp "${ASSETS}/diagnose.command"  "${TOOLS}/diagnose.command"
    cp "${ASSETS}/uninstall.command" "${TOOLS}/uninstall.command"
    cp "${ASSETS}/README.txt"        "${TOOLS}/README.txt"
    ditto "${DEL}/payload"     "${TOOLS}/payload"
    ditto "${DEL}/安装图解"    "${TOOLS}/安装图解"
    ditto "${ASSETS}"          "${TOOLS}/发布资产"
    chmod +x "${TOOLS}/诊断.command" "${TOOLS}/双击安装.command" "${TOOLS}/卸载.command" 2>/dev/null || true
    xattr -cr "${TOOLS}" 2>/dev/null || true
    # 上面那行 xattr -cr 是为了清隔离标记，代价是连图标一起抹掉 ——
    # 客户包里的图标是打在打包暂存目录上的，没受影响；但工作副本这一份
    # 会变成三张白纸，翻「交付工具」的时候看着就像图标没做。按同一个办法补回来。
    if [ -x "${SETICON}" ]; then
      for PAIR in "install.icns:双击安装.command" \
                  "uninstall.icns:卸载.command" \
                  "uninstall.icns:uninstall.command" \
                  "diagnose.icns:诊断.command" \
                  "diagnose.icns:diagnose.command"; do
        ICON="${PAIR%%:*}"; TARGET_FILE="${TOOLS}/${PAIR#*:}"
        [ -f "${TARGET_FILE}" ] && "${SETICON}" "${ROOT}/resources/FileIcons/${ICON}" \
          "${TARGET_FILE}" >/dev/null 2>&1
      done
      say "交付工具里的 .command 图标已补回"
    fi
  fi
  xattr -cr "${HAND}/${ZIP_INSTALLER_LOCAL}" 2>/dev/null || true
  say "桌面已同步"
else
  warn "桌面路径不存在（${DESK}），这次没有同步桌面 —— 别当成同步过了"
fi

# ── 6.5 交付根目录里不许再有 ASCII 名的安装包 ───────────────────
# 历史遗留：交付根目录躺过一个 3156741 字节的旧 DJI4G-installer.zip，
# 而旁边的 .sha256 却是新写的 —— 两份对不上。发现就挪走，不再留歧义。
if [ -e "${DEL}/${ZIP_INSTALLER_ASSET}" ]; then
  mv "${DEL}/${ZIP_INSTALLER_ASSET}" "${DEL}/_历史遗留-${ZIP_INSTALLER_ASSET}"
  warn "交付根目录里翻出历史遗留的 ${ZIP_INSTALLER_ASSET}，已改名为 _历史遗留-${ZIP_INSTALLER_ASSET}"
fi
if [ -e "${DEL}/${ZIP_INSTALLER_ASSET}.sha256" ]; then
  mv "${DEL}/${ZIP_INSTALLER_ASSET}.sha256" "${DEL}/_历史遗留-${ZIP_INSTALLER_ASSET}.sha256"
  warn "交付根目录里翻出历史遗留的 ${ZIP_INSTALLER_ASSET}.sha256，已改名加前缀"
fi

# ── 7. 自检：校验和全绿、各处副本同哈希 ─────────────────────────
say "自检…"
for PAIR in "${DEL}/${ZIP_APP}.sha256" "${DEL}/${ZIP_INSTALLER_LOCAL}.sha256" \
            "${ASSETS}/${ZIP_APP}.sha256" "${ASSETS}/${ZIP_INSTALLER_ASSET}.sha256"; do
  ( cd "$(dirname "${PAIR}")" && shasum -a 256 -c "$(basename "${PAIR}")" ) >/dev/null 2>&1 \
    || die "校验和没对上：${PAIR}"
done

# 同一个包在不同副本里必须逐字节一致（中文名 / ASCII 名混着比）
same_hash() {
  local EXPECT="$1"; shift
  local F
  for F in "$@"; do
    if [ -f "${F}" ]; then
      [ "$(shasum -a 256 "${F}" | cut -d' ' -f1)" = "${EXPECT}" ] \
        || die "副本不一致：${F}"
    fi
  done
}
same_hash "${INS_HASH%% *}" \
  "${DEL}/${ZIP_INSTALLER_LOCAL}" "${ASSETS}/${ZIP_INSTALLER_ASSET}" \
  "${HAND}/${ZIP_INSTALLER_LOCAL}" "${TOOLS}/${ZIP_INSTALLER_LOCAL}" \
  "${TOOLS}/${ZIP_INSTALLER_ASSET}" "${TOOLS}/发布资产/${ZIP_INSTALLER_ASSET}"
same_hash "${APP_HASH%% *}" \
  "${DEL}/${ZIP_APP}" "${ASSETS}/${ZIP_APP}" \
  "${TOOLS}/${ZIP_APP}" "${TOOLS}/发布资产/${ZIP_APP}"
# 脚本类文件也不能两处版本不同（install.sh 曾经踩过静默跳过）。
# 每条写清楚「交付目录叫什么 / 发布资产叫什么 / 桌面各处叫什么」。
check_scripts() {
  local GROUP="$1"   # 用法：本地名 发布资产名 交付工具名
  shift
  local LOCAL="$1" ASSET="$2" TOOLSNAME="$3"
  [ -f "${DEL}/${LOCAL}" ] || return 0
  local H; H="$(shasum -a 256 "${DEL}/${LOCAL}" | cut -d' ' -f1)"
  local F
  # 桌面根目录不再留脚本副本（客户只从 zip 里取），所以这里只比三处；
  # 发给客户/ 里那份说明书不在这个循环里，另行比对（见下面那条 same_hash）。
  for F in "${DEL}/${LOCAL}" "${ASSETS}/${ASSET}" "${TOOLS}/${TOOLSNAME}"; do
    if [ -f "${F}" ]; then
      [ "$(shasum -a 256 "${F}" | cut -d' ' -f1)" = "${H}" ] || die "副本不一致：${F}"
    fi
  done
  say "  ${LOCAL} 一致"
}
check_scripts install   install.sh   install.sh        install.sh
check_scripts diagnose  诊断.command diagnose.command  诊断.command
check_scripts uninstall 卸载.command uninstall.command 卸载.command
check_scripts readme    客户说明.txt README.txt        客户说明.txt
# 发给客户/ 里除 zip 外还有一份说明书（客户在手机上要先读得到），也必须同源。
same_hash "$(shasum -a 256 "${DEL}/客户说明.txt" | cut -d' ' -f1)" \
  "${HAND}/客户说明.txt"
# 包里的东西必须和刚打的那份同源：解开来直接比。
# 这条是为了「发出去的包是上一轮的」这类事故 —— 之前踩过两次，
# 每次都是靠人眼在桌面上翻文件才发现的。
APPNAME="DJI4G.app"
VERIFY_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dji4g-verify.XXXXXX")"
ditto -x -k "${DEL}/${ZIP_INSTALLER_LOCAL}" "${VERIFY_TMP}"
V_PKG="${VERIFY_TMP}/${FOLDER_INSTALLER}"
[ -d "${V_PKG}/程序/${APPNAME}" ] || die "安装包里没有 程序/${APPNAME}（install.sh 会找不到 App）"
[ -f "${V_PKG}/install.sh" ]      || die "安装包里没有 install.sh"
[ "$(shasum -a 256 "${V_PKG}/install.sh" | cut -d' ' -f1)" \
  = "$(shasum -a 256 "${DEL}/install.sh" | cut -d' ' -f1)" ] \
  || die "安装包里的 install.sh 和交付目录里的不是同一份"
V_ARCHS="$(lipo -archs "${V_PKG}/程序/${APPNAME}/Contents/MacOS/DJI4GMenuBar")"
case "${V_ARCHS}" in *x86_64*) ;; *) die "包里的 App 缺 x86_64（本机就是 Intel，先跑得起来才对）";; esac
case "${V_ARCHS}" in *arm64*)  ;; *) die "包里的 App 缺 arm64（客户是 M4，没有它根本打不开）";; esac
codesign --verify --deep --strict "${V_PKG}/程序/${APPNAME}" >/dev/null 2>&1 \
  || die "包里的 App 签名有问题，装到客户机器上会被系统杀掉。"
# 图标也要在包里验一遍：这条路径正是当初漏掉的那条 —— 源目录有图标、交付包没有，
# 而两边都没人打开看过。
[ -f "${V_PKG}/程序/${APPNAME}/Contents/Resources/AppIcon.icns" ] \
  || die "包里的 App 没有 AppIcon.icns，客户装完看到的是空白图标"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "${V_PKG}/程序/${APPNAME}/Contents/Info.plist" 2>/dev/null || true)" = "AppIcon" ] \
  || die "包里的 Info.plist 没写 CFBundleIconFile，图标不会生效"
# 麦克风说明也在「解出来的那一份」上验：这条路径跟图标一样，只有真去解一次才知道。
[ "$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "${V_PKG}/程序/${APPNAME}/Contents/Info.plist" 2>/dev/null || true)" = "打电话时把您的声音送到 4G 模块" ] \
  || die "包里的 Info.plist 没写 NSMicrophoneUsageDescription，客户打电话会被系统拒绝麦克风"
# 不休眠票也要在「解出来的那一份」上验：和图标、麦克风说明同一条路径，只有真
# 解一次才知道它有没有跟到包里。少了它，客户那台机器会偶发「面板卡几秒」。
[ "$(/usr/libexec/PlistBuddy -c 'Print :NSAppSleepDisabled' "${V_PKG}/程序/${APPNAME}/Contents/Info.plist" 2>/dev/null || true)" = "true" ] \
  || die "包里的 Info.plist 没写 NSAppSleepDisabled，客户会偶发「面板卡住几秒」"
[ -f "${SRC_APP}/Contents/Resources/AppIcon.icns" ] \
  || die "源码目录的 App 没有图标"
# .command 的图标也要在「解出来的那一份」上验：这类属性最容易被 zip 那一步丢掉，
# 而丢没丢只有真去解一次才知道。
for F in 双击安装.command 卸载.command 诊断.command; do
  xattr "${V_PKG}/${F}" 2>/dev/null | grep -q "com.apple.ResourceFork" \
    || die "解压后 ${F} 没有图标（zip 把资源分叉丢了）"
done
# 第四个资产也得验一次。这个资产当初就是为「桌面图标」才加的，
# 图标偏偏是最容易在最后一步被丢掉的东西 —— 而丢没丢，只有真解一次才知道。
V_TOOLS_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dji4g-tools.XXXXXX")"
tar -xzf "${ASSETS}/${TOOLS_TARBALL}" -C "${V_TOOLS_TMP}" 2>/dev/null \
  || die "${TOOLS_TARBALL} 解不开 —— 客户在线安装会退回没有图标的单文件下载"
for F in diagnose.command uninstall.command; do
  [ -f "${V_TOOLS_TMP}/${F}" ] || die "${TOOLS_TARBALL} 里没有 ${F}"
  xattr "${V_TOOLS_TMP}/${F}" 2>/dev/null | grep -q "com.apple.ResourceFork" \
    || die "${TOOLS_TARBALL} 里的 ${F} 没有资源分支（图标没进 tar）"
done
[ -f "${V_TOOLS_TMP}/README.txt" ] || die "${TOOLS_TARBALL} 里没有 README.txt"
# 解出来的这份还要和包内那份逐字节一致，否则「在线装」和「解 zip 装」两条路
# 会让客户拿到两个不同版本的诊断脚本。只比数据分支，shasum 本来也只读那个。
for PAIR in "diagnose.command:诊断.command" "uninstall.command:卸载.command"; do
  [ "$(shasum -a 256 "${V_TOOLS_TMP}/${PAIR%%:*}" | cut -d' ' -f1)" \
    = "$(shasum -a 256 "${V_PKG}/${PAIR#*:}" | cut -d' ' -f1)" ] \
    || die "${TOOLS_TARBALL} 里的 ${PAIR%%:*} 和安装包里的不是同一份"
done
say "桌面工具 tar.gz 已验证（成员齐全、图标在位、与包内同源）"
say "包内自检通过（install.sh 同源、App 双架构 ${V_ARCHS}、签名有效、图标在位）"

# 桌面那份「已经解开」的副本也得比一次。它曾经是整条链上唯一没人验的一环，
# 也是唯一真的把旧 App 装进 /Applications 的一环 —— 上面 4 组校验和全绿，
# 客户（和卖家自己）装的仍然是上一轮。
if [ -d "${HAND}/${FOLDER_INSTALLER}/程序/${APPNAME}" ]; then
  [ "$(shasum -a 256 "${HAND}/${FOLDER_INSTALLER}/程序/${APPNAME}/Contents/MacOS/DJI4GMenuBar" | cut -d' ' -f1)" \
    = "$(shasum -a 256 "${V_PKG}/程序/${APPNAME}/Contents/MacOS/DJI4GMenuBar" | cut -d' ' -f1)" ] \
    || die "发给客户/ 里解开的那份 App 不是这一轮的，双击它会装出旧界面"
  say "  发给客户/ 已解开的那份也是这一轮的"
fi

say "自检通过：4 组校验和、全部副本同哈希"

# ── 8. 收尾 ─────────────────────────────────────────────────────
echo
echo "──────────────────────────────────────────────"
say "打包完成。发布到 GitHub："
echo "  gh release upload v1.0 \\"
echo "    \"${ASSETS}/dji4g-1.0-universal.zip\" \"${ASSETS}/dji4g-1.0-universal.zip.sha256\" \\"
echo "    \"${ASSETS}/DJI4G-installer.zip\" \"${ASSETS}/DJI4G-installer.zip.sha256\" \\"
echo "    \"${ASSETS}/README.txt\" \"${ASSETS}/diagnose.command\" \\"
echo "    \"${ASSETS}/uninstall.command\" \"${ASSETS}/install.sh\" \\"
echo "    \"${ASSETS}/${TOOLS_TARBALL}\" \\"
echo "    --repo zhangyuan-a11y/dji4g-mac --clobber"
echo "（不要传中文名文件：GitHub 会把「双击安装.command」改写成 default.command）"
echo
say "微信里直接发给客户的就是这两样（都在 ${HAND}/）："
echo "  DJI4G-安装包.zip   ← 安装包（解开就有图解和三个 .command）"
echo "  客户说明.txt       ← 说明书，客户在手机上先读这一份"
echo
echo "编译两个架构（打包前跑一次）："
echo "  export HOME=\"\${PWD}/.buildhome\" CLANG_MODULE_CACHE_PATH=\"\${PWD}/.buildhome/clangcache\""
echo "  swift build -c release --disable-sandbox --scratch-path .build"
echo "  swift build -c release --arch arm64 --scratch-path .build-arm64 \\"
echo "    --cache-path .buildhome/swiftpm-cache-arm64"
