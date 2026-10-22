# 结构

## 分层

```
DJI4GMenuBar (SwiftUI 菜单栏)
      │  只读 AppModel 的 @Published，不碰 AT
      ▼
AppModel            动作串行化、把 ModemEvent 铺成界面状态
      ▼
ModemController     把 AT 响应变成事件；唯一的事件源
      ▼
SMSService · CallService · VoiceService · DataService · Carrier
      │                    │
      │                    └── Doctor    把一堆事实判成「哪项功能还不能用」
      ▼
ATSession           发命令、等 OK/ERROR、路由主动上报（+CMTI、RING…）
      ▼
ATTransport (协议) ──┬── CUSBATTransport   真机：IOKit 上的裸 USB
                     └── SimulatedATTransport  模拟：内存里的 EG25-G
```

宿主侧（不走 AT）：

```
DataService ──┬── CMacNet    按 VID/PID 找 BSD 网卡、读 NET_RT_IFLIST2 计数
              └── HostNetwork 调 networksetup 读写「网络服务」开关
VoiceService ──── CoreAudio   枚举模块的 USB 声卡（只供手动兜底；通话语音走下面那条）
CallAudioBridge ── CoreAudio   通话期间把 Mac 麦克风/扬声器与 AS/AC Interface 直接对接，
                              挂断即拆，全程不动系统默认设备
ModuleVoiceSetup ─ ADB         把厂商驱动、出厂校准、PCM 桥装到模块上（「一键安装通话语音」）

Notifier（仅菜单栏 App）── UserNotifications   来电 / 新短信的系统通知
```

## 为什么 AT 层要有一个协议

`ATTransport` 只是个能收发字节的东西。真机走 IOKit，模拟器走内存状态机，
**上层代码完全一样**。带来的好处是 `dji4gctl selftest` 里的检查真的在跑
PDU 编解码、AT 解析、来电状态机 —— 而不是在测 mock。真机上唯一没被覆盖的是
USB 枚举本身。

## 判定逻辑要和取数分开

`Doctor` 和 `AudioRouting` 都是**纯函数**：输入事实，输出结论。取数（读 AT、
问 CoreAudio、跑 networksetup）在 `dji4gctl` 和 `AppModel` 里做。分开的理由
不只是好测 —— 判定规则本身才是容易错的地方（「有 IP 但服务没开」算不算联网？
「手动切过音频」要不要在挂断时还原？），而这些规则在真机上很难构造出全部
分支，在自检里却是一行。

## 关键约定

**单位**。`AT+QGDCNT?` 返回的是**字节**，不是 KB。有些 EG25 文档写的是 KB，
按 KB 算会让流量统计差 1024 倍。代码里按字节处理，`DataStatus.format` 负责显示。

**短信存储**。模块上只有 **23 个 PDU 段**的位置，一条长短信要占好几段。所以
列表和「存储 4/23」这类显示读的是 `AT+CPMS?` 的实际值，而不是本地数组长度。

**来电状态**。不要靠 `RING` 推断。`AT+CLCC` 才是可靠来源：它给出方向、状态
（振铃/通话中/保持/等待）和号码。`RING` 只当刷新触发器用。

**状态变了要立刻说**。`CallService.answer/hangup/dial/reject` 是直接改自己的
状态，不会自己发事件；把 `calls.onStateChange` 接到 `emit(.call)` 的是
`ModemController.wireCallStateChanges()`。漏掉这一步不会报任何错 —— 面板会继续
显示上一个状态，直到三十秒后那次 `refreshCalls()` 轮询才纠正过来，看起来就是
「点了接听没反应」。两个 `init` 都要接线，否则走哪条路进去决定了这个 bug 在不在。

**通话等待**。通话中来的第二路电话不会响铃，只会来一条 `+CCWA`；此后
`AT+CLCC` 返回**两行**。面板只显示一路，所以取哪一行是有讲究的：
`CallService.preferred` 把它排成「等待 > 响铃 > 通话中 > 拨号中 > 保持」。
取第一行会显示正在通话的那路，等待来电下一次轮询就被抹掉；反过来，通话等待
切换之后两行是「保持 + 通话中」，这时又必须显示通话中的那路，否则会把正在说的
电话标成「保持中」。接等待来电用 `AT+CHLD=2`（不是 `ATA`，模块会回 ERROR），
拒接用 `AT+CHLD=0`（`AT+CHUP` 会把两路一起挂掉）。

**发送短信的长度**。`AT+CMGS=` 后面要跟的是 **TPDU 长度**，也就是整个 PDU
去掉短信中心那一段之后的长度。算错要么发不出去，要么发出乱码。

**组态解析**。`AT+QCFG="usbcfg"` 有 10 个逗号字段（VID、PID + 7 个功能位），
`ATParsers.qcfgComposite` 按这个数解析，`flagString` 只显示后面 7 位。

**通话语音**。信令和声音是两条通路，而且比「切一下设备」多一层：一代模块的
固件**默认不建 DSP 语音通路**，声卡摆在那儿，通话的两个方向都是死线（2026-09-25
实测：往放音通道送 440Hz 再录回来，81920 个采样点全 0）。2026-09-25 当天把
这条路走通了，办法是给模块补上缺的驱动和出厂校准（见 `ModuleVoiceSetup` 那五步），
再由 `CallAudioBridge` 在通话期间把 Mac 的麦克风接到 `AS Interface`、把
`AC Interface` 接到 Mac 的扬声器。所以：

- 通话的声音**不经过**系统默认输入/输出，`AudioRouting` 里那个「切到模块」
  只是换固件 / 换模块时的手动兜底，挂了自动还回去，而且只还原「自己切的那次」；
- 装语音是**一次性**动作，装在模块上：模块断电以后要重装一遍（App 里点一下），
  但不需要重启模块 —— 除非 `usbcfg` 的 adb 位还是 0（那一次要重启，约 20 秒）。

**通知**。`UNUserNotificationCenter.current()` 在**没有 bundle 的进程里会抛
ObjC 异常**，而 `--render` 正是直接跑 `.build/` 里的裸可执行文件。所以
`Notifier` 先看 `Bundle.main.bundleIdentifier`，为 nil 就整个绕过。

## 两条「有状态」的路径

**轮询**。`ModemController.startPolling` 在一个专用线程上以 0.1–1 秒的间隔读
主动上报，并按节拍刷新信号/网络/来电。`refreshData` 不在轮询里 —— 它要跑
`networksetup`，代价高（见下）。

**动作**。`AppModel.run` 把每个动作丢到后台队列。`isWorking` 期间来的第二个
动作会被**拒绝，而不是排队** —— 模块一条一条回话，排队执行的是过期意图（晚四秒
才生效的「挂断」比不挂断更糟）。但拒绝有三条硬要求：说出口（不写进 `lastError`
就等于按钮坏了）、回话（带回调的动作必须回调，否则短信弹窗永远停在「发送中…」）、
以及报错不能长生不老（下一次成功就清掉，历史留给活动日志）。就算这样，副作用
仍在：**方法返回时活还没干完**，而且 `completion` 比 `isWorking` 清零早一个主
队列轮次，「回调回来了」不等于「模型空了」。所以离屏渲染器必须等它排空
（`RenderHarness.pumpUntilIdle`），否则要么 seed 进去的值被随后落地的刷新覆盖，
要么第 1.5 个动作被当成并发的第 2 个而被拒。自检里这两件事各踩过一次。

**读操作不在此列**。`refreshAll` 是读不是写，它被拒的时候客户看到的是
「上一步操作还没结束，刷新状态没有执行」—— 一句 App 自己刚刷出来的红字：
`afterConnect` 先跑动作（把运营商的 APN 写进去）再刷新，动作占着 `isWorking`，
刷新就被自己挡下了。所以读既不排队也不拒绝，而是记一个 `readPending`，等当前
动作落地后补跑一次（`fulfillPendingRead`）。补跑**只在成功分支触发**，失败的
红字得留给客户看，不能被随后成功的读擦掉。写操作照旧拒绝。

## 两条「等模块自己开口」的路

**USSD（查话费）**。`AT+CUSD=1,…` 那条命令只回一个 `OK`，答案 `+CUSD:` 是
**主动上报**，两件事在时间上分开。所以 `ModemController.process(urc:)` 把它存在
`ussdLock` 后面的 `lastUSSD` 上，谁在等谁自己去看（`latestUSSD` / `waitForUSSD`）。
命令行没有轮询线程，`waitForUSSD` 得自己读那一口；App 里一秒一拍的轮询本来就在
读，不用谁来等。面板里 USSD 单独占一行、不进控制台的回显框 —— 回显框的每一行
都会被下一条命令冲掉，而 USSD 要等几秒才来。错误码的翻译在
`ATFailure.explainUSSD()`：`+CME ERROR: 30` 说的是「这个网络没给语音通道」
（USSD 走电路域，数据通不代表它通），不是命令写错了。

**扫网（`AT+COPS=?`）**。按标准要几十秒，期间**整个 AT 口没人应答**（2026-09-28
真机 QDC507 量到 90 秒不回话、之后还哑约两分钟）。所以它单独一条超时（60 秒），
超时和「扫到空列表」分开报 —— 混成一句「没扫到」，客户只会以为是自己信号差，
然后一遍遍重按。它不进任何自动流程；手动选网（`AT+COPS=1,2,…`）没有这个问题，
才是首选的那条路。

## 模拟器为什么要「钉住」

`SimulatedATTransport` 假装的只是模块本身。可 `DataService` 在 AT 之外还做两件
事：按 VID/PID 扫 IOKit 找模块的网卡、读它的收发字节。真机上这两件事本来就该
做；而模拟器跑在一台没插模块的 Mac 上，扫出来的会是**别的设备** —— 这台开发机
上是读卡器 `Baiwang`，面板于是挂了一条不属于模块的网卡。

所以模拟路径用 `overrideHostState` 把网卡和音频设备说成既定事实，并且**钉住**：
一个 `pinnedHostState` 开关，`refreshStatus()` 一进门就为它提前返回。区别在
「钉住」和「设一次」：刷新每跑一次都重新扫 IOKit，扫不到就把结论写回空，只设一次
的话两次轮询之后就被抹掉了 —— 面板会在画出来之后的下一次刷新里自相矛盾。改动这
一段时先跑 `--sim-check` 里那条「刷新之后仍然钉住」。

## 为什么 HostNetwork 单独一层

整条链路里只有这一件事模块答不上来 —— 网络服务的开关是**这台 Mac 的事实**，
不是模块的状态。它也是唯一 fork 子进程的地方，因此要特别小心：

- `networksetup` 在 `/usr/sbin`，不在 Finder 启动的 App 的 PATH 里，按绝对路径调；
- 解析 `-listnetworkserviceorder` 时只认 `Device:` 这个英文标记，服务名本身
  在中文系统上是本地化的，不能匹配字面量；
- 名字解析一次就缓存，只有开关状态按 5 秒节流重读（`DataService.serviceCache`），
  否则每 2 秒的界面轮询都要遍历一遍全部网络服务；
- 每次调用都有 6 秒超时。拿不到授权服务时它不是报错而是卡住，菜单栏程序卡在
  轮询上就是假死。

## 离屏渲染

`DJI4GMenuBar --render <目录>` 把每个界面画成 PNG 后退出。用
`NSHostingView` + `cacheDisplay` 画到位图上，而不是 `ImageRenderer` ——
后者遇到 `TextEditor` / `ScrollView` 会画成黄色的「不支持」条。渲染完全靠
模拟器供数据，不碰 IOKit 也不碰网络，所以没插模块的机器上也能看界面。

注意：这一步需要 WindowServer，**必须在普通终端里跑**，在沙箱化的环境里
`[NSApplication init]` 会直接 abort。

`--render` 有三种供数方式，验证的东西各不相同：默认模拟器（配图和回归）；
`--nomodule` 走真连接路径、假定 USB 口空着，用来审「没插模块」的文案；
`--hardware` 也走真路径，但等到卡、注册、信号真的报上来才截图，并写出
`hardware-summary.txt` —— 远程排障就靠它。后两种要真的开 USB 设备（
`cusbat_candidates` 走 `USBDeviceOpen` + 控制传输），沙箱会把这一步挡掉，
挡掉时面板如实报「读不到 USB 接口描述」，不会假装连上了。
