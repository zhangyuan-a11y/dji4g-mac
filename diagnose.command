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

# 面板一打开就要读点阵字。SwiftPM 自动生成的 Bundle.module 只认「app 根目录」
# 和「编译那台机器的 .build 目录」—— 资源明明在 Contents/Resources 里它也不看。
# 开发机上 .build 恰好在，所以看不出来；客户机上两条都落空，一点开面板就闪退
# （2026-09-25 一位客户发回来的 25 份崩溃报告全是这一行）。这一条专门验它。
if [ -n "${CTL}" ] && [ -n "${APP}" ]; then
  printf '\n$ %s fontcheck %s\n' "${CTL}" "${APP}" >> "${TXT}"
  if "${CTL}" fontcheck "${APP}" >> "${TXT}" 2>&1; then
    say "面板点阵字 ✓"
  else
    warn "点阵字资源不在 app 里，一点开面板就会闪退（见报告第 3 节）"
  fi
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

# App 自己的日志（如果这个版本开始写的话）。崩溃和「点了没反应」这类
# 问题，系统日志经常什么都不留，只有这张表能还原现场。
APPDIR="${DIR}/App日志"
mkdir -p "${APPDIR}"
FOUND_APP_LOG=0
for d in "${HOME}/Library/Logs/DJI4G" "/Library/Logs/DJI4G"; do
  [ -d "${d}" ] || continue
  for f in "${d}"/*.log "${d}"/*.txt; do
    [ -f "${f}" ] || continue
    cp "${f}" "${APPDIR}/$(basename "${d}")-$(basename "${f}")" 2>/dev/null && FOUND_APP_LOG=1
  done
done
if [ "${FOUND_APP_LOG}" = "1" ]; then
  ls -1 "${APPDIR}" >> "${TXT}" 2>/dev/null
  say "App 日志 ✓"
else
  echo "（这个版本的 App 还没有自己的日志文件）" >> "${TXT}"
fi

# ── 10. 界面截图（客户看到的界面，出问题时最直观）────────────────
#  只读：把面板的五个画面画成 PNG，连同真机摘要一起放进报告。
#  App 正在运行时不跑这一步 —— 两个进程同时读 AT 口会互相抢，
#  客户正看着的面板会闪一下。要看截图就先退出 App 再跑一次。
head_ "10. 界面截图"
#  两张图合起来回答一个关键问题：界面本身能不能画出来。
#  「菜单栏图标点不开」要么是画不出来（App 的问题），要么是画得出来但
#  那个弹窗没出来（系统那一层的问题）。这两种的修法完全不同，而在客户的
#  机器上离屏渲染一遍就能分开。不带 --hardware 的渲染走的是内存模拟，
#  不碰模块，所以 App 开着的时候也能安全跑。
SHOTS="${DIR}/界面截图"
BIN="${APP}/Contents/MacOS/DJI4GMenuBar"
mkdir -p "${SHOTS}"
APP_RUNNING=0
pgrep -f "DJI4G.app/Contents/MacOS/DJI4GMenuBar" >/dev/null 2>&1 && APP_RUNNING=1

render_into() {
  local outdir="$1"; shift
  mkdir -p "${outdir}"
  printf '\n$ %s --render %s %s\n' "${BIN}" "${outdir}" "$*" >> "${TXT}"
  local rc=1
  ( "${BIN}" --render "${outdir}" "$@" >> "${TXT}" 2>&1; echo $? > "${WORK}/render.rc" ) 2>/dev/null
  [ -f "${WORK}/render.rc" ] && rc="$(cat "${WORK}/render.rc")"
  echo "${rc}"
}

if [ ! -x "${BIN}" ]; then
  echo "跳过：没找到 App 本体（${BIN}）" >> "${TXT}"
  warn "没找到 App 本体，跳过界面截图"
else
  RC_MAIN=1
  if [ "${APP_RUNNING}" = "1" ]; then
    echo "菜单栏 App 正在运行：用内存模拟渲染（不读模块，不会打扰正在看的界面）。" >> "${TXT}"
    RC_MAIN="$(render_into "${SHOTS}/模拟")"
    RC_EXTRA="$(render_into "${SHOTS}/无模块" --nomodule)"
    RC_NOSIM="$(render_into "${SHOTS}/没插卡" --nosim)"
    echo "（附加场景退出码：无模块=${RC_EXTRA} 没插卡=${RC_NOSIM}）" >> "${TXT}"
  else
    echo "App 没在运行：连着模块一起渲染，截图里是这台机器的真实数据。" >> "${TXT}"
    RC_MAIN="$(render_into "${SHOTS}/真机" --hardware)"
  fi

  # 判定：有没有真的画出 PNG。这是「界面能不能渲染」的直接答案。
  PNG_N="$(find "${SHOTS}" -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
  {
    echo
    echo "---- 小结 ----"
    echo "渲染进程退出码：${RC_MAIN}"
    echo "画出来的 PNG 数量：${PNG_N}"
    if [ "${PNG_N}" -gt 0 ] 2>/dev/null; then
      echo "→ 界面能正常渲染。菜单栏图标点不开，问题在「弹窗没出来」这一层，"
      echo "  不在界面本身（报告里带回去的就是这些图）。"
    else
      echo "→ 一张图都没画出来，界面渲染这一步本身就有问题，退出码见上面。"
    fi
  } >> "${TXT}"

  if [ "${PNG_N}" -gt 0 ] 2>/dev/null; then
    find "${SHOTS}" -name '*.png' 2>/dev/null | sed "s|${DIR}/||" >> "${TXT}"
    say "界面截图 ✓（${PNG_N} 张）"
  else
    printf '（这一步失败不影响上面几节；退出码 %s）\n' "${RC_MAIN}" >> "${TXT}"
    warn "界面截图没跑成功（报告其余部分不受影响）"
  fi
fi

# ── 11. 面板窗口（「图标点得动、面板不弹」时最关键的一档）────────
#  客户报的正是这个现象，而开发机上怎么点都正常 —— 能回答这个问题的只有
#  他自己那台机器。这一步跑的就是「双击 App 图标」那条后路：真的在屏幕上
#  开一个面板窗口，再把窗口清单和那一刻的实拍图带回来。
#  它会在屏幕中间开一个窗口（几秒后自己关掉），期间菜单栏会多出一个图标，
#  那也是它；不碰模块（用的是模拟数据），也不改任何设置。
head_ "11. 面板窗口（点不开时那条后路走不走得通）"
if [ ! -x "${BIN}" ]; then
  echo "跳过：没找到 App 本体（${BIN}）" >> "${TXT}"
  warn "没找到 App 本体，跳过面板窗口检查"
else
  PANEL_DIR="${DIR}/面板窗口"
  mkdir -p "${PANEL_DIR}"
  {
    echo "这一步会短暂地在屏幕中间开一个面板窗口，几秒后自己关掉；"
    echo "期间菜单栏会多出一个图标，那也是它。用的是模拟数据，不碰模块。"
  } >> "${TXT}"
  printf '\n$ %s --panel-window-check %s\n' "${BIN}" "${PANEL_DIR}" >> "${TXT}"
  #  直接起成后台进程而不是套一层子 shell：万一它挂在窗口上不退，
  #  下面那个计时器杀的是它本人（套子 shell 的话杀掉的只是壳，
  #  真进程会留在客户机器上，比不跑这一步更糟）。
  "${BIN}" --panel-window-check "${PANEL_DIR}" >> "${TXT}" 2>&1 &
  PANEL_PID=$!
  ( sleep 25; kill -TERM "${PANEL_PID}" 2>/dev/null ) &
  WATCH_PID=$!
  PANEL_RC=0
  wait "${PANEL_PID}" 2>/dev/null || PANEL_RC=$?
  kill "${WATCH_PID}" 2>/dev/null
  # 这一步不能省：watchdog 多半还在睡着就被杀了，bash 会在收尸时往终端上
  # 打一行「Terminated: 15」—— 客户双击跑诊断，看到这么一行会以为出了事。
  # 自己 wait 一次，那句通知就不会打。
  wait "${WATCH_PID}" 2>/dev/null
  PANEL_PNG="$(find "${PANEL_DIR}" -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
  {
    echo
    echo "---- 小结 ----"
    echo "退出码：${PANEL_RC}（0 = 面板窗口能自己铺出来；143 = 超过 25 秒被脚本收掉）"
    echo "实拍图：${PANEL_PNG} 张"
    if [ "${PANEL_RC}" = "0" ]; then
      echo "→ 这条路是通的：双击 App 图标（或者面板弹不出来时双击一次）能把面板"
      echo "  开成一个独立窗口，报告里那张图就是它当时的样子。"
    else
      echo "→ 这条路也没走通，那就不是「菜单栏弹窗」这一层的事了。把退出码、"
      echo "  上面的窗口清单和实拍图一起发回给服务商。"
    fi
  } >> "${TXT}"
  if [ "${PANEL_RC}" = "0" ]; then
    say "面板窗口 ✓"
  else
    warn "面板窗口这一档没通过（退出码 ${PANEL_RC}，见报告第 11 节）"
  fi
fi

# ── 12. 崩溃报告（判断「点菜单栏没反应」是不是 App 崩了）────────
#  菜单栏图标点不开最常见的原因，其实是 App 在那一瞬间崩掉、然后被系统
#  自动拉起来 —— 表面看图标一直在，实际中间换过一个进程。崩溃报告是唯一
#  的硬证据，所以整份收进来。
say "收集崩溃报告…"
CRASH="${DIR}/崩溃报告"
mkdir -p "${CRASH}"
CRASH_N=0
for d in "${HOME}/Library/Logs/DiagnosticReports" "/Library/Logs/DiagnosticReports"; do
  [ -d "${d}" ] || continue
  for f in "${d}"/DJI4G* "${d}"/DJI4G*/*; do
    [ -f "${f}" ] || continue
    cp "${f}" "${CRASH}/$(basename "${f}")" 2>/dev/null && CRASH_N=$((CRASH_N + 1))
  done
done

# 「App 崩溃过」这五个字不带时间就是一句吓人的废话：客户三周前的那次崩溃
# 和眼前这个毛病可能毫无关系，而真正要紧的「崩溃是不是发生在当前这一版上」
# 反而没写。`.ips` 的文件名里带着崩溃时刻，所以这里把时间抠出来，再和现在
# 装着的这一版比一比，直接给出该不该追。
crash_stamp() {
  basename "$1" .ips \
    | sed -n 's/.*-\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{6\}\)$/\1/p'
}
crash_epoch() {
  local stamp
  stamp="$(crash_stamp "$1")"
  [ -n "${stamp}" ] || return 1
  date -j -f "%Y-%m-%d-%H%M%S" "${stamp}" "+%s" 2>/dev/null || return 1
}
APP_BIN="/Applications/DJI4G.app/Contents/MacOS/DJI4GMenuBar"
NEWEST_EPOCH=""
NEWEST_STAMP=""
for f in "${CRASH}"/DJI4G*.ips; do
  [ -f "${f}" ] || continue
  E="$(crash_epoch "${f}")" || continue
  if [ -z "${NEWEST_EPOCH}" ] || [ "${E}" -gt "${NEWEST_EPOCH}" ]; then
    NEWEST_EPOCH="${E}"
    NEWEST_STAMP="$(crash_stamp "${f}")"
  fi
done
BUILT_EPOCH=""
[ -f "${APP_BIN}" ] && BUILT_EPOCH="$(stat -f %m "${APP_BIN}" 2>/dev/null || true)"

{
  echo "找到 ${CRASH_N} 个和 DJI4G 相关的崩溃报告。"
  if [ "${CRASH_N}" = "0" ]; then
    echo "→ App 从来没有崩溃过。菜单栏点不开和崩溃无关。"
  else
    echo "→ App 崩溃过。每个 .ips 里搜 termination / exception 能看到原因。"
    if [ -n "${NEWEST_STAMP}" ]; then
      echo "   最近一次：$(date -j -f "%Y-%m-%d-%H%M%S" "${NEWEST_STAMP}" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "${NEWEST_STAMP}")"
      if [ -n "${BUILT_EPOCH}" ]; then
        echo "   现在装着的这一份：$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "${APP_BIN}" 2>/dev/null)"
        if [ "${NEWEST_EPOCH}" -lt "${BUILT_EPOCH}" ]; then
          echo "   → 最近一次崩溃发生在现在这一版之前，多半已经修掉了。"
          echo "     要是现在还出问题，把这份报告发回来 —— 第 12 节是硬证据。"
        else
          echo "   → 最近一次崩溃就在现在这一版上，这份报告一定要发回给服务商。"
        fi
      fi
    fi
  fi
  echo
  echo "报告目录里一共有这些文件（供参考，不含内容）："
  ls -1t "${HOME}/Library/Logs/DiagnosticReports" 2>/dev/null | head -30
} > "${CRASH}/摘要.txt" 2>&1
[ "${CRASH_N}" != "0" ] && warn "发现 ${CRASH_N} 个崩溃报告（见第 12 节）" || say "没有崩溃报告 ✓"

# ── 13. launchd 运行记录（App 被重启过几次、上次怎么退出的）──────
head_ "13. 菜单栏 App 的 launchd 记录"
{
  echo "这一段能直接回答：App 被系统拉起来过几次、上一次是正常退出还是崩了。"
  echo
  echo "安装信息："
  for p in "${HOME}/Library/LaunchAgents/local.dji4g.menubar.plist" \
           "/Library/LaunchAgents/local.dji4g.menubar.plist"; do
    if [ -f "${p}" ]; then
      echo "  找到：${p}"
      plutil -p "${p}" 2>&1 | sed 's/^/    /'
    fi
  done
  echo
  echo "--- launchctl print（关键行）---"
  LC_OUT="$(launchctl print "gui/$(id -u)/local.dji4g.menubar" 2>&1)"
  printf '%s\n' "${LC_OUT}" | grep -E 'state|runs|pid|last exit|program|path|keepalive|KeepAlive|successful' -i \
    || printf '%s\n' "${LC_OUT}" | head -20
  echo
  echo "--- launchctl print（完整输出）---"
  printf '%s\n' "${LC_OUT}"
  echo
  echo "--- 当前进程 ---"
  ps -Ao pid,ppid,lstart,etime,stat,comm 2>/dev/null | grep -i 'DJI4GMenuBar' | grep -v grep \
    || echo "  （App 没在运行）"
  echo
  echo "--- 进程启动时间（换算成已运行多久）---"
  pgrep -f 'DJI4G.app/Contents/MacOS/DJI4GMenuBar' >/dev/null 2>&1 \
    && echo "  App 正在运行" || echo "  App 没在运行"
} >> "${TXT}" 2>&1
say "launchd 记录 ✓"

# ── 打包 ────────────────────────────────────────────────────────
ditto -c -k --keepParent "${DIR}" "${ZIP}" 2>/dev/null

echo
echo "==============================================="
if [ -f "${ZIP}" ]; then
  SIZE="$(du -h "${ZIP}" | cut -f1 | tr -d ' ')"
  say "报告已生成：${ZIP}（${SIZE}）"
  echo
  echo "  把这个 zip 整个发给服务商就行。"
  echo "  报告只包含：系统版本、USB 枚举、模块状态、运行日志、界面截图、"
  echo "  面板窗口实拍图、崩溃报告（如果有）。"
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
