# DJI 4G 一代模块 · macOS 菜单栏控制器

给 **大疆一代 4G 模块**（BAIWANG QDC507，基带 Quectel EG25-G，USB `2CA3:4006`）
用的 macOS 菜单栏程序，目标是三件事：

| 功能 | 靠什么实现 | 出厂状态 |
| --- | --- | --- |
| 收发短信 | 纯 AT 命令 | ✅ 插上就能用 |
| 电话（拨号 · 接听 · 挂断 · 来电提醒） | 纯 AT 命令 | ✅ 插上就能用 |
| 通话记录（谁打来、接没接到、说了多久） | 纯 AT 命令 + App 自己攒一份 | ✅ 插上就能用 |
| 通话声音（双向） | AT 解锁 ADB + 厂商语音驱动 + 出厂校准 + PCM 桥 | ⚠️ 要装一次（App 里点一下，见下） |
| Mac 上网 | CDC-ECM 网卡 + macOS 网络服务 | ⚠️ 出厂关闭，要开一次 |

这不是闭源商业软件「DJI 4G 控制器」的拷贝，而是照着它的**功能**重写的实现。
原程序是 arm64 单架构 + 激活码 + 反调试的闭源包，没法也不打算复制它的代码。

## 为什么有几件「要开一次」的事

模块对外只提供一条 AT 串口、一个 USB 网络功能、一个 USB 音频功能，这三样
由**同一条命令**控制：

```
AT+QCFG="usbcfg",0x2CA3,0x4006,1,1,1,1,1,0,0
                 │      │      ↑       ↑ ↑
                 │      │      │       │ └── audio   出厂 0  ← 模块声卡（通话语音的载体）
                 │      │      │       └──── adb     出厂 0
                 │      │      └──────────── network 出厂 1  ← 已开
                 │      └─────────────────── pid
                 └────────────────────────── vid

字段顺序（USBComposition.flags）：
    name, vid, pid, diag, nmea, at, modem, network, adb, audio

AT+QCFG="usbnet"        → 出厂 0 = RNDIS（Windows 默认），macOS 只认 1 = ECM ← 要改
```

也就是说，一代模块出厂状态在 macOS 上**上不了网、模块声卡也是关的**：USB 网络
模式是 RNDIS（macOS 没有对应驱动），音频位是 0。

注意这几件事的**性质不同**，别改错位：

- `usbcfg` 里的 network 位（第 8 个字段）出厂**已经是 1**，ECM 功能本来就在组态里，
  不用动。真正卡住的是下面的 `usbnet` **模式**——模式不对，macOS 没有对应驱动，
  ECM 功能开着也认不出来。
- `usbcfg` 里的 audio 位（最后一个字段）出厂是 **0**，这个也要改成 1。
  它是通话语音的载体：这一位不开，模块不会把自己枚举成声卡，后面装什么都
  听不见。但光把它打开也还不够 —— 还要在模块上装一次语音通路，见下面
  「通话语音要装一次」一节。

短信、来电和拨号信令不受这两项影响，因为它们只走 AT 口。

改这两项之后模块会重启（重新枚举 USB），macOS 才会看到「USB 音频设备」和
「以太网卡」。详细说明见 [`docs/NETWORKING.md`](docs/NETWORKING.md)。

## 构建与运行

需要 Swift 6 / Xcode 命令行工具即可，没有第三方依赖。

```bash
swift build -c release          # 编译
swift build -c release 2>&1 | grep -E "error|warning"   # 应为空
./scripts/make-app.sh           # 打包成可双击的 DJI4G.app
open DJI4G.app                  # 只出现在菜单栏，不占 Dock
```

命令行工具：

```bash
./.build/release/dji4gctl doctor        # 端到端体检：逐项检查 + 给出该执行的命令
./.build/release/dji4gctl status        # 模块/SIM/网络/流量总览
./.build/release/dji4gctl network       # 联网诊断（会直接指出卡在哪一步）
./.build/release/dji4gctl sms-list
./.build/release/dji4gctl sms-send 10086 108
./.build/release/dji4gctl call-dial 10000
./.build/release/dji4gctl net-status    # macOS 网络服务是开还是关
./.build/release/dji4gctl net-enable    # 让流量走模块
./.build/release/dji4gctl net-disable   # 把默认路由还给 Wi-Fi
```

没有硬件也能跑：

```bash
./.build/release/dji4gctl selftest      # 全量自检，不需要模块
./.build/release/dji4gctl sim           # 内置模拟模块，可交互
DJI4GMenuBar --render /tmp/shots        # 把所有界面渲染成 PNG（模拟器供数）
DJI4GMenuBar --render /tmp/hw --hardware # 真机：真模块供数，出 5 张图 + 状态摘要
```

菜单栏 App 自己也能跑模拟模块，用来在没有硬件的机器上过一遍界面和状态机：

```bash
DJI4GMenuBar --sim           # 假装模块插着、卡插好了
DJI4GMenuBar --sim-nosim     # 假装模块插着、卡没插
DJI4GMenuBar --sim-check     # 不开界面，逐条断言跑一遍，全绿退出码 0
```

`--sim` / `--sim-nosim` 是真的开界面：可以拨号、接听、拒接、收短信、发短信、
看通知，走的全是真 App 的代码路径，只是底下换成了模拟器。`--sim-check` 是把
这些动作在无头模式下自动跑一遍 —— 每一条都等到状态真的出现为止，没有一条是
「等固定秒数」。三条命令都**不扫 IOKit、不碰真 USB**，所以它们证明的是界面和
状态机自洽，不能替代插卡实测。

`--render` 有三种供数方式，别混：默认走模拟器（和 `--sim` 同一套数据）；
`--nomodule` 跑真 App 的连接路径、但假定 USB 口是空的，用来盯「没插模块」
那几句文案；`--hardware` 同样跑真路径，但**等**模块把卡、注册、信号报上来
再截图，并在输出目录里写一份 `hardware-summary.txt`。`--hardware` 是给远程
排障用的：让客户跑一条命令，把图和摘要发回来，比隔着电话问「你那显示什么」准。
三种都需要 WindowServer，都要在普通终端里跑。

`selftest` 覆盖 PDU 编解码（含中文 UCS-2 与长短信分段）、AT 解析、来电状态机、
通话等待、模块声卡的切换判定（含「挂断自动还回去」）、端到端体检的判定、流量计数、以及 macOS
网络服务表的解析。**它全绿只能证明代码自洽，不能证明模块能跑** —— 真正的
USB 枚举和 AT 通信必须插上硬件才算数。

## 一次只做一件事

模块在 USB 上是一条一条命令回话的，两个动作同时发就会把 AT 流量交错在一起。
所以所有动作都走同一道闸门（`AppModel.run`）：**前一个没结束时，后一个会被
挡下**。

挡下这件事本身有三个坑，都踩过：

- 挡下之后**必须说话**。静默丢弃会让按钮看起来是坏的：客户点了「接听」，什么
  都没发生。现在被挡下的动作会写明「上一步操作还没结束，……没有执行，请稍候
  再试」，而且这句话会出现在**被点的那个窗口里** —— 呼叫窗口浮在面板上面，
  只写在面板里等于没写。
- 带回调的动作**必须回调**。短信弹窗等的就是它，漏掉这一条，弹窗会永远停在
  「发送中…」，等于告诉客户消息可能已经发出去了。
- 报错不能长生不老。下一次动作成功就清掉红色报错，否则客户把卡插回去、成功
  发出短信之后，面板还在红字说「未检测到 SIM 卡」。历史留在「模块设置 → 日志」。

## 通话等待

通话中再有电话进来，运营商不会让它响铃，而是把它「挂」在当前通话后面，模块
用 `+CCWA` 通知主机。这时候 `AT+CLCC` 会**返回两行**：一行通话中，一行等待
接听。

两个坑：

- 面板只能显示一路通话。如果取第一行，显示的就是正在通话的那路，等待来电会
  在下一次轮询时被悄悄抹掉 —— 看起来像是响了一声就没了。所以
  `CallService.preferred` 明确排序：等待接听 > 响铃 > 通话中 > 拨号中 > 保持中。
- 等待中的电话不是「在响」，所以**不能用 `ATA` 接**，模块会直接回 ERROR。
  接它要用 `AT+CHLD=2`（保持当前通话，接新的那路）；拒接要用 `AT+CHLD=0`，
  用 `AT+CHUP` 会把整通电话都挂掉，包括你正在说的这通。

顺带一提：`AT+CCWA=1` 必须显式打开，否则模块根本不会上报 `+CCWA`，第二路来电
就静默消失了。

## 通话记录为什么不问模块

模块**没有**通话历史。`AT+CLCC` 报的是「此刻在响 / 在通」的那几路，问完就没了；
`AT+CPBS` / `AT+CPBR` 那套电话本是空页（真机上读过），一代 QDC507 的固件里也
没有别的口子能把「昨天谁打来过」翻出来。

所以「通话」窗口里那一列是 **App 自己攒的**：每一通电话从响铃到挂断/接起的
状态变化都被抄成一行，落在

```
~/Library/Application Support/DJI4G/calllog.json
```

关窗口、重启电脑之后还在，最多留 200 条（超了丢最旧的）。记的字段是号码、
方向、结果（已接通 / 没接到 / 已拒接 / 未接通）和时长。

两条边界：

- **App 没在跑的那段时间不记。** 记录是 App 看着状态变化攒的，没运行就没有人
  在看着。它开机自启，所以这个窗口通常就是「开机到关机」。
- **只记在这台 Mac 上。** 换台电脑是另一份；「清空」也只删这一份，模块和卡都
  不动（模块里本来也没存）。

号码进日志之前会脱敏：`+8618957549662` 写成 `+86****9662`（留头三位、尾四位，
认得出是哪一通；客服短号 `10086` 原样留着）。客户桌面上的「诊断.command」
打出来的报告是会被发出去的，里面不该跟着一串完整手机号。落盘只有
`calllog.json` 一个文件，和短信一样在本机。

## 通话语音要装一次（「一键安装通话语音」做了什么）

**接听电话本身不会把声音接上** —— 信令走 AT 口，声音走模块的 USB 声卡，是两条
完全不同的通路。这一点以前被写成「切过去就有声音」，再后来又被写成「一代模块的
语音根本不进 USB 声卡」。2026-09-25 的真机实测把两半都量清楚了：**声卡确实是
语音的通路，但固件默认不建 DSP 语音通路** —— 声卡摆在那儿，通话时两个方向都是
死线（往它送 440Hz 再录回来，81920 个采样点全是 0）。

缺的东西能补上。App 里「通话」窗口那格「通话语音」点一下（命令行是
`dji4gctl voice-provision --install`）就是下面五步，做过的会跳过：

| 步骤 | 做什么 | 为什么非做不可 |
| --- | --- | --- |
| 1 | `AT+QADBKEY` 解锁 ADB，`usbcfg` 的 adb 位置 1，重启 | 后面几步都要在模块自己的 shell 里做 |
| 2 | `insmod qdc507_aprv3.ko` + `qdc507_voice.ko` | 固件里没有这两个驱动，语音通道靠它们建 |
| 3 | 往 `/run/alsaucm_test` 写出厂校准 | 建起 `Voice Call` 那条 verb，接上 Auxpcm 收发 |
| 4 | 起 PCM 桥 + `echo 1 > …/f_audio/audio_enable` | 把 DSP 通路的采样点接到 USB 声卡上 |
| 5 | 通话时跑 `CallAudioBridge` | Mac 麦克风 → `AS Interface`，`AC Interface` → Mac 扬声器 |

第五步是自动的：通话一开始，App 就把 Mac 的麦克风和扬声器接到模块上，挂断自动
拆开，**全程不动系统默认设备** —— 不会因为接个电话就听不见电脑的声音。

几个坑写在这里，省得再踩一遍：

- 「`AT+QAUDMOD` 六种模式各拨一通、录音全 0」不是模块不支持，那是**缺了第 2、3
  步**的表现；补上之后同一批录音里就有人声了。
- 声卡开不开**不影响**拨号、接听、挂断和短信：那些只走 AT 口。所以 `Doctor`
  的「模块声卡」一项开着是 `ok`、关着是 `warn`，`blocks` 是空的，不拦任何能力。
- 这一步装在**模块**上，不装在 Mac 上：模块断电（拔下来、或者重启）以后驱动和
  校准就没了，重新插上再点一下那个按钮即可，不必再重启模块。
- 只有 `usbcfg` 的 adb 位还是 0 时，第 1 步才会重启模块（约 20 秒掉线），
  App 会自己等它回来。

来电和短信也会发系统通知，这样不用一直开着面板。

## 开机自启

模块挂在 Mac 后面，图的就是「电话随时能进来」。而这件事在重启之后就不成立了：
菜单栏空着，那段时间的来电和短信全部错过 —— 而且**界面上看不出任何异常**，
看起来就跟「今天没人找我」一模一样。所以 App 会给自己注册一个开机自启：
`~/Library/LaunchAgents/local.dji4g.menubar.plist`。

- 用 LaunchAgent，不用 `SMAppService`：后者拒绝注册 ad-hoc 签名的包，
  而交付出去的每一份都是 ad-hoc 签名。
- 纯用户级，注册和移除都不要管理员密码，卸载就是删掉那个文件。
- `KeepAlive=false`：用户点「退出」就是退出，不会被 launchd 立刻拉回来。
- 注册时不 `launchctl bootstrap`：那会在安装器刚打开的那一份旁边再开一份，
  两个图标抢同一个串口。
- 面板里「模块设置 → 开机自启」可以直接开关；命令行是
  `dji4gctl autostart <on|off|status>`。
- `install.sh` 装完会自动打开它，`卸载.command` 会关掉它。

关掉也能用，只是每次重启之后要自己打开一次 App。

## 目录

```
Sources/CUSBAT        裸 IOKit 的 IOUSBHostDevice，模块的 AT 口
Sources/CMacNet       CDC-ECM 网卡查找与 NET_RT_IFLIST2 计数
Sources/DJI4GCore     AT 会话、PDU、SMS/通话/语音/数据服务、模拟模块
Sources/dji4gctl      命令行
Sources/DJI4GMenuBar  SwiftUI 菜单栏界面
docs/                 联网原理、架构、AT 命令表
resources/ModuleVoice 随包的模块侧语音资源（两个 .ko + PCM 桥 + 自带 adb）
scripts/make-app.sh   打包成 .app
```

## 上真机前的检查

0. 先看一眼面板会长成什么样（可比体检早了，这一步不需要卡）：

   ```bash
   ./.build/release/DJI4GMenuBar --render /tmp/hw --hardware
   ```

   图在 `/tmp/hw`，`hardware-summary.txt` 是同一批数字的文字版。模块没插、
   或者被别的 DJI4G 占着，这一条会如实写出来，不会假装连上了。

1. 插上模块，跑一次体检 —— 它会逐项检查并直接告诉你该执行什么：

   ```bash
   ./.build/release/dji4gctl doctor
   ```

   输出形如：

   ```
     ✓ USB 连接：DJI/QDC507 接口 2（out 0x03 / in 0x84）
     ✓ AT 通道：QDC507GLEFM21 · IMEI 86…
     ! 模块声卡：未开启（出厂组态）。拨号、接听、短信都不看它，但通话语音需要它：
       「一键启用」会顺手写 1，之后跑一次「一键安装通话语音」
         → dji4gctl voice-enable   # 会重启模块
     ! USB 网络模式：当前 RNDIS（Windows），macOS 没有对应驱动
         → dji4gctl usbnet 1   # 会重启模块
     ✓ SIM 卡：已就绪
     ✓ 网络注册：中国电信 · RSRP -99 dBm · 4/5

     可用    来电与拨号
     可用    收发短信
     不可用  联网
   ```

   有待办时退出码是 1，全通是 0，方便脚本判断。

2. 如果体检说「USB 连接：没有找到模块」，确认它真的枚举了：

   ```bash
   system_profiler SPUSBDataType | grep -A 12 -i baiwang
   ```

   期望看到 `2CA3:4006`，以及若干 interface。**如果接口数量和代码里的假设
   不一样，请把这段输出发我**，描述符解析要按实际布局调。

3. 看状态：

   ```bash
   ./.build/release/dji4gctl status
   ./.build/release/dji4gctl network
   ```

4. 开网络（会重启模块，等约 10 秒）：

   ```bash
   ./.build/release/dji4gctl usbnet 1
   ./.build/release/dji4gctl apn CTNET        # 电信；移动 CMNET、联通 UNINET
   ```

5. 装通话语音（第一次会重启模块一次，约 20 秒；之后再插拔只是重装一遍）：

   ```bash
   ./.build/release/dji4gctl voice-provision --install   # 装完自报「通话语音已就绪」
   ./.build/release/dji4gctl audio-bridge 20             # 拨通后跑它，看上下行电平
   ```

6. 只让测试流量走模块，不干扰 Wi-Fi：

   ```bash
   ./.build/release/dji4gctl net-enable
   route -n get default          # 确认默认路由
   curl -I --connect-timeout 8 https://www.apple.com
   ./.build/release/dji4gctl net-disable   # 测完立刻还原
   ```

## 已知限制

- `usbcfg` 的音频位和 ECM 都改完之后，**模块只能二选一地稳定工作**在
  macOS 默认路由上：ECM 服务一旦启用就会顶掉 Wi-Fi 的默认路由，所以 App 默认
  把它关着，点「4G ON」才启用，关闭时立刻还原。
- 通话语音要在模块上装一次（App 里那格「通话语音」点一下）。装之前拨号、接听、
  短信都正常，只是两个方向都没有声音 —— 通话窗口会直说是哪一步没做完。模块
  断电（拔下来）以后要重新点一次：它装在模块上，而不是装在 Mac 上。
- 面板里那个「切到模块」的手动按钮切的是**系统默认输入/输出**，与通话语音无关，
  只在换固件 / 换模块时兜底；挂断时 App 会自动还回你原来的设备。
- 一只模块不能同时直插 Mac 和平板。平板（小米 Pad 等）能否识别取决于其 ROM
  是否带外部 CDC-ECM 支持，普通 App 补不了内核这一层。
- 流量统计是 macOS 网卡字节数，不是运营商账单。
