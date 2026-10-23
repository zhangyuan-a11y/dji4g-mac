#!/bin/sh
# SwiftPM produces a bare executable, which Finder cannot double-click and
# which has no place to put LSUIElement. This wraps it in a normal .app.
#
# The bundle is named "DJI4G.app" with no space: LaunchServices resolves
# "DJI 4G.app" by path but `open` on it returns kLSNoExecutableErr, and a
# bundle whose name contains a space is the usual cause.
set -e
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" --disable-sandbox

APP="DJI4G.app"
# Move the previous bundle aside instead of deleting it: the same script has to
# work under a sandbox that refuses `rm -rf`.
if [ -d "$APP" ]; then
    mv "$APP" "${TMPDIR:-/tmp}/dji4g-app-replaced-$$" 2>/dev/null || mv "$APP" "./old-$APP.$$"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/$CONFIG/DJI4GMenuBar" "$APP/Contents/MacOS/DJI4GMenuBar"

# 图标：以前这里什么都没有，Finder 和「登录项」里就是一个空白方框。
# resources/AppIcon.icns 是 scripts/make-icon.py 画出来的，改配色改那个脚本。
if [ -f "resources/AppIcon.icns" ]; then
    cp "resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "！resources/AppIcon.icns 不在，App 会是个空白图标" >&2
fi

# 资源包跟着 app 走。注意 SwiftPM 自动生成的 Bundle.module 并不看
# Contents/Resources/ —— 它只看 app 根目录和编译机上的 .build 目录，
# 客户机上两条都不在，一取就 fatalError（2026-09-25 客户机上 25 份崩溃
# 报告）。代码里已经改成走 AppResources 自己找，这里照旧放 Resources。
# 名字是 SwiftPM 的 "<package>_<target>.bundle"。
for BUNDLE in ".build/$CONFIG"/*_DJI4GMenuBar.bundle; do
    [ -d "$BUNDLE" ] && cp -R "$BUNDLE" "$APP/Contents/Resources/"
done

# 通话语音的模块侧资源：两个 .ko、PCM 桥、出厂校准，加一份自带的 adb。
# 这几样必须跟着 app 走 —— 客户机上既没有源码树也没有 platform-tools，
# 少了这个目录，真到打电话那一刻只会回一句「通话语音组件没装全」。
# 2026-09-30 就是这么漏过一次：本机因为 PATH 里正好有 adb、resources/ 又
# 就在手边，怎么试都好，交付出去才发现壳里根本没有 ModuleVoice。
MV_SRC="resources/ModuleVoice"
if [ -d "$MV_SRC" ]; then
    # 老的那一份挪走而不是删（沙箱里 rm -rf 会被拒，脚本得能反复跑）。
    mv "$APP/Contents/Resources/ModuleVoice" "${TMPDIR:-/tmp}/dji4g-mv-old-$$" 2>/dev/null || true
    cp -R "$MV_SRC" "$APP/Contents/Resources/ModuleVoice"
    # zip 解出来丢可执行位的情况见过一次，这里明写一遍。
    chmod 755 "$APP/Contents/Resources/ModuleVoice/adb" 2>/dev/null || true
    # 逐个文件点一遍名：缺一个，客户那边的电话就是没声音，而本机看不出来。
    for NEED in manifest.json adb mavo-pcm-bridge.armv7 qdc507_voice.ko qdc507_aprv3.ko; do
        if [ ! -e "$APP/Contents/Resources/ModuleVoice/$NEED" ]; then
            echo "！App 里少了 ModuleVoice/$NEED，客户机上电话会没声音" >&2
            exit 1
        fi
    done
    if [ ! -x "$APP/Contents/Resources/ModuleVoice/adb" ]; then
        echo "！App 里的 ModuleVoice/adb 不可执行" >&2
        exit 1
    fi
else
    echo "！resources/ModuleVoice 不在，App 里不会有通话语音组件" >&2
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DJI4G</string>
    <key>CFBundleDisplayName</key><string>DJI 4G</string>
    <key>CFBundleExecutable</key><string>DJI4GMenuBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>local.dji4g.menubar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <!-- 双击 App 图标第二下时不再起第二份。两份会并排画两个一模一样的 4G
         图标，客户不知道该点哪个；而且两份都能连上模块，等于两个进程抢同一个
         AT 口。2026-09-26 客户截图实测。运行时那条兜底和跨 bundle 的进程锁
         在 Sources/DJI4GMenuBar/SingleInstance.swift。 -->
    <key>LSMultipleInstancesProhibited</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <!-- 通话那一路要打开 Mac 的麦克风（CoreAudio 的 AUHAL，见
         CallAudioBridge.swift），而 TCC 是按「进程要不要用麦克风」判的，
         不看走的是 CoreAudio 还是 AVFoundation。少了这一条，客户机上真到
         打电话那一刻，系统要么直接拒绝、要么把进程按死 —— 2026-09-26 的
         M4 客户机上还没验过通话，属于「不补就可能现场翻车」的一条。
         有它而没触发，只是多一行没人看的字符串。 -->
    <key>NSMicrophoneUsageDescription</key><string>打电话时把您的声音送到 4G 模块</string>
    <!-- 这个 App 平时没有窗口，正好是 App Nap 最爱的样子：主线程降优先级、
         定时器被合并、整个进程能被换出去 —— 表现出来就是客户偶尔遇到的
         「面板卡住 4–5 秒又自己好了」，日志里那一行「主线程卡住」。这个键
         让系统层压根不挑它节流；运行时那一半在 AppNap.swift。 -->
    <key>NSAppSleepDisabled</key><true/>
</dict>
</plist>
PLIST

# 签名走 scripts/sign-app.sh —— 现在只用临时签名（ad-hoc），不再依赖
# dji4g-signing 钥匙串（那张自签证书的钥匙串密码对不上，codesign 一碰就弹
# 密码框；而且自签证书本来也不被 Gatekeeper 信任）。理由和代价见 sign-app.sh。
sh "$(dirname "$0")/sign-app.sh" "$APP"
echo "已生成 $APP"
