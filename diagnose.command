#!/bin/bash
# ============================================================================
#  DJI 4G 模块 · 一键诊断 / 售后取证
#
#  双击运行即可。它只做「读」操作，不会修改模块的任何设置，
#  也不会读取你的短信内容。
#
#  跑完会在桌面生成一个 zip，把它发回给服务商即可。
# ============================================================================
set -uo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
DISPLAY_NAME="DJI4G-诊断-${STAMP}"
ZIP="${HOME}/Desktop/${DISPLAY_NAME}.zip"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dji4g-diag.XXXXXX")"
DIR="${WORK}/${DISPLAY_NAME}"
mkdir -p "${DIR}"
TXT="${DIR}/报告.txt"
APPLOG="${DIR}/系统日志.txt"

say()  { printf '\033[1;32m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
head_() { printf '\n\n========== %s ==========\n' "$*" >> "${TXT}"; }
cmd_()  { printf '\n$ %s\n' "$*" >> "${TXT}"; "$@" >> "${TXT}" 2>&1; }

echo "==============================================="
echo "  DJI 4G 模块 · 诊断"
echo "==============================================="
echo
say "收集信息中，全程只读，不会改动任何设置。"

# ── 找到命令行工具 ──────────────────────────────────────────────
CTL=""
for p in \
  "/usr/local/bin/dji4gctl" \
  "/Applications/DJI4G.app/Contents/Resources/dji4gctl" \
  "${HOME}/Applications/DJI4G.app/Contents/Resources/dji4gctl"
do
  if [ -x "${p}" ]; then CTL="${p}"; break; fi
done

APP=""
for p in "/Applications/DJI4G.app" "${HOME}/Applications/DJI4G.app"; do
  if [ -d "${p}" ]; then APP="${p}"; break; fi
done

# ── 1. 主机环境 ─────────────────────────────────────────────────
head_ "1. 主机环境"
{
  echo "采集时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "主机名：$(hostname)"
  echo "系统：$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "架构：$(uname -m)"
  echo "型号标识：$(sysctl -n hw.model 2>/dev/null || echo '（读不到）')"
  MEMMB="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  if [ "${MEMMB}" -gt 0 ] 2>/dev/null; then
    echo "内存：$(( MEMMB / 1024 / 1024 / 1024 )) GB"
  fi
  echo
  echo "--- 硬件概览（用来确认机型）---"
  system_profiler SPHardwareDataType 2>/dev/null | sed -n '1,18p' | grep -v -i 'serial number' || echo "(读不到)"
} >> "${TXT}" 2>&1
say "主机环境 ✓"

# ── 2. 安装状态 ─────────────────────────────────────────────────
head_ "2. 软件安装状态"
{
  if [ -n "${APP}" ]; then
    echo "App 位置：${APP}"
    echo -n "App 架构："; lipo -info "${APP}/Contents/MacOS/DJI4GMenuBar" 2>&1
    echo "签名校验："
    codesign --verify --deep --strict --verbose=2 "${APP}" 2>&1 | sed 's/^/  /'
    codesign -dv --verbose=2 "${APP}" 2>&1 | sed 's/^/  /'
    echo
    printf '进程状态：'
    if pgrep -f "DJI4G.app/Contents/MacOS/DJI4GMenuBar" >/dev/null 2>&1; then
      echo "菜单栏 App 正在运行"
    else
      echo "菜单栏 App 没在运行"
    fi
  else
    echo "没有找到 DJI4G.app（/Applications 和 ~/Applications 都没有）"
  fi
  echo
  echo "命令行工具：${CTL:-未找到}"
} >> "${TXT}" 2>&1
say "安装状态 ✓"

# ── 3. 二进制是否能在这台机器上跑 ───────────────────────────────
head_ "3. 二进制自检（Apple 芯片上被签名问题杀掉会在这里暴露）"
if [ -n "${CTL}" ]; then
  printf '\n$ %s selftest\n' "${CTL}" >> "${TXT}"
  if "${CTL}" selftest >> "${TXT}" 2>&1; then
    say "自检通过 ✓"
  else
    RC=$?
    warn "自检没通过（见报告第 3 节）"
    echo "（退出码：${RC}）" >> "${TXT}"
  fi
else
  echo "跳过：没找到 dji4gctl" >> "${TXT}"
  warn "没找到 dji4gctl，跳过自检"
fi

# ── 4. USB 枚举 ─────────────────────────────────────────────────
head_ "4. USB 枚举（模块有没有被系统认出来）"
{
  echo "--- 所有串口设备 ---"
  ls -1 /dev/cu.* /dev/tty.* 2>/dev/null || echo "(没有任何串口设备——模块可能没插好)"
  echo
  echo "--- USB 树中和模块相关的部分 ---"
  system_profiler SPUSBDataType 2>/dev/null \
    | grep -i -B4 -A 18 -E 'EG25|Quectel|DJI|2ca3|2c7c|4G' \
    || echo "(USB 树里没有找到 Quectel / EG25 / 2ca3 设备——模块没插，或者被识别成了别的设备)"
  echo
  echo "--- ioreg 原始记录 ---"
  ioreg -p IOUSB -w 0 2>/dev/null | grep -i -E '2ca3|2c7c|quectel|eg25|dji|4g' \
    || echo "(无)"
} >> "${TXT}" 2>&1
say "USB 枚举 ✓"

# ── 5. 模块体检 ─────────────────────────────────────────────────
if [ -n "${CTL}" ]; then
  head_ "5. 模块体检 doctor"
  cmd_ "${CTL}" doctor
  say "体检完成 ✓"

  head_ "6. 状态总览 status"
  cmd_ "${CTL}" status

  head_ "7. 网络诊断 network"
  cmd_ "${CTL}" network

  head_ "8. 模块声卡通道 voice"
  cmd_ "${CTL}" voice

  head_ "9. macOS 网络服务 net-status"
  cmd_ "${CTL}" net-status
  say "模块状态 ✓"
else
  head_ "5-9. 模块状态"
  echo "跳过：没找到 dji4gctl" >> "${TXT}"
fi

# ── 10. App 运行日志 ────────────────────────────────────────────
say "收集系统日志（可能要十几秒）…"
{
  echo "窗口：最近 30 分钟"
  echo
  log show --last 30m --style compact \
    --predicate 'process == "DJI4GMenuBar"' 2>/dev/null | tail -200
} > "${APPLOG}" 2>&1

if [ ! -s "${APPLOG}" ]; then
  echo "(没有日志，或系统不给读)" > "${APPLOG}"
fi

# ── 10. 界面截图（客户看到的界面，出问题时最直观）────────────────
#  只读：把面板的五个画面画成 PNG，连同真机摘要一起放进报告。
#  App 正在运行时不跑这一步 —— 两个进程同时读 AT 口会互相抢，
#  客户正看着的面板会闪一下。要看截图就先退出 App 再跑一次。
head_ "10. 界面截图"
SHOTS="${DIR}/界面截图"
BIN="${APP}/Contents/MacOS/DJI4GMenuBar"
mkdir -p "${SHOTS}"
if [ ! -x "${BIN}" ]; then
  echo "跳过：没找到 App 本体（${BIN}）" >> "${TXT}"
elif pgrep -f "DJI4G.app/Contents/MacOS/DJI4GMenuBar" >/dev/null 2>&1; then
  echo "跳过：菜单栏 App 正在运行，不能同时读模块。" >> "${TXT}"
  echo "想要界面截图：先退出菜单栏 App（点菜单栏图标 → 退出），再跑一次诊断。" >> "${TXT}"
else
  printf '\n$ %s --render %s --hardware\n' "${BIN}" "${SHOTS}" >> "${TXT}"
  # 二进制被系统杀掉时（比如这次会话没有图形界面），bash 会自己往终端印一行
  # 「Abort trap: 6」。客户看到那行，只会以为诊断把电脑搞坏了。办法是让它在一
  # 个子 shell 里收尾：子 shell 里还有第二条命令，bash 就不会把第一条 exec 掉，
  # 那行提示也就跟着子 shell 的 stderr 一起被丢掉。退出码照样拿得到，真正的
  # 失败原因仍然原样写进报告。
  RENDER_RC=1
  ( "${BIN}" --render "${SHOTS}" --hardware >> "${TXT}" 2>&1; echo $? > "${WORK}/render.rc" ) 2>/dev/null
  [ -f "${WORK}/render.rc" ] && RENDER_RC="$(cat "${WORK}/render.rc")"
  if [ "${RENDER_RC}" = "0" ]; then
    ls -1 "${SHOTS}" >> "${TXT}" 2>/dev/null
    say "界面截图 ✓"
  else
    printf '（这一步失败不影响上面几节；退出码 %s）\n' "${RENDER_RC}" >> "${TXT}"
    warn "界面截图没跑成功（报告其余部分不受影响）"
  fi
fi

# ── 打包 ────────────────────────────────────────────────────────
ditto -c -k --keepParent "${DIR}" "${ZIP}" 2>/dev/null

echo
echo "==============================================="
if [ -f "${ZIP}" ]; then
  SIZE="$(du -h "${ZIP}" | cut -f1 | tr -d ' ')"
  say "报告已生成：${ZIP}（${SIZE}）"
  echo
  echo "  把这个 zip 整个发给服务商就行。"
  echo "  报告只包含：系统版本、USB 枚举、模块状态、运行日志。"
  echo "  不包含您的短信内容和联系人。"
  echo
  open -R "${ZIP}" 2>/dev/null || true
else
  warn "打包失败。请手动把 ${DIR} 这个文件夹发给服务商。"
  open "${DIR}" 2>/dev/null || true
fi
echo "==============================================="
echo
read -r -p "按回车关闭这个窗口…" _ 2>/dev/null || true
