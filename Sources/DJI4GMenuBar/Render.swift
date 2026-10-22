import Foundation
import SwiftUI
import AppKit
import DJI4GCore

/// Offscreen renderer for the panel.
///
/// `DJI4GMenuBar --render <dir>` draws every screen the app owns into PNGs and
/// exits. It exists so the layout can be reviewed on a machine with no module
/// attached, and so a regression shows up as a file diff instead of as a
/// surprise in somebody's menu bar. Nothing here opens a window or touches the
/// screen: `ImageRenderer` draws to a bitmap, and the simulator supplies every
/// number, so no IOKit call and no network traffic is involved.
@MainActor
enum RenderHarness {
    /// 通话窗的宽度。
    ///
    /// 原来这里写的是 330，而 `CallWindow` 自己是 `.frame(width: 320)` —— 多出
    /// 来的十个点落在窗口两边，出图的时候是两条谁也没注意过的透明边。窗口按
    /// `.windowResizability(.contentSize)` 收在内容尺寸上，出图就该按同一个
    /// 尺寸出，否则图上放得下的号码，客户窗口里会被截掉。
    private static let callWindowWidth: CGFloat = 320

    private static let usage = "用法：DJI4GMenuBar --render <输出目录> [--nosim | --nomodule"
        + " | --hardware | --dataoff | --phoneaudio | --fresh | --storagefull"
        + " | --longsms | --smsopen | --notifyblocked | --micdenied | --micunasked"
        + " | --panelchrome]\n"

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(
            ((message.isEmpty ? "" : message + "\n") + usage).utf8))
        exit(2)
    }

    static func run() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--render"), arguments.count > flag + 1 else {
            fail("")
        }
        // 输出目录写在旗标后面。位置写漏一格就会把旗标当成路径 —— 2026-09-29 真
        // 碰上一回：`--render --panelchrome` 在仓库里建出一个叫 `--panelchrome`
        // 的文件夹，图也画进去了，谁都没发现。出图是给人看的，宁可直接报用法。
        let rawDirectory = arguments[flag + 1]
        guard !rawDirectory.hasPrefix("-") else {
            fail("输出目录不能把旗标写进去（收到的是「\(rawDirectory)」）。")
        }
        let directory = URL(fileURLWithPath: rawDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if arguments.contains("--panelchrome") { checkPanelChrome(to: directory) }
        if arguments.contains("--notifyblocked") { renderNotificationsBlocked(to: directory) }
        if arguments.contains("--micdenied") { renderMicrophoneDenied(to: directory) }
        if arguments.contains("--micunasked") { renderMicrophoneUnasked(to: directory) }
        if arguments.contains("--dataoff") { renderDataOff(to: directory) }
        if arguments.contains("--nomodule") { renderNoModule(to: directory) }
        if arguments.contains("--storagefull") { renderStorageFull(to: directory) }
        if arguments.contains("--longsms") { renderLongSMS(to: directory) }
        if arguments.contains("--smsopen") { renderSMSOpen(to: directory) }
        if arguments.contains("--phoneaudio") { renderPhoneAudio(to: directory) }
        if arguments.contains("--fresh") { renderFresh(to: directory) }
        if arguments.contains("--hardware") { renderHardware(to: directory) }

        // `--nosim` draws the screen a customer sees after plugging the module
        // in but before inserting a card. Nothing that needs the network can be
        // true there, and the panel has to say so in words instead of showing
        // an empty field — rendering the state is how that wording gets read by
        // a human before a customer ever sees it.
        let emptySlot = arguments.contains("--nosim")
        let simulator = SimulatedATTransport(scenario: emptySlot ? .noSIM : .ready)
        // 172.7 GB of a 300.4 GB plan, so the ring reads 43% left — the figure
        // the reference panel shows. The empty-slot render starts from zero
        // bytes and no plan, which is what a new customer actually has.
        if !emptySlot {
            simulator.sentBytes = 700_000_000
            simulator.receivedBytes = 172_000_000_000
        }

        let model = AppModel(simulator: simulator, planGB: emptySlot ? 0 : 300.4)
        do {
            try model.startSimulator()
        } catch {
            FileHandle.standardError.write(Data("模拟器启动失败：\(error)\n".utf8))
            exit(1)
        }
        pump(0.8)
        // Everything from here to the call window describes a module that is
        // already working. With an empty slot none of it can be true: no PDP
        // context without a card, and no interface either, because the factory
        // composition has not been rewritten yet.
        if !emptySlot {
            // 这一套图描述的是「一键启用已经做过」的模块：组态最后一位（模块
            // 声卡）得是 1。模拟器的出厂值是 0 —— 不补这一笔，图上的组态和
            // 真机对不上，而两处只在「关着」时才会出现的提示（通话窗那句红字、
            // 设置页那一行）会误演在演示图里。
            _ = try? model.controller.voice.enableAudioFunction(reboot: false)
            pump(0.3)

            // Bring the PDP context up through the same call the "4G ON" pill
            // makes, so the screenshot shows a panel that is actually online.
            pressDataSwitch(model, true)

            _ = simulator.injectIncomingSMS(text: "您本月剩余流量 127.7GB，回复 CXLL 查询详情。", from: "10086")
            pump(0.3)
            _ = simulator.injectIncomingSMS(text: "验证码 861324，5 分钟内有效，请勿转告他人。", from: "106903001234")
            pump(0.3)
            _ = simulator.injectIncomingSMS(text: "您的 4G 模块已完成绑定。", from: "1065500000000")
            pump(0.6)

            model.seedTraffic(traffic: trafficShape, today: 3_240_000_000)
        }
        model.refreshAll()
        // Every action runs its body on a background queue, so refreshAll has
        // not finished when it returns. Wait for it before seeding, or its
        // refresh lands afterwards and overwrites what was seeded.
        pumpUntilIdle(model)
        if !emptySlot {
            // The interface and its macOS network service are the one part of
            // the link the in-memory module cannot fake — they are facts about
            // this Mac, so the harness states them directly.
            model.seedHostLink(interface: "en17", ipv4: "10.42.7.19",
                               service: "Baiwang", enabled: true)
            pump(0.3)
            // Same reasoning for the call audio: the module's UAC function is a
            // fact about the USB tree, and this machine has no module plugged
            // in.
            model.seedModuleAudio(name: "USB Audio Device")
            pump(0.3)
            // 通话语音那一格同样是「这台机器上插着什么」的结论，而它还会被
            // 通话窗 `.onAppear` 里那次真机探测改写 —— 出图机上插着模块时，
            // 导出的通话窗会写着「未安装」或「通话中」。这一套图说的是同一个
            // 已经装好的模块，所以把它钉住。
            model.seedVoiceSetup()
            pump(0.3)
            // The totals under the ring are the module's own, and they get
            // stated here rather than read: this Mac may well have a module
            // attached, whose live traffic would otherwise replace the seeded
            // 172.7 GB and turn the ring into "100% left".
            model.seedModuleCounters()
            pump(0.3)
        } else {
            // 空卡座那一版：网卡还没建出来，流量也还没走过，两样都得钉住 ——
            // 截图机上插着的模块会把这些数字从真机带进来。
            model.seedHostLink(interface: "", ipv4: "", service: "", enabled: false)
            model.seedModuleCounters()
            pump(0.3)
        }

        // 通话记录也是这样：真机路径上它跟着通话自己攒，出图机上除了攒不出来，
        // 还会把出图这台机器上那份真客户的 `calllog.json` 读进来。默认这一屏
        // 说的是新客户的样子（一条没有），带记录的版本在下面另画一张。
        model.seedCallHistory([])
        pump(0.2)

        render(PanelView(initialTab: .network).environmentObject(model),
               "panel-network", width: Theme.panelWidth, to: directory)
        render(PanelView(initialTab: .module).environmentObject(model),
               "panel-module", width: Theme.panelWidth, to: directory)
        render(PanelView(initialTab: .sms).environmentObject(model),
               "panel-sms", width: Theme.panelWidth, to: directory)
        // 折起来那条小条。摊开的样子天天见，折起来的只有这份图上有 ——
        // 一条三十来个点高的面板长什么样，画出来才有人过目。
        render(PanelView(initialTab: .network, compact: true).environmentObject(model),
               "panel-folded", width: Theme.panelWidth, to: directory)
        render(CallWindow().environmentObject(model), "window-call", width: callWindowWidth, to: directory)
        render(SetupWindow().environmentObject(model), "window-setup", width: 380, to: directory)

        // 通话记录那一列的排版。
        //
        // 空着的样子上面 `window-call` 已经有一张（下面把它钉成空的了），
        // 这里要的是有记录时那一排栏 —— 结果那三个字、时长、相对时间挤在
        // 292pt 里会不会互相压，只有画出来才看得见。四条样板把四种结果各
        // 摆上一遍。
        let now = Date()
        model.seedCallHistory([
            // 按时间排：这一份和真机上攒出来的是一个方向（旧在前），列表显示
            // 的时候把它倒过来（新的在最上面）。
            CallRecord(number: "+8618800138001", outgoing: true, outcome: .failed,
                       at: now.addingTimeInterval(-3600 * 24 * 9), seconds: 0),
            CallRecord(number: "+8613900139000", outgoing: false, outcome: .missed,
                       at: now.addingTimeInterval(-3600 * 30), seconds: 0),
            CallRecord(number: "10086", outgoing: true, outcome: .answered,
                       at: now.addingTimeInterval(-3600 * 26), seconds: 32),
            CallRecord(number: "+8613800138000", outgoing: true, outcome: .answered,
                       at: now.addingTimeInterval(-3600 * 5), seconds: 3725),
        ])
        pump(0.2)
        render(CallWindow().environmentObject(model), "window-call-history", width: callWindowWidth, to: directory)

        // 两块默认收起的东西，各自的展开态。
        //
        // 平时截的是客户第一眼看到的样子（收起），可收起的代价是「里面长什么
        // 样」没人再看得到 —— 2026-09-25 那版 AT 回显就是在这个盲区里糊掉的。
        // 带上 DJI4G_RENDER_EXPANDED=1 再跑一次，抽屉摊开的配色才有人过目。
        if ProcessInfo.processInfo.environment["DJI4G_RENDER_EXPANDED"] != nil {
            render(PanelView(initialTab: .network, consoleVisible: true,
                             consoleOutput: "AT+QCFG=\"usbcfg\"\r\n"
                                 + "+QCFG: \"usbcfg\",1,1,1,1,1,0,0\r\n"
                                 + "AT+CSQ\r\n+CSQ: 24,99\r\nOK\r\n")
                   .environmentObject(model),
                   "panel-console", width: Theme.panelWidth, to: directory)
            // 快捷指令抽屉 + USSD 那一行。两条都得有人看过：抽屉收着的时候
            // 长指令会不会被裁、USSD 长答案会不会把面板顶穿，只有这张图能答。
            render(PanelView(initialTab: .network, consoleVisible: true,
                             consoleOutput: "AT+QCFG=\"usbcfg\"\r\n"
                                 + "+QCFG: \"usbcfg\",1,1,1,1,1,0,0\r\n"
                                 + "AT+CSQ\r\n+CSQ: 24,99\r\nOK\r\n",
                             consolePresets: true,
                             consoleUSSD: "您的余额为12.30元")
                   .environmentObject(model),
                   "panel-console-presets", width: Theme.panelWidth, to: directory)
            render(SetupWindow(logExpanded: true).environmentObject(model),
                   "window-setup-log", width: 380, to: directory)
            // 远程调试那一行的摊开态。它是一段临时通道，但「临时」不等于
            // 「没人看过」—— 里面有两条地址和一排按钮，样子得有一张图。
            render(SetupWindow(debugExpanded: true).environmentObject(model),
                   "window-setup-debug", width: 380, to: directory)
        }

        // The one call state that cannot be reached from a cold model: a second
        // caller parked behind a conversation that is already up. It also
        // cannot be reached without a card, which is why it is skipped there.
        if !emptySlot {
            model.dial("+8613800138000")
            pump(2.8)
            // 通话中这一刻，这一排只剩一颗「挂断」，药丸会撑满整行 —— 好不好
            // 看得画出来，所以单独留一张。
            render(CallWindow().environmentObject(model), "window-call-active",
                   width: callWindowWidth, to: directory)
            simulator.simulateIncomingCall(from: "+8613900139000")
            pump(0.8)
            render(CallWindow().environmentObject(model), "window-call-waiting", width: callWindowWidth, to: directory)

            // 来电横幅：客户问「电话来了先看哪儿」的答案就是面板顶上这条。
            // 它也要有一张图，出问题时才有东西可对照。
            model.simulateRemoteHangup()
            pump(1.0)

            // 按键音键盘：只在真正接通后才画得出来（空闲时它不出现在窗口里）。
            // 来电 → 接听 → 这一张。键盘是三列四行，摆成这样还是那样，只有
            // 图能回答。
            model.simulateIncomingCall()
            pump(0.8)
            model.answer()
            pump(1.2)
            render(CallWindow().environmentObject(model), "window-call-keypad",
                   width: callWindowWidth, to: directory)
            model.hangup()
            pump(1.0)

            model.simulateIncomingCall()
            pump(0.8)
            render(PanelView(initialTab: .network).environmentObject(model),
                   "panel-ringing", width: Theme.panelWidth, to: directory)
            // 浮层卡片本来的样子。它是一块盖在全屏之上的窗口，截图里只有它
            // 自己，所以这张图是给交付说明用的：「来电时屏幕上会出现这个」。
            render(RingCard(number: "+8618957549662", title: "来电响铃", answer: {}, reject: {}),
                   "ring-card", width: 304, to: directory)
        }

        exit(0)
    }

    /// The first screen a customer sees: app installed, module not plugged in.
    ///
    /// Nothing here is simulated. This runs the real attach path — the same
    /// IOKit scan the shipping app runs every three seconds — so whatever the
    /// panel says is what a customer with an empty USB port reads. It exists
    /// because that state used to carry the seed of every other state's copy:
    /// a fresh model reports 「卡的状态未知」, whose advice is to check the card
    /// slot's ribbon cable, and the panel printed it at somebody who had not
    /// plugged anything in yet.
    private static func renderNoModule(to directory: URL) -> Never {
        // 先把这个口子堵上再造模型：`AppModel.init` 里第一件事就是扫总线，
        // 晚一行写它就晚了。不堵的话，模块插着的机器上画出来的是一个连着的
        // 模块 —— 这一版要审的「还没插模块」那句话反而一个字都看不到。
        AppModel.scanOverride = { [] }
        let model = AppModel()
        pump(1.5)
        render(PanelView(initialTab: .network).environmentObject(model),
               "nomodule-panel-network", width: Theme.panelWidth, to: directory)
        render(PanelView(initialTab: .module).environmentObject(model),
               "nomodule-panel-module", width: Theme.panelWidth, to: directory)
        render(PanelView(initialTab: .sms).environmentObject(model),
               "nomodule-panel-sms", width: Theme.panelWidth, to: directory)
        render(CallWindow().environmentObject(model), "nomodule-window-call", width: callWindowWidth, to: directory)
        render(SetupWindow().environmentObject(model), "nomodule-window-setup", width: 380, to: directory)
        print("未插模块的 5 张图已写到 \(directory.path)")
        exit(0)
    }

    /// 系统没允许通知那一版。画的是「通知关着，但 App 浮层照弹」那条文案
    /// （2026-09-26 改过，见 `NotificationWarning`）。
    ///
    /// 真机上这个状态由 `UNUserNotificationCenter` 的回调决定，而无头进程
    /// 没有 bundle，那条回调永远不来 —— 也就是说这行提示在截图里默认永远不
    /// 出现，它的排版谁都没看过。它偏偏是「电话来了为什么没弹」唯一摆在客户
    /// 面前的解释，值得有一张能逐像素比对的图。
    private static func renderNotificationsBlocked(to directory: URL) -> Never {
        let simulator = SimulatedATTransport(scenario: .ready)
        simulator.sentBytes = 700_000_000
        simulator.receivedBytes = 172_000_000_000
        let model = AppModel(simulator: simulator, planGB: 300.4)
        do {
            try model.startSimulator()
        } catch {
            FileHandle.standardError.write(Data("模拟器启动失败：\(error)\n".utf8))
            exit(1)
        }
        pump(0.8)
        pressDataSwitch(model, true)
        model.seedNotificationsBlocked()
        model.refreshAll()
        pumpUntilIdle(model)
        // 和主图同一组数字：这两张图将来是并排看的，唯一该有的差别是那条提示。
        model.seedTraffic(traffic: trafficShape, today: 3_240_000_000)
        model.seedHostLink(interface: "en17", ipv4: "10.42.7.19",
                           service: "Baiwang", enabled: true)
        model.seedModuleAudio(name: "USB Audio Device")
        model.seedModuleCounters()
        pump(0.3)
        render(PanelView(initialTab: .network).environmentObject(model),
               "notifyblocked-panel-network", width: Theme.panelWidth, to: directory)
        render(PanelView(initialTab: .sms).environmentObject(model),
               "notifyblocked-panel-sms", width: Theme.panelWidth, to: directory)
        render(CallWindow().environmentObject(model), "notifyblocked-window-call", width: callWindowWidth, to: directory)
        print("通知没允许的 3 张图已写到 \(directory.path)")
        exit(0)
    }

    /// 「麦克风没打开」那一版。
    ///
    /// 2026-09-30 之前面板上不出麦克风的状态（面板当时只管模块和网络），
    /// 于是唯一提到它的地方是那扇要先自己点开的通话窗 —— 客户多半一辈子
    /// 不会点开，看到的只有「接起来没声音」。现在面板顶上多一条，两处都画，
    /// 免得下次改到这一块又是客户先看见。
    private static func renderMicrophoneDenied(to directory: URL) -> Never {
        let simulator = SimulatedATTransport(scenario: .ready)
        let model = AppModel(simulator: simulator, planGB: 300.4)
        do {
            try model.startSimulator()
        } catch {
            FileHandle.standardError.write(Data("模拟器启动失败：\(error)\n".utf8))
            exit(1)
        }
        pump(0.8)
        // 这一档要说明的是「只有麦克风那一件事没做，别的都是好的」：组态最后
        // 一位补上、数据开关按下去、语音通路钉成已就绪。少这三笔，图上会多出
        // 三句和麦克风无关的红字，看图的人分不清哪一句才是这版要说的。
        _ = try? model.controller.voice.enableAudioFunction(reboot: false)
        pump(0.3)
        pressDataSwitch(model, true)
        model.seedVoiceSetup()
        model.seedMicrophoneDenied()
        model.refreshAll()
        pumpUntilIdle(model)
        model.seedTraffic(traffic: trafficShape, today: 3_240_000_000)
        model.seedHostLink(interface: "en17", ipv4: "10.42.7.19",
                           service: "Baiwang", enabled: true)
        model.seedModuleAudio(name: "USB Audio Device")
        model.seedModuleCounters()
        pump(0.3)
        render(PanelView(initialTab: .network).environmentObject(model),
               "micdenied-panel-network", width: Theme.panelWidth, to: directory)
        render(CallWindow().environmentObject(model), "micdenied-window-call",
               width: callWindowWidth, to: directory)
        print("麦克风没打开的 2 张图已写到 \(directory.path)")
        exit(0)
    }

    /// 「麦克风还一次没问过」那一版 —— 装完第一次打开就是这一档。
    ///
    /// 和被拒过的那一档只差文案和按钮：没问过的点一下就能弹系统框，被拒过的
    /// 只能去系统设置。两张图分开，是为了让两句文案都被真读过一遍。
    private static func renderMicrophoneUnasked(to directory: URL) -> Never {
        let simulator = SimulatedATTransport(scenario: .ready)
        let model = AppModel(simulator: simulator, planGB: 300.4)
        do {
            try model.startSimulator()
        } catch {
            FileHandle.standardError.write(Data("模拟器启动失败：\(error)\n".utf8))
            exit(1)
        }
        pump(0.8)
        _ = try? model.controller.voice.enableAudioFunction(reboot: false)
        pump(0.3)
        pressDataSwitch(model, true)
        model.seedVoiceSetup()
        model.seedMicrophoneUnasked()
        model.refreshAll()
        pumpUntilIdle(model)
        model.seedTraffic(traffic: trafficShape, today: 3_240_000_000)
        model.seedHostLink(interface: "en17", ipv4: "10.42.7.19",
                           service: "Baiwang", enabled: true)
        model.seedModuleAudio(name: "USB Audio Device")
        model.seedModuleCounters()
        pump(0.3)
        render(PanelView(initialTab: .network).environmentObject(model),
               "micunasked-panel-network", width: Theme.panelWidth, to: directory)
        render(CallWindow().environmentObject(model), "micunasked-window-call",
               width: callWindowWidth, to: directory)
        print("麦克风还没问过的 2 张图已写到 \(directory.path)")
        exit(0)
    }

    /// 数据开关「关」的那一版。
    ///
    /// 面板中间那颗胶囊原来写死 `4G ON`，关掉数据也不变，客户读到的是一块
    /// 标签而不是开关（2026-09-26 的反馈）。改成会变的以后，「关」长什么样
    /// 只有真按一下才画得出来，所以这一档把开关按下去：网卡和 IP 都还在
    /// —— 这是实情，macOS 不会因为停用一个网络服务就把 ECM 网卡拆掉，也
    /// 正是旧代码看 `isConnected` 会一直显示 `ON` 的原因 —— 服务已经停用，
    /// 胶囊该写 `4G OFF`，底下的「未启用」跟着一起看。
    private static func renderDataOff(to directory: URL) -> Never {
        let simulator = SimulatedATTransport(scenario: .ready)
        simulator.sentBytes = 700_000_000
        simulator.receivedBytes = 172_000_000_000
        let model = AppModel(simulator: simulator, planGB: 300.4)
        do {
            try model.startSimulator()
        } catch {
            FileHandle.standardError.write(Data("模拟器启动失败：\(error)\n".utf8))
            exit(1)
        }
        pump(0.8)
        pressDataSwitch(model, true)
        model.refreshAll()
        pumpUntilIdle(model)
        model.seedTraffic(traffic: trafficShape, today: 3_240_000_000)
        model.seedHostLink(interface: "en17", ipv4: "10.42.7.19",
                           service: "Baiwang", enabled: true)
        model.seedModuleAudio(name: "USB Audio Device")
        model.seedModuleCounters()
        pump(0.3)
        // 走的就是按钮那条路：停用 macOS 网络服务（默认路由还给 Wi-Fi）→
        // 拆 PDP。不是摆拍，所以这里按下去以后面板必须自己说得通。
        pressDataSwitch(model, false)
        // 网卡和 IP 是「这台 Mac」的事实（见上面 `seedHostLink` 的说明），所以
        // 关掉数据之后必须重新说一遍 —— 说成没有。不补这一句，这张图就会自相
        // 矛盾：开关写着 4G OFF，下面还印着 `接口 en17 / IPV4 10.42.7.19`。
        // 真机上关掉数据是 `无 IPv4`（2026-09-26 实测），图上也得是。
        model.seedHostLink(interface: "", ipv4: "", service: "", enabled: false)
        pump(0.3)
        render(PanelView(initialTab: .network).environmentObject(model),
               "dataoff-panel-network", width: Theme.panelWidth, to: directory)
        // 再按一次开，但让 macOS 那半边停在「服务还没启用」—— 切完 ECM、
        // 网卡刚起来而服务还没建好的那几秒就是这个样子。灯这时候既不能实心
        // （链路还没通）也不能是灰的（开关明明开着），第三种样子也得有图可比。
        pressDataSwitch(model, true)
        model.seedHostLink(interface: "en17", ipv4: "10.42.7.19",
                           service: "Baiwang", enabled: false)
        pump(0.3)
        render(PanelView(initialTab: .network).environmentObject(model),
               "datapending-panel-network", width: Theme.panelWidth, to: directory)
        print("数据开关的 2 张图（关 / 开而没通）已写到 \(directory.path)")
        exit(0)
    }

    /// 手机那一档：为了插 iPhone / iPad，模块声卡被关掉之后的样子。
    ///
    /// 模块一旦枚举成 USB 声卡，**任何**宿主都会把音频输出切到它身上。Mac 上
    /// 这正是通话语音的载体，要的就是这个；可模块没有喇叭，iPhone / iPad 上
    /// 切过去的结果是整台设备像哑了一样 —— 刷抖音、听歌全都没声音。手机端本来
    /// 也用不到那块声卡（iOS 不把 AT 那句给我们），所以插手机就该把 usbcfg
    /// 最后一位关掉。
    ///
    /// 关掉之后回到 Mac，通话语音那一格仍然写着「已就绪」（它说的是模块里的
    /// 通路：驱动、出厂校准、PCM 桥），打出去却是一通两边都没有声音的电话。
    /// 新加的两处提示只在「关着」时出现，平时不占客户的地方 —— 也就没有别的图
    /// 能看到它们的排版。这一档专门把它们画出来。
    private static func renderPhoneAudio(to directory: URL) -> Never {
        let simulator = SimulatedATTransport(scenario: .ready)
        simulator.sentBytes = 700_000_000
        simulator.receivedBytes = 172_000_000_000
        let model = AppModel(simulator: simulator, planGB: 300.4)
        do {
            try model.startSimulator()
        } catch {
            FileHandle.standardError.write(Data("模拟器启动失败：\(error)\n".utf8))
            exit(1)
        }
        pump(0.8)
        pressDataSwitch(model, true)
        model.refreshAll()
        pumpUntilIdle(model)
        // 走的就是「换成移动版」那颗按钮同一条路（`applyHostMode` 的后半截）。
        // 这里不重启：快照要的是那份组态，不是等一次重启。
        _ = try? model.controller.voice.disableAudioFunction(reboot: false)
        _ = model.controller.refreshData()
        waitUntil(model) { $0.data.composition?.audio == false }
        pumpUntilIdle(model)
        // 和主图同一组数字。这两张图将来是并排看的，唯一该有的差别是那两处提示。
        model.seedTraffic(traffic: trafficShape, today: 3_240_000_000)
        model.seedHostLink(interface: "en17", ipv4: "10.42.7.19",
                           service: "Baiwang", enabled: true)
        model.seedModuleCounters()
        pump(0.3)
        // 声卡这一档钉的是「一个模块音频设备都没有」：位关掉之后 macOS 真的
        // 一个都认不到（2026-09-27 实测），那一行就该读作「未检测到模块音频
        // 设备」。不钉的话，这台做图的机器上正插着一台声卡开着的模块，那一行
        // 会凭空冒出 `已识别 AC Interface`，和图上「声卡是关着的」打架。
        model.seedNoModuleAudio()
        pump(0.3)
        // 这一档的通话窗要读作「通话语音 已就绪 ＋ 声卡关着」—— 两句话说的
        // 是两件事，正是这一档要审的地方。语音那一格不钉住的话，它读的是这
        // 台机器上插着的那块模块（还没装过就写「未安装」），这张图就从「两
        // 件事各说各的」变成「两件事都坏了」。
        model.seedVoiceSetup()
        pump(0.3)
        // 面板也要一张。安装图解第 2 步教客户「红框那行现在写着『未开启』」，
        // 而默认那套面板图是在声卡开着的模块上出的 —— 图里那一格会写「已开启」，
        // 和正文对着干。客户手里的模块拿到手就是关着的这一档，图就该是这一档。
        render(PanelView(initialTab: .module).environmentObject(model),
               "phoneaudio-panel-module", width: Theme.panelWidth, to: directory)
        render(CallWindow().environmentObject(model), "phoneaudio-window-call",
               width: callWindowWidth, to: directory)
        render(SetupWindow().environmentObject(model), "phoneaudio-window-setup",
               width: 380, to: directory)
        print("手机档（声卡关着）的 3 张图已写到 \(directory.path)")
        exit(0)
    }

    /// 出厂那一档：客户把一块**从没用过**的模块插上 Mac，第一眼看到的样子。
    ///
    /// 实物出厂时网卡停在 Windows 那一档，模块声卡也是关着的 —— 设置窗里
    /// 那颗「启用并重启模块」还等着被按。这正是「装好之后图解」第 2、3 步
    /// 教客户去做的那件事，可那一页的图一直是从 `--live` 那套**已经开好**的
    /// 模块上取的：设置窗写着「已开好」、按钮压根不出现，而正文正让客户去
    /// 找那颗按钮。两张嘴各说各的，看图的人只会以为自己装错了。
    ///
    /// `--phoneaudio` 补得了面板那一格（声卡关着那一行），补不了设置窗 ——
    /// 它那一档的网卡是通着的，`hostModeNow` 读到「移动版」，按钮换成「切回
    /// Mac 版」，还是不对。只有连网卡一起摆回出厂，设置窗才是客户真会看到
    /// 的那一张。
    private static func renderFresh(to directory: URL) -> Never {
        let simulator = SimulatedATTransport(scenario: .ready)
        simulator.sentBytes = 700_000_000
        simulator.receivedBytes = 172_000_000_000
        let model = AppModel(simulator: simulator, planGB: 300.4)
        do {
            try model.startSimulator()
        } catch {
            FileHandle.standardError.write(Data("模拟器启动失败：\(error)\n".utf8))
            exit(1)
        }
        pump(0.8)
        model.refreshAll()
        pumpUntilIdle(model)

        // 走真代码路径摆回出厂（「使用模式」那两颗按钮底下是同一条）：网卡写
        // 0 = Windows 那一档，声卡那一位写 0。都不重启 —— 要的是那份组态，
        // 不是等一次重启。数据开关不碰：出厂这一档它本来就还没开。
        _ = try? model.controller.data.setUSBnetMode(.rndis, reboot: false)
        _ = try? model.controller.voice.disableAudioFunction(reboot: false)
        _ = model.controller.refreshData()
        waitUntil(model) { $0.data.usbnetMode == .rndis }
        pumpUntilIdle(model)

        // 摆完必须核：这一档存在的全部理由就是「两样都还没开」。摆不上就别
        // 出图 —— 一张谎报出厂的图比没有图更坏。
        guard model.hostModeNow == nil else {
            FileHandle.standardError.write(Data(
                ("渲染夹具：模块没摆回出厂那一档（读到的还是 "
                 + (model.hostModeNow?.label ?? "?") + "）\n").utf8))
            exit(1)
        }
        guard model.data.composition?.audio == false else {
            FileHandle.standardError.write(Data("渲染夹具：模块声卡没摆回关着\n".utf8))
            exit(1)
        }
        // 通话语音那一格是 `.onAppear` 里异步探的，离屏渲染不跑它 —— 不补这
        // 一步，导出的图会停在初始态，等于自己给自己报一个假故障（同一处
        // 坑 `renderHardware` 里记过）。这一档说的是没装过的模块，出图机上
        // 插着什么都会被这一句盖掉。
        model.seedVoiceSetup()
        // 这一档的这台机器上什么都没有：网卡没建出来，也没有模块音频设备。
        model.seedHostLink(interface: "", ipv4: "", service: "", enabled: false)
        model.seedNoModuleAudio()
        model.seedModuleCounters()
        model.seedCallHistory([])
        pump(0.3)

        render(PanelView(initialTab: .module).environmentObject(model),
               "fresh-panel-module", width: Theme.panelWidth, to: directory)
        render(PanelView(initialTab: .network).environmentObject(model),
               "fresh-panel-network", width: Theme.panelWidth, to: directory)
        render(SetupWindow().environmentObject(model), "fresh-window-setup",
               width: 380, to: directory)
        print("出厂档（两样都没开）的 3 张图已写到 \(directory.path)")
        exit(0)
    }

    /// 存储占满那一版。
    ///
    /// 模块自己的 23 个格子满了之后，网络投递过来的短信会被**直接丢掉**：
    /// 发的人那边一切正常，这边一条都收不到，屏幕上也没有任何提示 —— 客户
    /// 只会觉得「最近没人给我发短信」。所以收件箱底下那行「存储 23/23 已满」
    /// 是这个哑巴故障唯一的可见处，它得有张能逐像素比对的图；红字哪天改糊
    /// 了，会变成文件差异而不是变成客户的一句「收不到」。
    ///
    /// 再塞 22 条（模拟器自己已经放了一条），正好 23 个格子占满 —— 顺带把
    /// 列表封顶（10 行 380pt）之后的样子也画出来：封顶那一行以前会被切成半行
    /// 字，只有塞满才看得见。
    private static func renderStorageFull(to directory: URL) -> Never {
        let simulator = SimulatedATTransport(scenario: .storageFull)
        let model = AppModel(simulator: simulator, planGB: 300.4)
        do {
            try model.startSimulator()
        } catch {
            FileHandle.standardError.write(Data("模拟器启动失败：\(error)\n".utf8))
            exit(1)
        }
        pump(0.8)
        pressDataSwitch(model, true)
        // 22 条，不是 23：模拟器自己先塞了一条「模块就绪」，加起来正好把 23 个
        // 格子占满。塞 23 条的话收件箱是 24 条、存储却是 23/23 —— 这张图是拿来
        // 逐像素对比的，自相矛盾的数字会让人怀疑图本身坏了。
        for index in 0..<22 {
            _ = simulator.injectIncomingSMS(
                text: "第 \(index + 1) 条占位短信，用来把 23 个格子占满。",
                from: Self.placeholderSender(index))
        }
        pump(0.6)
        model.refreshAll()
        pumpUntilIdle(model)
        render(PanelView(initialTab: .sms).environmentObject(model),
               "storagefull-panel-sms", width: Theme.panelWidth, to: directory)
        print("存储满的 1 张图已写到 \(directory.path)")
        exit(0)
    }

    /// 长短信合并那一档：一条 2 段的长短信躺进收件箱，所以「条数」比「格数」少 1。
    ///
    /// 2026-09-26 真机上撞到的就是这样一条：slot 3 和 slot 4 是同一组中国电信
    /// 通知（UDH ref 0x10，2 段），列表里合成一条显示 —— 小屏写着「2 条」，
    /// 底下写着「存储 3/23」，客户盯着这两个数就会觉得少了一条短信（真机上是
    /// 6 条 vs 7/40）。这一档把那句话画出来，改文案时能直接看见效果。
    private static func renderLongSMS(to directory: URL) -> Never {
        let simulator = SimulatedATTransport(scenario: .ready)
        let model = AppModel(simulator: simulator, planGB: 300.4)
        do {
            try model.startSimulator()
        } catch {
            FileHandle.standardError.write(Data("模拟器启动失败：\(error)\n".utf8))
            exit(1)
        }
        pump(0.8)
        pressDataSwitch(model, true)
        // 文案照着真机那条抄：长短信是运营商发来的，分段位置就在「请点击」和
        // 链接之间 —— 合并处要是差了半个字符，这条长得跟真的一样的短信就会露馅。
        simulator.injectMultipartSMS(
            parts: ["尊敬的用户：截至2026年09月24日 20时51分，您已使用套餐外短信业务，"
                    + "超出短信每条按0.1元收费。查询短信使用明细，请点击",
                    "：https://a.189.cn/6FmrFN 进入中国电信APP【中国电信】"],
            from: "10001")
        pump(0.6)
        model.refreshAll()
        pumpUntilIdle(model)
        render(PanelView(initialTab: .sms).environmentObject(model),
               "longsms-panel-sms", width: Theme.panelWidth, to: directory)
        print("长短信合并的 1 张图已写到 \(directory.path)")
        exit(0)
    }

    /// 点开一条短信之后的样子。
    ///
    /// 这一屏平时只有客户自己点得出来，出图机上没人点 —— 「白卡黑字 + 回复
    /// 按钮」这套改动要是没有图，改糊了也只能等客户来报。夹具把最长的那条
    /// （运营商那种两段合一的百字通知）摊开：正文字号、换行、长短信收进的
    /// 滚动区、右下角那枚「回复」，都在这一张上。
    private static func renderSMSOpen(to directory: URL) -> Never {
        let simulator = SimulatedATTransport(scenario: .ready)
        let model = AppModel(simulator: simulator, planGB: 300.4)
        do {
            try model.startSimulator()
        } catch {
            FileHandle.standardError.write(Data("模拟器启动失败：\(error)\n".utf8))
            exit(1)
        }
        pump(0.8)
        pressDataSwitch(model, true)
        // 一条短的 + 一条长的：短的用来核对「不滚动的卡片」长什么样，长的
        // 用来核对滚动区。挑长的那条摊开。
        _ = simulator.injectIncomingSMS(text: "验证码 861324，5 分钟内有效，请勿转告他人。",
                                        from: "106903001234")
        pump(0.3)
        simulator.injectMultipartSMS(
            parts: ["尊敬的用户：截至2026年09月24日 20时51分，您已使用套餐外短信业务，"
                    + "超出短信每条按0.1元收费。查询短信使用明细，请点击",
                    "：https://a.189.cn/6FmrFN 进入中国电信APP【中国电信】"],
            from: "10001")
        pump(0.6)
        model.refreshAll()
        pumpUntilIdle(model)
        let opened = model.messages.first { $0.sender == "10001" } ?? model.messages.first
        render(PanelView(initialTab: .sms, initialSMS: opened).environmentObject(model),
               "smsopen-panel-sms", width: Theme.panelWidth, to: directory)
        print("点开短信的 1 张图已写到 \(directory.path)")
        exit(0)
    }

    /// 每 7 条混一个 20 位的服务号。
    ///
    /// 20 位是 PDU 地址字段的上限（`BCD.encodeAddress` 那里卡着），现实里也
    /// 确实收得到这种长号。收件箱那一行只有 15pt 高，发件人不封顶的话这个号
    /// 会把时间列挤出面板、或者把自己撑成两行被裁成半行字 —— 只有真塞进来
    /// 才看得见，所以它跟着存储满那一档一起画。
    private static func placeholderSender(_ index: Int) -> String {
        index % 7 == 3 ? "10690300123456789012" : "1069000000\(String(format: "%02d", index))"
    }

    /// 真机截图：真模块、真 AT 通道、真卡状态，一个数字都不模拟。
    ///
    /// 和 `--nomodule` 是同一条路径，差别在等待条件。USB 口空着的时候等多久
    /// 都是空面板；插着模块就得等它把卡、注册、信号一个个报上来，否则截到的
    /// 是刚连上那一帧。用途有两个：给人看真机现在长什么样，以及远程让客户跑
    /// 一条命令，把图和状态摘要发回来 —— 比隔着电话问「你那显示什么」准。
    private static func renderHardware(to directory: URL) -> Never {
        let model = AppModel()
        waitUntil(model, timeout: 12) { $0.isConnected || $0.lastError != nil }
        pumpUntilIdle(model)
        // 上面那句等的就是「模块连上」。机器上根本没插模块时它必然超时 ——
        // 图还是照画（画的是空档那一段），但报告里那句「等待超时」得有人
        // 解释，不然远程看图的这头会把它读成故障。
        if !model.isConnected, model.attachedIdentity == nil {
            print("  · 这台机器上没有模块：等的是模块连上，图照画空档那一段")
        }
        if model.isConnected {
            // 一秒一轮的轮询至少跑完一轮，卡才有值。这里等的是「模块报过话了」，
            // 不是「卡插好了」：卡座空的时候 `sim` 也会落到「未检测到」。
            waitUntil(model, timeout: 10) { $0.sim.state != .unknown }
            pumpUntilIdle(model)
            // 信号和流量跟在卡后面几个命令里，多给一轮。
            pump(1.4)

            // 通话语音那一格平时是 `.onAppear` 里异步探的，而离屏渲染压根不跑
            // `onAppear` —— 不补这一步，导出的截图永远停在 `adbBinary == nil`
            // 的初始态，也就是「缺少组件」。装好的机器也这么显示：这些图是要
            // 拿去给客户看的，等于自己给自己报了一个假故障（2026-09-27 发现）。
            model.refreshVoiceSetup()
            waitUntil(model, timeout: 20) { $0.voiceSetup.adbBinary != nil }
            pumpUntilIdle(model)
        }

        let summary = hardwareSummary(model)
        print(summary)
        // 也落一份到盘上：这个模式多半是被双击或者 `open` 起来的，那时候
        // 标准输出没人接，图和文字一起留在目录里才拿得回来。
        try? summary.write(to: directory.appendingPathComponent("hardware-summary.txt"),
                           atomically: true, encoding: .utf8)
        render(PanelView(initialTab: .network).environmentObject(model),
               "hardware-panel-network", width: Theme.panelWidth, to: directory)
        render(PanelView(initialTab: .module).environmentObject(model),
               "hardware-panel-module", width: Theme.panelWidth, to: directory)
        render(PanelView(initialTab: .sms).environmentObject(model),
               "hardware-panel-sms", width: Theme.panelWidth, to: directory)
        render(CallWindow().environmentObject(model), "hardware-window-call", width: callWindowWidth, to: directory)
        render(SetupWindow().environmentObject(model), "hardware-window-setup", width: 380, to: directory)
        // 来电横幅。封面用的就是这一屏，而它只有响铃时才画得出来 —— 真机档
        // 没有模拟器可以点，所以把通话状态直接摆成响铃再画。放在最后：摆完
        // 状态之后，别的图都会被这顶横幅顶上。
        model.seedIncomingCall(number: "+8613800138000")
        pump(0.2)
        render(PanelView(initialTab: .network).environmentObject(model),
               "hardware-panel-ringing", width: Theme.panelWidth, to: directory)
        print("真机 6 张图已写到 \(directory.path)")
        exit(0)
    }

    /// 截图之外再给一份能贴进聊天窗口的文字：机器不在手上时，这几行就是全部线索。
    private static func hardwareSummary(_ model: AppModel) -> String {
        guard model.isConnected else {
            return "\n真机状态：没连上 —— \(model.lastError ?? "模块没有响应")"
        }
        func db(_ value: Double?, _ unit: String) -> String {
            value.map { String(format: "%.1f %@", $0, unit) } ?? "--"
        }
        var lines = ["", "真机状态"]
        lines.append("  通道      \(model.transport)")
        lines.append("  模块      \(model.identity.model.isEmpty ? "读不到" : model.identity.model)"
                     + "  固件 \(model.identity.revision.isEmpty ? "读不到" : model.identity.revision)")
        lines.append("  IMEI      \(model.identity.imei.isEmpty ? "读不到" : model.identity.imei)")
        lines.append("  SIM       \(model.sim.label)")
        lines.append("  注册      \(model.network.reportedRegistration.label)"
                     + "  运营商 \(model.network.carrier.name)")
        lines.append("  信号      RSRP \(db(model.signal.rsrp, "dBm"))"
                     + "  RSRQ \(db(model.signal.rsrq, "dB"))"
                     + "  SINR \(db(model.signal.sinr, "dB"))")
        lines.append("  USB 组态  \(model.data.composition?.flagString ?? "读不到")"
                     + "  网卡 \(model.data.usbnetMode?.technicalName ?? "读不到")")
        lines.append("  上网      接口 \(model.data.interfaceName.isEmpty ? "没找到" : model.data.interfaceName)"
                     + "  联网服务 \(model.data.serviceLabel)")
        lines.append("  短信      \(model.messages.count) 条")
        lines.append("  通话语音  " + (model.voiceSetup.ready ? "已就绪" : "未就绪 —— " + model.voiceSetup.technicalSummary))
        return lines.joined(separator: "\n")
    }

    /// Headless exercise of the `--sim` launch path.
    ///
    /// `--render` covers the screenshots; this covers the other half of the
    /// simulator — the part that only exists while the app is running. Both
    /// depend on a background poll thread and a live run loop, so neither can
    /// be reviewed by reading the code. They get run instead.
    ///
    /// It also pins down the one property that would be invisible until it bit
    /// somebody: that the stated host link survives a refresh. An unpinned
    /// override looks correct in a screenshot and wrong one poll later.
    static func checkSimulator() {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "  \u{2713} \(name)" : "  \u{2717} \(name)")
            if !ok { failures += 1 }
        }

        // 这一档跑在**真 App 进程**里，UserDefaults 就是这台机器真那一份。
        // 下面要演「客户手选 APN」和「客人换卡」，两档都会往 `apnOwnerSIM`
        // 里写模拟器的卡号 —— 演完必须还原。不还原的话，自检会在这台机器上
        // 留下一个「模块里的 APN 是别的卡写的」的印子，下一次真插卡时自动路
        // 会照它去改写客户的 APN。
        let apnOwnerBefore = UserDefaults.standard.string(forKey: AppModel.apnOwnerSIMKey)
        // 同一件事的另一半：`apnManualPick` 是「卡座空着的时候有人按过运营商
        // 按钮」的占位记号，它会**关掉**自动改写的安全网。自检里好几档都在空
        // 卡座上按过按钮，留下它，客人换卡时那套自救就永远不触发了 —— 而且
        // 面板上完全看不出区别。用 `object(forKey:)` 取，为的是把「没设过」
        // 和「设成 false」分开，还原回原样。
        let apnManualBefore = UserDefaults.standard.object(forKey: AppModel.apnManualKey) as? Bool

        // `--nomodule` 那个夹具的口子，先钉住再往下走。
        //
        // 2026-09-26 发现它坏了：`--nomodule` 用的是会把模块连上的真模型，所以在
        // 模块常年插着的开发机上，那张图标的是「一个连着的模块」，而它要审的
        // 恰恰是「还没插模块」那段文案。这条检查就是那次事故的钉子 —— 它同时
        // 要求「模型看不到设备」和「没有报错」：只要有一点残渣落进 `lastError`，
        // 面板底部就会多出一行红字，而空口那一版文案旁边不该有别的话。
        AppModel.scanOverride = { [] }
        let bare = AppModel()
        pump(1.2)
        check("夹具口子造出「还没插模块」（通道=\(bare.transport)）",
              !bare.isConnected && bare.transport == "未连接")
        check("空口状态没有报错（\(bare.lastError ?? "无")）", bare.lastError == nil)
        // 上一条只读了刚造出来的那一瞬，而客户看见的红字是**轮询攒出来的**：
        // 模块没插时巡检每两三秒走一趟 `refreshAll()`，从前那一趟照样去读 AT
        // 口、读到「通道已关闭」，再把这条写进 `lastError` —— 面板底下于是常年
        // 挂着一行红字，而顶上明明写着「模块未连接 · 插到 Mac 的 USB 口」。
        // 2026-09-29 的真机截图里挂着的就是它。照着那个节奏读三趟，再问一次
        // 底下有没有红字；这里要是有一天红了，客户那扇等模块的窗口就又像坏了。
        for _ in 0..<3 { bare.refreshAll() }
        pump(0.4)
        check("模块没插时连着轮询也不挂红字（\(bare.lastError ?? "无")）", bare.lastError == nil)
        AppModel.scanOverride = nil

        let model = AppModel.launch(arguments: ["DJI4GMenuBar", "--sim"], announce: false)
        check("--sim 选中模拟器", model.isInteractiveSim && model.simulator != nil)
        check("--sim 连上了模拟模块", model.isConnected)
        check("--sim 不去扫 IOKit", model.attachedIdentity == nil)

        // Every arrival below is delivered by the poll thread draining URCs at
        // the live one-second cadence, so each one is waited for rather than
        // given a fixed number of seconds. A fixed wait passed on a fast run and
        // failed on a slow one, which is worse than failing every time: the
        // failures it produced said nothing about the code.
        waitUntil(model) { $0.messages.count >= 2 }
        check("开箱就有短信（\(model.messages.count) 条）", model.messages.count >= 2)
        check("收件箱里是中文", model.messages.contains { $0.text.contains("流量") })
        check("模拟器里能看到模块声卡（截图用）", model.voice.moduleDevice != nil)

        // The stated link is applied on the main thread but the first refresh
        // reports it from a background one. Waiting for the value also keeps the
        // next check honest: comparing "" to "" passes while proving nothing.
        waitUntil(model) { !$0.data.serviceName.isEmpty }
        // The panel used to open on a red 「上一步操作还没结束，刷新状态没有执行」
        // that nobody had caused: the connect handshake reads the whole link
        // back right after it has started the carrier-APN write itself, so the
        // read was refused by the app's own preceding step. Reads wait for the
        // write now, so by the time the first state has arrived there is
        // nothing to complain about — and nothing may have been refused, since
        // nothing here raced for the session.
        pumpUntilIdle(model)
        check("开机没有被自己挡下的操作刷红（\(model.lastError ?? "干净")）",
              model.lastError == nil)
        let pinned = model.data.serviceName
        check("网卡被钉住（\(pinned)）", !pinned.isEmpty && model.data.isRoutable)
        model.refreshAll()
        pumpUntilIdle(model)
        check("刷新之后仍然钉住，没有被 IOKit 抹掉（\(model.data.serviceName)）",
              !pinned.isEmpty && model.data.serviceName == pinned)

        // 数据开关的两个位置。老代码把胶囊画成「有链路 = 4G ON」：关掉数据之后
        // 网卡和它的 DHCP 租约还在（`isConnected` 照样为真），胶囊于是永远写着
        // `4G ON`，客户看到的是一块标签而不是开关 —— 2026-09-26 的反馈。这里
        // 钉住的是「开关的位置由按下它的人决定，跟链路状态脱钩」，而且关掉之后
        // 真的还有链路（否则这条检查等于什么都没验）。
        model.setDataEnabled(false)
        pumpUntilIdle(model)
        check("关掉数据后开关落在 OFF，而网卡还在（已连接：\(model.data.isConnected)）",
              !model.dataWanted && model.data.isConnected && !model.data.isRoutable)
        model.setDataEnabled(true)
        pumpUntilIdle(model)
        // 开服务那一句现在跑在后台（真机上它要拉一个 networksetup 进程，3–4 秒，
        // 放主线程上就是把面板冻住 —— 日志里那条「主线程卡住：4 秒没有响应」
        // 记的就是它）。`dataWanted` 按下即到，`isRoutable` 要等那一跳回来。
        waitUntil(model) { $0.data.isRoutable }
        check("再打开就回到 ON，而且流量真的能走（\(model.data.serviceLabel)）",
              model.dataWanted && model.data.isRoutable)

        // 开关不能被别人的活儿挡回来。刷新、连上模块时的握手都占着 AT 会话，
        // 客户按开关的那一秒挑不了时候；被挡回来时弹的那句「上一步操作还没
        // 结束」对客户没有任何意义 —— 他只是想上网。这一按要排队，并且自己
        // 落地，不该留下一行红字。
        model.refreshAll()
        model.setDataEnabled(false)
        let busyRefusal = model.lastError
        check("会话忙的时候按开关不被挡回来（\(busyRefusal ?? "没有报错")）",
              busyRefusal == nil && !model.dataWanted)
        pumpUntilIdle(model)
        pumpUntilIdle(model)
        check("排队的那一按自己落地（\(model.data.serviceLabel)）",
              !model.dataWanted && !model.data.isRoutable)
        model.setDataEnabled(true)
        pumpUntilIdle(model)
        waitUntil(model) { $0.data.isRoutable }
        check("排队之后再按回来，流量照样通（\(model.data.serviceLabel)）",
              model.dataWanted && model.data.isRoutable)

        model.simulateIncomingCall()
        waitUntil(model) { $0.call.state == .ringing && !$0.call.number.isEmpty }
        check("模拟来电会响铃", model.call.state == .ringing)
        check("来电号码正确（\(model.call.number)）", model.call.number == "+8613800138000")
        // The ring is two lines and the number is on the second one. Announcing
        // from the first would name the caller 「未知号码」.
        check("来电通知带号码（\(Notifier.shared.lastPosted?.title ?? "没发")）",
              Notifier.shared.lastPosted?.title == "来电 · +8613800138000")
        // 通知没被允许时，客户面前的电话必须还有第二条路可走：一张浮在最上面
        // 的卡片。规则在这里钉住 —— 该出现的两种状态要出现，已经接通的不要弹。
        check("来电会弹浮层卡片（铃声 + 接听/拒接）",
              RingAlert.wantsCard(.ringing) && RingAlert.wantsCard(.waiting))
        check("通话中和空闲都不弹浮层卡片",
              !RingAlert.wantsCard(.active) && !RingAlert.wantsCard(.idle))
        check("自检和截图那条路不弹浮层卡片", !model.announcesAlerts)

        // 会话正被别的活占着的时候按接听 —— 真机上打开面板那几秒就是这个局面
        // （整体刷新和自动配 APN 都还在跑）。这一下以前会被「上一步操作还没
        // 结束」整个丢回去：状态原地不动，电话一直响到对方放弃，而客人以为
        // 自己已经接了。`refreshAll()` 是当场抢下会话的，紧跟着按下去必然被
        // 挡，所以这条判据是确定的，不靠运气。
        model.refreshAll()
        model.answer()
        waitUntil(model) { $0.call.state == .active }
        check("会话被别人占着时按接听，这一下不会丢（\(model.call.state.label)）",
              model.call.state == .active)
        // 挂掉再响一次，把下面那条老判据的前置状态摆回来（它要的是一条来电）。
        model.simulateRemoteHangup()
        waitUntil(model) { $0.call.state == .idle }
        model.simulateIncomingCall()
        waitUntil(model) { $0.call.state == .ringing }

        // The state this reaches is the one that used to take thirty seconds:
        // `CallService` mutated itself and nobody emitted, so the panel went on
        // showing 「来电响铃」 until the next `refreshCalls()`.
        model.answer()
        waitUntil(model) { $0.call.state == .active }
        check("接听后进入通话中（\(model.call.state.label)）", model.call.state == .active)

        model.simulateIncomingCall()
        waitUntil(model) { $0.call.state == .waiting }
        check("通话中再来电显示为等待接听（\(model.call.state.label)）", model.call.state == .waiting)

        model.simulateRemoteHangup()
        waitUntil(model) { $0.call.state == .idle }
        check("对方挂断后回到空闲", model.call.state == .idle)

        let inbox = model.messages.count
        model.simulateIncomingSMS()
        waitUntil(model) { $0.messages.count > inbox }
        check("模拟短信进了收件箱（\(inbox) → \(model.messages.count)）",
              model.messages.count == inbox + 1)

        // `+CLIP` is a subscription, not a guarantee. A ring that never names
        // the caller still has to reach Notification Center: the grace timer is
        // what covers that, and a timer that never fired would swallow the
        // announcement entirely rather than merely misname it.
        model.simulator?.simulateIncomingCallWithoutNumber()
        waitUntil(model) { $0.call.state == .ringing }
        waitUntil(model) { _ in Notifier.shared.lastPosted?.title == "来电 · 未知号码" }
        check("没有号码的来电也会通知（\(Notifier.shared.lastPosted?.title ?? "没发")）",
              Notifier.shared.lastPosted?.title == "来电 · 未知号码")
        model.simulateRemoteHangup()
        waitUntil(model) { $0.call.state == .idle }

        // Outgoing is the half of the call feature the ring paths above never
        // touch: a different AT command, a different set of states, and the
        // audio handover firing on the way out rather than on the way in.
        pumpUntilIdle(model)
        model.dial("+8613900139000")
        waitUntil(model) { $0.call.state != .idle }
        check("拨号进入呼出中（\(model.call.state.label)）", model.call.state == .dialing)
        pumpUntilIdle(model)
        model.hangup()
        waitUntil(model) { $0.call.state == .idle }
        check("挂断后回到空闲（\(model.call.state.label)）", model.call.state == .idle)

        // Rejecting has to leave the module with no call at all, not with a
        // parked one: a rejected call still in the list turns the *next* ring
        // into a call-waiting event, and the panel would then offer to answer a
        // caller who had already gone.
        model.simulateIncomingCall()
        waitUntil(model) { $0.call.state == .ringing }
        pumpUntilIdle(model)
        model.reject()
        waitUntil(model) { $0.call.state == .idle }
        check("拒接后回到空闲", model.call.state == .idle)
        model.simulateIncomingCall()
        waitUntil(model) { $0.call.state == .ringing }
        check("拒接之后再来的电话还是响铃，不是等待接听（\(model.call.state.label)）",
              model.call.state == .ringing)
        model.simulateRemoteHangup()
        waitUntil(model) { $0.call.state == .idle }

        pumpUntilIdle(model)
        var sendResult: Bool?
        model.sendSMS(text: "测试短信，走一遍发送链路。", to: "10086") { ok in
            DispatchQueue.main.async { sendResult = ok }
        }
        waitUntil(model) { _ in sendResult != nil }
        check("发短信成功（\(sendResult.map(String.init) ?? "没有回调")）", sendResult == true)

        // Two sends back to back. The module takes one command at a time, so
        // the second one is refused — but it has to be refused *out loud*: the
        // compose sheet is waiting on that completion, and a dropped action
        // left it saying 「发送中…」 with no way back.
        // The completion lands one hop before the busy flag clears, so the two
        // sends below are only back to back once this one has fully settled.
        pumpUntilIdle(model)
        var firstSend: Bool?
        var secondSend: Bool?
        model.sendSMS(text: "连发第一条。", to: "10086") { ok in
            DispatchQueue.main.async { firstSend = ok }
        }
        model.sendSMS(text: "连发第二条。", to: "10086") { ok in
            DispatchQueue.main.async { secondSend = ok }
        }
        // Read the reason at the moment of the refusal. The send that was
        // already on the wire finishes afterwards and clears it, because by
        // then nothing is busy — which is the point of clearing it.
        let refusal = model.lastError
        waitUntil(model) { _ in firstSend != nil && secondSend != nil }
        check("连发第二次也会回话（第一次 \(firstSend.map(String.init) ?? "没有回调")）",
              firstSend == true)
        check("第二次被挡下并报失败（\(secondSend.map(String.init) ?? "没有回调")）",
              secondSend == false)
        check("挡下的理由说得出来（\(refusal ?? "没有报错")）",
              (refusal ?? "").contains("没有执行"))
        pumpUntilIdle(model)
        check("上一步做完之后旧的报错不再挂着（\(model.lastError ?? "已经清掉")）",
              model.lastError == nil)

        let empty = AppModel.launch(arguments: ["DJI4GMenuBar", "--sim-nosim"], announce: false)
        check("--sim-nosim 也走模拟器", empty.isInteractiveSim)
        waitUntil(empty) { $0.sim.state == .missing }
        check("--sim-nosim 报告未插卡（\(empty.sim.label)）",
              !empty.sim.ready && empty.sim.state == .missing)
        check("--sim-nosim 不假装有网卡", empty.data.ipv4Address.isEmpty)
        check("--sim-nosim 不假装有短信", empty.messages.isEmpty)

        // Without a card the module refuses both of these. What matters is that
        // the refusal is reported rather than swallowed: a call that silently
        // does nothing and an SMS that reports success both read as "the
        // software is broken" once the customer is holding the phone.
        pumpUntilIdle(empty)
        var refusedSend: Bool?
        let beforeSend = empty.lastError
        empty.sendSMS(text: "没有卡的时候不该假装已经发出去了。", to: "10086") { ok in
            DispatchQueue.main.async { refusedSend = ok }
        }
        waitUntil(empty) { _ in refusedSend != nil }
        check("没插卡时发短信报失败（\(refusedSend.map(String.init) ?? "没有回调")）",
              refusedSend == false)
        // The reason has to be the empty slot's. A refused action reports false
        // too, so without this the check above could pass on a busy model while
        // proving nothing about a missing card — and the error has to be waited
        // for rather than read, because the last one is still sitting there.
        waitUntil(empty) { $0.lastError != beforeSend }
        check("没插卡时发短信的失败原因是没卡（\(empty.lastError ?? "没有报错")）",
              (empty.lastError ?? "").contains("SIM"))

        pumpUntilIdle(empty)
        let sendFailure = empty.lastError
        empty.dial("+8613800138000")
        waitUntil(empty) { $0.lastError != sendFailure }
        check("没插卡时拨号说明原因（\(empty.lastError ?? "没有报错")）",
              (empty.lastError ?? "").contains("SIM"))
        check("没插卡时拨号不会假装通话中", empty.call.state == .idle)

        // 设置窗里那排运营商按钮：点哪一家就写哪一家的 APN，而且没插卡时
        // 也必须真的落下去。以前三个按钮传的是同一个调用、名字被丢掉，没卡
        // 时那条路又直接静默返回 —— 客户点下去看到的是一点动静都没有的界面，
        // 而这一下恰恰是卡还没到时唯一能提前做对的事。
        empty.applyCarrierAPN(force: true, carrier: CarrierCatalog.carrier(forMCCMNC: "46011"))
        pumpUntilIdle(empty)
        check("没插卡时点「电信」真的写进 CTNET（\(empty.data.apn.isEmpty ? "还是空" : empty.data.apn)）",
              empty.data.apn == "CTNET")
        empty.applyCarrierAPN(force: true, carrier: CarrierCatalog.carrier(forMCCMNC: "46000"))
        pumpUntilIdle(empty)
        check("换一家会改写，不是各写各的（\(empty.data.apn.isEmpty ? "还是空" : empty.data.apn)）",
              empty.data.apn == "CMNET")
        check("写 APN 不当成故障报出来（\(empty.lastError ?? "干净")）", empty.lastError == nil)

        // 客户真正要做的动作是把卡推进去。真机上就是卡座从这一下开始报到有卡，
        // 轮询线程几秒内读到 `+CPIN: READY`，面板自己变好 —— 不重启 App，也不
        // 重启模块，客户什么都不用按。这条路径在插卡之前从没被执行过，所以在
        // 模拟器上重演一遍：这里**故意不按刷新**，等的就是轮询线程自己发现。
        let beforeInsert = empty.sim.label
        empty.simulator?.setSIMInserted(true)
        waitUntil(empty, timeout: 30) { $0.sim.ready }
        check("插卡后自己认到卡，不用重启 App（\(beforeInsert) → \(empty.sim.label)）",
              empty.sim.ready)
        check("插卡后卡座提示自己收掉（\(empty.sim.guidance.isEmpty ? "已收" : empty.sim.guidance)）",
              empty.sim.guidance.isEmpty)
        // 短信存在模块里，卡一认到就该有人去读一遍：不然客户看到的是
        // 「SIM 就绪 ＋ 空收件箱」，而模块里其实躺着历史短信。
        waitUntil(empty, timeout: 30) { !$0.messages.isEmpty }
        check("插卡后自动读出模块里的短信（\(empty.messages.count) 条）", !empty.messages.isEmpty)

        // 插卡那一刻 APN 也该自己好：客户拿到的就是插好卡的模块，打开就该能
        // 联网，不该还要求他先点一次 AUTO。上面那个模型里手选过 APN，走的是
        // 「客户手选的优先」那条路 —— 那条路同样要验，所以这里另开一个干净的
        // 空卡座，让它自己走一遍自动那条。
        let auto = AppModel.launch(arguments: ["DJI4GMenuBar", "--sim-nosim"], announce: false)
        waitUntil(auto) { $0.sim.state == .missing }
        pumpUntilIdle(auto)
        // 开关本身存在 UserDefaults 里，会被上一次运行带着走；自检要验的是
        // 「卡插上会不会自己配」，所以这里把它明确置成开。
        auto.autoApplyAPN = true
        check("插卡之前模块里没有 APN（\(auto.data.apn.isEmpty ? "空" : auto.data.apn)）",
              auto.data.apn.isEmpty)
        auto.simulator?.setSIMInserted(true)
        waitUntil(auto, timeout: 30) { $0.sim.ready && !$0.data.apn.isEmpty }
        check("插卡后自己把 APN 配上，不用点 AUTO（\(auto.data.apn.isEmpty ? "还是空" : auto.data.apn)）",
              auto.data.apn == "CMNET")
        check("自动配 APN 不当故障报出来（\(auto.lastError ?? "干净")）", auto.lastError == nil)

        // 反过来：客户手选过的那一家不被模块自己认到的覆盖掉。上面 empty 里
        // 手选的是移动的 CMNET，而模拟模块认到的也是移动 —— 为了让这条真的
        // 有区分度，先手选一家不同的，再插卡。
        let chosen = AppModel.launch(arguments: ["DJI4GMenuBar", "--sim-nosim"], announce: false)
        waitUntil(chosen) { $0.sim.state == .missing }
        pumpUntilIdle(chosen)
        // 这一档验的是「手选优先」这条规矩本身，所以先把前几档留下的主人记号和
        // 占位记号都清干净 —— 带着上一场的残渣过关，验的就不是它了。
        UserDefaults.standard.removeObject(forKey: AppModel.apnOwnerSIMKey)
        UserDefaults.standard.removeObject(forKey: AppModel.apnManualKey)
        chosen.autoApplyAPN = true
        // 真机上这一刻卡座是空的：读不到 ICCID，记号只能落在占位键上。
        chosen.applyCarrierAPN(force: true, carrier: CarrierCatalog.carrier(forMCCMNC: "46003"))
        pumpUntilIdle(chosen)
        check("插卡前手选电信写进 CTNET（\(chosen.data.apn.isEmpty ? "还是空" : chosen.data.apn)）",
              chosen.data.apn == "CTNET")
        // 空卡座上按的这一下要被记住。记不住的后果很具体：插卡那一拍它会走上
        // 「模块里这个是上一手留下的」那条路，客人刚按下去的那一家自己变了。
        check("卡座空着按的按钮记成「下一张卡的手选」",
              UserDefaults.standard.bool(forKey: AppModel.apnManualKey))
        chosen.simulator?.setSIMInserted(true)
        waitUntil(chosen, timeout: 30) { $0.sim.ready }
        pumpUntilIdle(chosen, timeout: 10)
        pump(1.5)
        check("客户手选的 APN 不被模块自己认到的覆盖（\(chosen.data.apn.isEmpty ? "被清空" : chosen.data.apn)）",
              chosen.data.apn == "CTNET")
        check("手选保护不当故障报出来（\(chosen.lastError ?? "干净")）", chosen.lastError == nil)

        // 同一枚硬币的另一面：2026-09-26 发现上面那条「手选优先」走过了头 ——
        // 它连**换了一张卡**也一起挡着。现场就是开发机上这一台：模块里留着
        // 电信的 CTNET，客人插一张移动卡进去，那张新卡从此用着一个别人的
        // APN，打不开任何一个网页，而面板上一个字都不说。
        //
        // 现在的规矩按卡分：同一个 ICCID 上照旧一个字不动（上一条钉的就是
        // 它），主人换了才改写。这里把「换了」那一半演一遍。卡号用真机那个
        // ICCID，演的就是交付当天那个现场。
        //
        let swap = AppModel.launch(arguments: ["DJI4GMenuBar", "--sim"], announce: false)
        waitUntil(swap) { $0.sim.ready }
        pumpUntilIdle(swap)
        swap.autoApplyAPN = true
        // 先摆成「电信卡 ＋ CTNET」。
        swap.simulator?.iccid = "89860325045754494684"
        swap.simulator?.imsi = "460115197034937"
        swap.simulator?.carrierMCCMNC = "46011"
        swap.simulator?.carrierName = "CHINA TELECOM"
        swap.refreshAll()
        waitUntil(swap, timeout: 30) { $0.data.apn == "CTNET" }
        pumpUntilIdle(swap)
        check("换卡前：电信卡自己配成 CTNET（\(swap.data.apn.isEmpty ? "还是空" : swap.data.apn)）",
              swap.data.apn == "CTNET")
        // 拔出来，插一张移动的。卡号一换，模块里那个 CTNET 就不是它的了。
        swap.simulator?.iccid = "89860012345000000001"
        swap.simulator?.imsi = "460001234500000"
        swap.simulator?.carrierMCCMNC = "46000"
        swap.simulator?.carrierName = "CHINA MOBILE"
        swap.refreshAll()
        waitUntil(swap, timeout: 30) { $0.data.apn == "CMNET" }
        pumpUntilIdle(swap)
        check("换了张卡，APN 跟着新那家走（\(swap.data.apn.isEmpty ? "还是空" : swap.data.apn)）",
              swap.data.apn == "CMNET")
        check("换卡改写不当故障报出来（\(swap.lastError ?? "干净")）", swap.lastError == nil)
        // 换回来还得跟得上，不然「只认第一次」也能骗过上面两条。
        swap.simulator?.iccid = "89860325045754494684"
        swap.simulator?.imsi = "460115197034937"
        swap.simulator?.carrierMCCMNC = "46011"
        swap.simulator?.carrierName = "CHINA TELECOM"
        swap.refreshAll()
        waitUntil(swap, timeout: 30) { $0.data.apn == "CTNET" }
        pumpUntilIdle(swap)
        check("再换回来也跟得上（\(swap.data.apn.isEmpty ? "还是空" : swap.data.apn)）",
              swap.data.apn == "CTNET")

        // 2026-09-26：卡在卡座里 ≠ 模块认得这张卡。刚插卡 / 刚上电那几秒，
        // `+QNWINFO` 报的还是上一次驻留的运营商 —— 真机实测：卡拔了，它照样
        // 回 `"FDD LTE","46011"`（中国电信）。照它写进 CTNET，模块里就有 APN
        // 了，而上面那条「手选优先」会让自动路从此再不碰它：客人换一张移动
        // 卡就永远连不上，还得靠人按按钮。所以：没在网就不写，注册上来自己补。
        let late = AppModel.launch(arguments: ["DJI4GMenuBar", "--sim-nosim"], announce: false)
        waitUntil(late) { $0.sim.state == .missing }
        pumpUntilIdle(late)
        late.autoApplyAPN = true
        late.simulator?.setSIMInserted(true)
        // 卡在了、但模块还在搜网：这正是「认不出是哪一家」的那几秒。
        late.simulator?.setRegistration(2)
        waitUntil(late, timeout: 20) { $0.sim.ready }
        pumpUntilIdle(late, timeout: 8)
        pump(2.5)
        check("模块还没在网时不写 APN（\(late.data.apn.isEmpty ? "空" : late.data.apn)）",
              late.data.apn.isEmpty)
        // 真机上这一刻到的是 `+CEREG: 0,1` 这条 URC，客户什么都不用按。
        late.simulator?.setRegistration(1)
        late.simulator?.pushURC("+CEREG: 0,1")
        waitUntil(late, timeout: 30) { !$0.data.apn.isEmpty }
        pumpUntilIdle(late)
        check("模块一注册上来，APN 自己补上（\(late.data.apn.isEmpty ? "还是空" : late.data.apn)）",
              late.data.apn == "CMNET")
        check("补写 APN 不当故障报出来（\(late.lastError ?? "干净")）", late.lastError == nil)

        // 默认路由保命那一条。2026-09-26 真机事故：4G 开着的时候把卡拔了，
        // 整台 Mac 断网，重启也不好（网络服务是开机就开着的），插回卡才恢复 ——
        // ECM 网卡永远拿得到 IP 和网关，包却出不去，默认路由就这么被压在
        // 一条死链路上。判断本身是纯函数，这里直接喂输入：真机上要等观察窗
        // 的，自检等不起，而这段的关键恰恰只在「哪种输入该抢路由」。
        //
        // 观察窗本身也要有护栏。2026-09-26：那 25 秒是客人真实的断网时长，
        // 面板上写着「在观察」，客人感受的是「整台电脑没网」。这个数字
        // 只会被往小里调，谁要把它改回二十几秒，这里当场报出来。
        check("观察窗够短（\(Int(AppModel.routeGraceSeconds)) 秒）",
              AppModel.routeGraceSeconds <= 10)
        check("没插卡 → 认定这条 4G 出不了网",
              AppModel.dataLinkTrouble(connected: true, simReady: false,
                                       registered: false) != nil)
        check("模块不在 → 同样认定出不了网",
              AppModel.dataLinkTrouble(connected: false, simReady: false,
                                       registered: false) != nil)
        check("卡在、但还没注册 → 照样认定出不了网",
              AppModel.dataLinkTrouble(connected: true, simReady: true,
                                       registered: false) != nil)
        check("卡在、注册了 → 不动默认路由（通不通由实测说了算）",
              AppModel.dataLinkTrouble(connected: true, simReady: true,
                                       registered: true) == nil)

        // 实测那一路。模块状态全绿却出不了网（卡欠费 / APN 选错 / 上游断）
        // 只有真发一个包才看得出来，而那时候客户的整台电脑已经没网了。
        check("实测连输够了、路由在模块上、还有别的路 → 认账",
              AppModel.probeTrouble(routeOnModule: true, failures: 2, hasOtherUplink: true))
        check("只输了一次 → 先不动（链路抖一下不算）",
              AppModel.probeTrouble(routeOnModule: true, failures: 1, hasOtherUplink: true) == false)
        check("默认路由不在这条链路上 → 跟 4G 无关，不认账",
              AppModel.probeTrouble(routeOnModule: false, failures: 9, hasOtherUplink: true) == false)
        check("机器上只剩这一条路 → 关了也没处去，不认账",
              AppModel.probeTrouble(routeOnModule: true, failures: 9, hasOtherUplink: false) == false)

        // 总闸本身：保命逻辑问的是**路由表现在在哪块网卡上**，不是那个只有完整
        // 刷新才更新的「服务开着没」标记。2026-09-26 交付当天真机实测出来的盲区：
        // 从外部把服务打开、再让模块掉网，整台电脑断了九十秒，保命逻辑一次都没动
        // —— 因为它读到的 `serviceEnabled` 还是 false，以为「这条 4G 不关我的事」。
        // 同一个故障从面板那条路进来只花八秒：八秒的观察窗没错，错的是有没有人去看。
        let liveRoute = NetProbe.defaultRouteInterface()
        check("默认路由查得出来，且就在它自己报的那块网卡上（\(liveRoute.isEmpty ? "这台机器现在没有默认路由" : liveRoute)）",
              liveRoute.isEmpty || NetProbe.defaultRouteIsOn(interface: liveRoute))
        check("名字对不上就不认（en999 上不会有默认路由）",
              NetProbe.defaultRouteIsOn(interface: "en999") == false)
        check("不知道模块叫什么名字时不猜（空名字一律不认）",
              NetProbe.defaultRouteIsOn(interface: "") == false)

        // 总闸那一条本身。中间这行就是真机翻车的那组输入：路由压在模块上，
        // 而 App 自己的标记还是「服务没开」—— 老代码在这组输入上回 false，
        // 于是整个保命逻辑一眼都不看。这条只要红了，就是那个盲区回来了。
        check("路由在模块上、App 却记着服务没开 → 照样要管（真机就是这么瞎了九十秒）",
              liveRoute.isEmpty || AppModel.holdsDefaultRoute(interfaceName: liveRoute,
                                                              serviceEnabled: false))
        check("接口名还没读到、服务是 App 自己刚开的 → 兜底认",
              AppModel.holdsDefaultRoute(interfaceName: "", serviceEnabled: true))
        check("路由不在模块上、服务也没开 → 不管（Wi-Fi 该走走）",
              AppModel.holdsDefaultRoute(interfaceName: "en999", serviceEnabled: false) == false)

        // 「还欠着一条链路」那笔账。2026-09-26 交付当天第二起真机事故：模块
        // 拔插回来时那句话是在 `en59` 还没出现的一瞬说的，`ensureHostService()`
        // 原地返回 —— 而它当时只在完整刷新（打开面板 / 手动刷新 / 切模式）里被
        // 叫一次，客人不开面板就永远等不到第二次。停用的服务让 macOS 不肯拉起
        // 网卡，网卡不出现又让这一句永远返回，两边互相等死。
        // 修法是把这笔账挂到三秒一次的巡检上（见 AppModel 里那盏灯的注释），
        // 判据抽成了这个纯函数。第一行就是真机上翻车的那组输入。
        check("接口还没出现 → 不动手，也**不许把欠账销掉**（真机就是这么等死的）",
              AppModel.pendingLinkCanLand(wantsDataLink: true,
                                          hasInterface: false,
                                          serviceEnabled: false) == false)
        check("接口一出现、服务还停着 → 补上",
              AppModel.pendingLinkCanLand(wantsDataLink: true,
                                          hasInterface: true,
                                          serviceEnabled: false))
        check("服务已经开着 → 不重复拉 networksetup（三秒一拍也不许起进程）",
              AppModel.pendingLinkCanLand(wantsDataLink: true,
                                          hasInterface: true,
                                          serviceEnabled: true) == false)
        check("客人自己按了 4G OFF → 接口再出现也不许自己打开",
              AppModel.pendingLinkCanLand(wantsDataLink: false,
                                          hasInterface: true,
                                          serviceEnabled: false) == false)

        // 「4G 开着，可系统里那条服务被人从外面关掉了」。2026-09-27 真机实测：
        // 先把服务打开让 App 接管（开关跟着链路自己摆到「开」），再从外面
        // `networksetup -setnetworkserviceenabled … off`，三十秒过去 App 一动
        // 不动，默认路由留在 Wi-Fi 上 —— 客人看到的是「开关是开的、却一直走
        // Wi-Fi」，而面板上没有一个字能解释为什么。
        //
        // 判据的五个输入每一个都能单独把它挡下来，下面六行就是那五条边界。
        check("服务被外面关掉、客人还开着 4G → 自己收回来",
              AppModel.shouldRestoreHostLink(dataWanted: true, linkWasUp: true, trouble: nil,
                                             hasInterface: true, routeOnModule: false))
        check("客人自己按了 4G OFF → 不许替他做主（他关得起也关得掉）",
              AppModel.shouldRestoreHostLink(dataWanted: false, linkWasUp: true, trouble: nil,
                                             hasInterface: true, routeOnModule: false) == false)
        check("这条路根本没跑起来过 → 没有可收回的东西，不重排进程",
              AppModel.shouldRestoreHostLink(dataWanted: true, linkWasUp: false, trouble: nil,
                                             hasInterface: true, routeOnModule: false) == false)
        check("模块这头出不了网 → 先等它好（开服务等于把整台 Mac 交给一条死链路）",
              AppModel.shouldRestoreHostLink(dataWanted: true, linkWasUp: true,
                                             trouble: "卡座里没有卡",
                                             hasInterface: true, routeOnModule: false) == false)
        check("网卡还没被 macOS 发布出来 → 等下一拍",
              AppModel.shouldRestoreHostLink(dataWanted: true, linkWasUp: true, trouble: nil,
                                             hasInterface: false, routeOnModule: false) == false)
        // 同一个现场，只把「默认路由压在哪儿」换一下。这就是那三十秒里唯一真的
        // 变过的东西：服务被关掉、路由回到 Wi-Fi，而 `data.serviceEnabled` 那个
        // 缓存还写着「开着」—— 第一版的判据就是拿它当答案，于是整段瞎了。判据
        // 必须问路由表，这一行钉的就是这件事。
        check("判据问的是路由表，不是那个会过期的服务状态（路由还在模块上就什么都不做）",
              AppModel.shouldRestoreHostLink(dataWanted: true, linkWasUp: true, trouble: nil,
                                             hasInterface: true, routeOnModule: true) == false)

        // 第四类故障：模块枚举好了，**系统那一半没做完**。2026-09-27 真机复现
        // 三次 —— 屏幕锁着的时候插上模块，`configd` 明确拒绝给它命名，而且解锁
        // 之后也不补做。网卡永远停在「在 IOKit 里、没有 BSD 名字」，App 这边看到
        // 的却是「网卡还没出现」，于是它一直等一个不会来的东西。
        //
        // 唯一的出路是让模块重新枚举一次，而这条动作的代价是所有自愈里最大的
        // （断网二十秒，通话还会被掐掉），所以下面每一行「不许动手」都得钉住。
        check("锁屏时插上的模块、系统没给网卡起名字 → 重新枚举一次救回来",
              AppModel.shouldRebootForStrandedInterface(wanted: true, connected: true, stranded: true,
                                                        consoleLocked: false, callIdle: true,
                                                        gaveUp: false))
        // 这一行是整段的地基：系统正因为锁屏才拒绝命名，这时候重新枚举照样被
        // 拒绝（真机实测三次全都是 `ignored`），而客户人不在 —— 白白断他一次网。
        check("屏幕还锁着 → 动了也是白动，等客人回来再说",
              AppModel.shouldRebootForStrandedInterface(wanted: true, connected: true, stranded: true,
                                                        consoleLocked: true, callIdle: true,
                                                        gaveUp: false) == false)
        check("客人自己按了 4G OFF → 不许替他做主",
              AppModel.shouldRebootForStrandedInterface(wanted: false, connected: true, stranded: true,
                                                        consoleLocked: false, callIdle: true,
                                                        gaveUp: false) == false)
        check("模块根本没连上 → 那是重连那一路的活，跟网卡无关",
              AppModel.shouldRebootForStrandedInterface(wanted: true, connected: false, stranded: true,
                                                        consoleLocked: false, callIdle: true,
                                                        gaveUp: false) == false)
        check("网卡好好的（正常插拔的绝大多数时候）→ 什么都不做",
              AppModel.shouldRebootForStrandedInterface(wanted: true, connected: true, stranded: false,
                                                        consoleLocked: false, callIdle: true,
                                                        gaveUp: false) == false)
        check("正在通话 → 重启会把语音链路掐断，让路",
              AppModel.shouldRebootForStrandedInterface(wanted: true, connected: true, stranded: true,
                                                        consoleLocked: false, callIdle: false,
                                                        gaveUp: false) == false)
        check("两次都没救回来 → 停手，把话留给客人",
              AppModel.shouldRebootForStrandedInterface(wanted: true, connected: true, stranded: true,
                                                        consoleLocked: false, callIdle: true,
                                                        gaveUp: true) == false)

        // 探针本身：连一个必然被拒的端口，必须**立刻**回 false，不能等超时。
        let refusedStart = Date()
        let refused = NetProbe.tcpConnect(host: "127.0.0.1", port: 1, timeout: 3)
        let refusedCost = Date().timeIntervalSince(refusedStart)
        check("连本机一个没人听的端口 → 不通，且立刻返回（\(String(format: "%.2f", refusedCost))s）",
              refused == false && refusedCost < 2)

        // 「掉网以后多久能看见」那一条。2026-09-26 交付当天真机实测：从
        // `AT+CFUN=0` 掉网，到默认路由交回 Wi-Fi，一共三十一秒 —— 而观察窗
        // 那八秒是对的，二十四秒全花在「多久才看见」上。当时看注册状态走的是
        // 三十秒一次的整体刷新，而它正好被「模块断电后重装通话语音」（二十多
        // 秒）堵住。现在单开一条只问注册的便宜路，并且只在默认路由押在模块上
        // 的那两个窗口走快档。
        let watchEvery = ModemController.registrationWatchEvery(watching: true)
        check("默认路由押在模块上 → 注册状态快问（\(watchEvery) 秒一拍）",
              watchEvery > 0 && watchEvery <= 3)
        check("路由不在模块上 → 不白问（\(ModemController.registrationWatchEvery(watching: false))）",
              ModemController.registrationWatchEvery(watching: false) == 0)
        // 快档必须明显快过观察窗。不快过它，那八秒就压在「三十秒才看见」
        // 后面白等 —— 2026-09-26 那三十一秒里，二十四秒正是这么来的。
        check("快档明显快于观察窗（\(watchEvery) 秒 vs \(Int(AppModel.routeGraceSeconds)) 秒）",
              Double(watchEvery) <= AppModel.routeGraceSeconds / 2)

        // 演一遍真机那条路：模块掉网（`+CEREG: 0,2`），看门狗那两条便宜的
        // 命令自己看见，不用等一趟完整刷新 —— 真机上那趟刷新要等满八秒超时。
        let watched = AppModel.launch(arguments: ["DJI4GMenuBar", "--sim"], announce: false)
        waitUntil(watched) { $0.sim.ready }
        pumpUntilIdle(watched)
        check("演之前：模块是在网的（\(watched.network.reportedRegistration)）",
              watched.network.dataRegistered)
        watched.simulator?.setRegistration(2)
        _ = try? watched.controller.refreshRegistration()
        waitUntil(watched, timeout: 8) { !$0.network.dataRegistered }
        check("模块一掉网，那两条便宜的 AT 就看得见（\(watched.network.reportedRegistration)）",
              !watched.network.dataRegistered)
        check("看见之后判定跟着翻：这条 4G 出不了网",
              AppModel.dataLinkTrouble(connected: watched.isConnected,
                                       simReady: watched.sim.ready,
                                       registered: watched.network.dataRegistered) != nil)

        // 上面这条现在会通过，是因为「刷新」终于把读到的列表推给界面了。读收件箱
        // 以前只在握手和新短信回来时做，于是「按刷新不重读」「删掉的那行还在」
        // 一起活了下来 —— 那两件事在真机上只表现成客户以为按钮坏了。删一条再
        // 看列表，就是给那段代码留的哨兵。
        pumpUntilIdle(empty)
        if let victim = empty.messages.first {
            empty.deleteSMS(victim)
            waitUntil(empty) { $0.messages.isEmpty }
            check("删掉的短信不会留在列表里（剩 \(empty.messages.count) 条）", empty.messages.isEmpty)
        } else {
            check("删掉的短信不会留在列表里（收件箱是空的，这条没验到）", false)
        }

        // 认到卡之后，之前被挡下的两件事要真的能用 —— 只把状态改绿、动作还是
        // 被挡，是最容易被忽略的一种「修好了」。
        pumpUntilIdle(empty)
        var hotSend: Bool?
        empty.sendSMS(text: "插卡之后这条应该发得出去。", to: "10086") { ok in
            DispatchQueue.main.async { hotSend = ok }
        }
        waitUntil(empty) { _ in hotSend != nil }
        check("插卡后短信能发出去（\(hotSend.map(String.init) ?? "没有回调")）", hotSend == true)

        pumpUntilIdle(empty)
        empty.dial("+8613800138000")
        waitUntil(empty) { $0.call.state != .idle }
        check("插卡后拨号真的拨出去（\(empty.call.state.label)）", empty.call.state == .dialing)
        pumpUntilIdle(empty)
        empty.hangup()
        waitUntil(empty) { $0.call.state == .idle }
        check("挂断之后回到空闲（\(empty.call.state.label)）", empty.call.state == .idle)
        check("插卡这一路没有留下红字（\(empty.lastError ?? "干净")）", empty.lastError == nil)

        // 卡还没插的这几天不是空等：一次性设置跟卡没有关系，现在就能写完
        // —— 而且应该现在写完。它写完要重启一次模块，趁没插卡先重启，等卡
        // 到了就不会把刚上线的网络掐一下。
        //
        // 这条提示得自己出现、自己消失。面板上不会自己消失的提示，客户读第
        // 三遍以后就不读了，那时它挡的就是真出问题的那条红字。
        //
        // 2026-09-27：句子本身压成了一句 —— 原来它把「USB 网卡 / 模块声卡」
        // 两个内部名字和「不需要卡」的理由都写出来，两行灰字。客户的原话是
        // 「按钮没几个，全是字」。所以这里查的是它还有没有把该说的两件事说
        // 到：不用等卡，以及去哪儿点。
        let preCard = AppModel.launch(arguments: ["DJI4GMenuBar", "--sim-nosim"], announce: false)
        waitUntil(preCard) { $0.sim.state == .missing }
        pumpUntilIdle(preCard)
        let audioNote = preCard.preCardSetupNote ?? ""
        check("没插卡时提示可以先把模块开好（\(audioNote.isEmpty ? "没有提示" : audioNote)）",
              audioNote.contains("卡还没插"))
        check("这句话说清楚不用卡、也说清楚去哪儿点（\(audioNote)）",
              audioNote.contains("卡还没插") && audioNote.contains("一键启用"))
        // 换一种缺法，提示还得在。一代模块出厂就是 RNDIS，也就是客户拿到的
        // 第一台机器本来的样子；切过去这一步不重启模块，正好能演。
        pumpUntilIdle(preCard)
        preCard.setUSBnetMode(.rndis)
        waitUntil(preCard) { $0.data.usbnetMode == .rndis }
        let bothNote = preCard.preCardSetupNote ?? ""
        check("只差网络这一样时这句话也还在（\(bothNote.isEmpty ? "没有提示" : bothNote)）",
              bothNote.contains("一键启用"))
        // 两样都开好之后必须收掉。这里直接写组态（不重启），读回来的仍然是
        // 模块里的真实组态 —— 和面板看的是同一个数。
        pumpUntilIdle(preCard)
        _ = try? preCard.controller.voice.enableAudioFunction(reboot: false)
        _ = preCard.controller.refreshData()
        // 「一键启用」是两样一起写的，所以这里也得两样一起开：只开了声卡
        // 那句话还该留着说 USB 网卡 —— 那不是没收干净，是还没做完。
        preCard.setUSBnetMode(.ecm)
        waitUntil(preCard) { $0.data.usbnetMode == .ecm }
        waitUntil(preCard) { $0.data.composition?.audio == true }
        pumpUntilIdle(preCard)
        check("两样都开好之后这句话收掉（\(preCard.preCardSetupNote ?? "已收")）",
              preCard.data.composition?.audio == true && preCard.preCardSetupNote == nil)

        // 「读不到 USB 接口描述」在传输层只说了一半：它把原因说对了，却没有
        // 下一步，客户读完只能去拔插线 —— 而那正好是没用的动作。这里钉住换成
        // 的那句话，也钉住「只换这一种」：别的失败原因不许被顺手改口。
        let noPermit = ATTransportError.noATInterface(
            "模块已连接，但读不到它的 USB 接口描述（FFFF:FFFF）；当前进程可能没有 USB 访问权限")
        let noPermitText = AppModel.connectFailure(
            noPermit, identity: USBModuleIdentity(vendorID: 0xFFFF, productID: 0xFFFF, label: "测试"))
        check("拿不到 USB 权限时给的是「双击 App 重开」（\(noPermitText)）",
              noPermitText.contains("访达") && noPermitText.contains("双击"))
        check("这句话不再让人去拔插线（\(noPermitText)）",
              !noPermitText.contains("拔插") && noPermitText.contains("USB 权限"))
        let timedOut = AppModel.connectFailure(ATTransportError.timeout, identity: .dji)
        check("超时那种失败照原样报（\(timedOut)）",
              timedOut.contains("等待模块响应超时"))

        // AT 口打不开的时候，报错里那个「被谁占着」必须是真凶。
        //
        // 2026-09-25 客户那儿报回来的是「模块正被 AppleUSBECHControl 占用」，
        // 而 AT 口（接口 2）在 IORegistry 里根本没人署名 —— 那句话是拿
        // `holders.first` 念出来的，而 `holders` 收的是**所有**接口的占用者：
        // USB 网卡那两口归 AppleUSBECMControl / AppleUSBECMData、声卡归
        // AppleUSBAudioDevice。客户照着这句话去退一个根本不存在的程序，永远
        // 也修不好。下面三份快照就是照着他那台机器的样子摆的。
        func interface(_ number: Int, _ role: USBInterfaceRole, owner: String = "") -> USBInterfaceInfo {
            USBInterfaceInfo(number: number,
                             interfaceClass: role == .audio ? 0x01 : (role == .network ? 0x02 : 0xFF),
                             subClass: 0, protocolNumber: 0, endpointCount: 2,
                             owner: owner, role: role)
        }
        // detail 就是传输层原样带出来的那句，别自己再加一层前缀 —— 加了之后
        // 报错会读成「没有可用的 AT 接口：没有可用的 AT 接口：…」。
        let blocked = ATTransportError.noATInterface("接口 2 已被其它程序独占；退出占用它的程序后再试")

        // ① 真凶：另一个 DJI4G。它走 `USBInterfaceOpen`（不是 seize），**不写**
        //    `UsbExclusiveOwner`，所以这份快照里 AT 口看起来是空的 —— 恰恰是
        //    这种「没人署名却打不开」最需要说清楚，因为它正是客户点第二下的
        //    时候发生的事：菜单栏上已经有一个图标了。
        let secondInstance = USBInventory(
            identity: .dji,
            interfaces: [interface(0, .diag), interface(1, .nmea), interface(2, .at),
                         interface(3, .modem), interface(4, .audio, owner: "AppleUSBAudioDevice"),
                         interface(5, .network, owner: "AppleUSBECMData")],
            deviceOwner: "")
        let secondText = AppModel.connectFailure(blocked, inventory: secondInstance)
        check("AT 口没人署名时，指的是「另一个 DJI4G」而不是苹果驱动（\(secondText)）",
              secondText.contains("另一个 DJI4G") && !secondText.contains("AppleUSBECM"))
        // 三级台阶，一级比一级强：先看是不是自己开了第二个（最常见），再动线，
        // 最后才是重开 App。少了哪一级，客户都会卡在那一级上没办法往下走。
        //
        // 之所以不敢一口咬定「就是另一个 DJI4G」：通道卡住和被人占住在这一层
        // 是**同一个**错误码（kIOReturnNoResources），自检那一刻起就没法分辨。
        // 2026-09-26 就撞上过一次：在受限沙箱里跑，连设备节点本身都建不出
        // USB 通道，十个接口无一例外 —— 那种情况下「另一个 DJI4G」是句假话，
        // 只有下面第三级台阶管用。
        check("这句话给出三级能照着做的动作（\(secondText)）",
              secondText.contains("退出") && secondText.contains("拔掉数据线")
                  && secondText.contains("退出重开"))

        // ② 真被别人占着：那就得点名，客户才知道该退谁。
        let foreign = USBInventory(
            identity: .dji,
            interfaces: [interface(0, .diag), interface(1, .nmea),
                         interface(2, .at, owner: "Google Chrome"),
                         interface(5, .network, owner: "AppleUSBECMData")],
            deviceOwner: "")
        let foreignText = AppModel.connectFailure(blocked, inventory: foreign)
        check("AT 口真有署名占用者时照实点名（\(foreignText)）",
              foreignText.contains("Google Chrome") && !foreignText.contains("另一个 DJI4G"))

        // ③ 连 AT 接口都枚举不出来（线只插了一半、口不对），那就不是「被谁
        //    抓着」的事。这时候还去说「另一个 DJI4G」等于把客户支到错的方向。
        let noInterface = USBInventory(
            identity: .dji,
            interfaces: [interface(0, .diag), interface(1, .nmea)],
            deviceOwner: "")
        let noInterfaceText = AppModel.connectFailure(blocked, inventory: noInterface)
        check("枚举不到 AT 接口时不提「另一个 DJI4G」、也不点苹果驱动的名（\(noInterfaceText)）",
              !noInterfaceText.contains("另一个 DJI4G")
                  && !noInterfaceText.contains("Apple")
                  && noInterfaceText.contains("AT 接口"))

        // 设备级占用者是真凶时也不能漏（整台模块被 seize 走的情况）。
        let deviceHeld = USBInventory(
            identity: .dji,
            interfaces: [interface(0, .diag), interface(1, .nmea), interface(2, .at)],
            deviceOwner: "cusbat")
        check("整台设备被署名占用时点它的名（\(AppModel.connectFailure(blocked, inventory: deviceHeld))）",
              AppModel.connectFailure(blocked, inventory: deviceHeld).contains("cusbat"))

        // 一键启用 / 切 usbnet / 开模块声卡都会把模块重启掉。重启的那几秒里
        // 连不上是计划内的事，写成红字客户既看不懂也没有办法照着做，而面板
        // 还得说清楚他到底在等什么 —— 所以这三句分开写，各自都要对。
        check("没模块时状态行是「等待模块」",
              AppModel.waitingLabel(awaitingReconnect: false, attached: false) == "等待模块")
        check("有模块、正在连的时候是「连接中」",
              AppModel.waitingLabel(awaitingReconnect: false, attached: true) == "连接中")
        check("重启窗口里盖过另外两句（\(AppModel.waitingLabel(awaitingReconnect: true, attached: true))）",
              AppModel.waitingLabel(awaitingReconnect: true, attached: true) == "模块重启中")

        model.disconnect()
        model.lastError = nil
        model.beginAwaitReconnect()
        check("窗口打开后进入等待状态", model.awaitingReconnect)
        check("等待期间状态行说的是「模块重启中」（\(model.stateLine)）",
              model.stateLine == "模块重启中")
        // 这段窗口里按刷新是最自然的动作：模块还没回来，读它只会得到一条
        // 红字，而客户按了刷新却被告知出错，只会以为是自己弄坏的。
        model.refreshAll()
        pumpUntilIdle(model)
        check("重启窗口里按刷新不会刷出红字（\(model.lastError ?? "干净")）", model.lastError == nil)
        model.clearAwaitReconnect()
        check("窗口关掉之后不再等", !model.awaitingReconnect)
        check("窗口关掉之后状态行回到「等待模块」（\(model.stateLine)）",
              model.stateLine == "等待模块")

        // 菜单栏那一项：客户的「图标点得动、菜单不弹」就是这里出的事。这段
        // 不变量得钉在代码里，不能靠人再去看一遍视频。
        //
        // 2026-09-25 的根因是标签按状态换**分支**：`4G` 是两块（信号条＋
        // 文字），掉线是一块（一个符号）。视图结构一变，SwiftUI 就把菜单栏
        // 那一项拆掉重建；重建正好撞在面板正在弹出的那一帧上，面板跟着没
        // 了。客户点下去的那一刻模块掉线，于是「点得动、不弹」。
        //
        // 本机之所以一直没发现，是因为 macOS 15 上掉线从不落在点击那一瞬
        // 间 —— 怎么点都正常。所以这里钉的不是「看起来对不对」，而是那条
        // 与运气无关的性质：**不管什么状态，标签都是同一个 `Image`，尺寸
        // 也一样**。谁再写回 `if 状态 { … }`，这几条就会红。
        // 走和 `--sim` 同一条创建路径，而不是自己搭一个裸模拟器：接听要
        // 走通的那些环节（宿主链路、模块声卡、每秒的轮询）都是
        // `beginInteractiveDemo` 里的，缺一样，`answer()` 就会连同这一整段
        // 检查一起停在响铃上 —— 看起来像是标签画错了，其实什么都没测到。
        let labelModel = AppModel.launch(arguments: ["DJI4GMenuBar", "--sim"], announce: false)
        waitUntil(labelModel) { $0.isConnected }
        // 四种状态各取一次：掉线、在线、来电响铃、通话中等待接听。掉线那
        // 一种借用上面的 `model`：它刚被 disconnect 过，正是客户视频里那
        // 一帧的样子。
        //
        // 图和视图类型都**当场**取下来。`AppModel` 是引用类型，把四个状态
        // 的模型攒到最后再读，读到的全是最后那一种 —— 这几条就会变成永远
        // 绿的摆设，正是它们想防的那种事。
        var labelStates: [(name: String, image: NSImage, body: String)] = []
        func capture(_ name: String, _ state: AppModel) {
            labelStates.append((name,
                                MenuBarLabel.image(for: state),
                                String(describing: type(of: MenuBarLabel(model: state).body))))
        }

        capture("掉线", model)
        capture("在线", labelModel)
        labelModel.simulateIncomingCall()
        waitUntil(labelModel) { $0.call.state == .ringing }
        capture("来电响铃", labelModel)
        labelModel.answer()
        waitUntil(labelModel) { $0.call.state == .active }
        labelModel.simulateIncomingCall()
        waitUntil(labelModel) { $0.call.state == .waiting }
        capture("等待接听", labelModel)

        let bodyTypes = labelStates.map(\.body)
        check("四种状态下菜单栏标签是同一个视图类型（\(Set(bodyTypes).count) 种：\(bodyTypes[0])）",
              Set(bodyTypes).count == 1)
        check("菜单栏标签是一个 Image，不是分支也不是组合（\(bodyTypes[0])）",
              bodyTypes[0].contains("Image")
                  && !bodyTypes[0].contains("Conditional")
                  && !bodyTypes[0].contains("Tuple"))
        // 结构不变不等于画什么都不变：来电必须看得出来，否则「有提示」和
        // 「没提示」在客户眼里是同一件事。号码那一版一定比「4G」宽。
        check("来电那一版比在线那一版宽，说明内容真的换了（"
              + "\(Int(labelStates[1].image.size.width)) → \(Int(labelStates[2].image.size.width))）",
              labelStates[2].image.size.width > labelStates[1].image.size.width)

        for state in labelStates {
            check("\(state.name)时菜单栏标签高度还是 \(Int(MenuBarLabel.labelHeight))"
                  + "（\(Int(state.image.size.height))）",
                  state.image.size.height == MenuBarLabel.labelHeight)
            check("\(state.name)时菜单栏标签宽度有效（\(Int(state.image.size.width))）",
                  state.image.size.width > 4)
            // 光有尺寸不够：`MenuBarExtra` 的标签只合成 `Text` 和 `Image`，
            // SwiftUI 自己画的东西会被整块丢掉 —— 那样图标还在、位置还占，
            // 只是空的。所以这里数一遍真的落了墨的像素。
            check("\(state.name)时菜单栏标签真的画出了东西（\(ink(state.image)) 个像素）",
                  ink(state.image) > 0)
        }

        // 面板窗口那条后路。这里钉得住的是「信号」那一半：客户双击第二下时，
        // 第二份要能把第一份叫起来（`SingleInstance` 里那条分布式通知），第一份
        // 要把它变成一次「开窗口」（菜单栏标签上的 `onReceive`）。窗口真的铺没铺
        // 出来只能在真窗口里看，那是 `--panel-window-check` 那一档的事。
        let ticket = PanelWindowRequest.shared.ticket
        PanelWindowRequest.shared.request(reason: "自检")
        check("请求面板窗口会把信号推出去（\(ticket) → \(PanelWindowRequest.shared.ticket)）",
              PanelWindowRequest.shared.ticket == ticket + 1)
        check("面板窗口的 id 和另外两条不重名（\(WindowID.panel)）",
              Set([WindowID.call, WindowID.setup, WindowID.panel]).count == 3)
        // 单实例这件事有两种写错的写法，后果都很重：把自己也数进去，App 连
        // 第一份都起不来（客户开机就是空的）；第二份不认第一份，客户双击一下
        // 就多一个连不上的斜杠图标。第一种在这里防。
        check("单实例判定不会把自己当成另一个实例",
              SingleInstance.otherInstance()?.processIdentifier
                  != ProcessInfo.processInfo.processIdentifier)

        // 只读查看页。它开在一个同一张网里谁都能扫到的端口上，所以这里钉住的
        // 是**它不会漏出去的东西**（IMEI、号码）和它唯一那道门禁。前半段是
        // 字符串上的事，后半段只有真的发一次 HTTP 请求才测得出来 —— 于是下面
        // 起了一个真的服务，用裸 socket 问它四个问题。
        let page = ReadOnlyPage()
        check("钥匙是 16 位（\(page.token.count)）", page.token.count == 16)
        check("钥匙里避开了念不清的 0 o 1 l i（\(page.token)）",
              page.token.allSatisfy { !"01loi".contains($0) })
        check("每次开出来的钥匙都不一样",
              ReadOnlyPage.newToken() != ReadOnlyPage.newToken())

        let pageText = DebugSnapshot.status(model: model, machine: MachineInfo.current())
        check("页面上看得到状态（\(pageText.split(separator: "\n").count) 行）",
              pageText.contains("连接：") && pageText.contains("信号："))
        check("页面上没有 IMEI 这一栏", !pageText.contains("IMEI"))
        check("页面上没有本机号码这一栏", !pageText.contains("本机号码"))
        check("模块报了 IMEI 的时候页面上也没有它"
              + "（\(model.identity.imei.isEmpty ? "模拟器没报，跳过这一条" : "已确认不含")）",
              model.identity.imei.isEmpty || !pageText.contains(model.identity.imei))

        let links = ReadOnlyPage.addresses(port: 8770, token: page.token)
        check("每条地址都带着钥匙（\(links.count) 条）",
              links.allSatisfy { $0.url.hasPrefix("http://") && $0.url.contains(page.token) })
        check("局域网排在异地前面",
              links.firstIndex(where: \.isTailscale)
                  .map { index in !links[index...].contains { !$0.isTailscale } } ?? true)
        check("Tailscale 那一段（100.64.0.0/10）认得出",
              ReadOnlyPage.isTailscale("100.64.0.1")
                  && ReadOnlyPage.isTailscale("100.127.255.254")
                  && !ReadOnlyPage.isTailscale("100.128.0.1")
                  && !ReadOnlyPage.isTailscale("192.168.1.4"))

        // 客户照着这一行敲地址。模块自己那张 USB 网卡（真机上系统管它叫
        // `Baiwang`）以前被报成「同一个 Wi-Fi 可用」，敲进去是打不开的 ——
        // 这一档钉的就是它不再冒充局域网。
        check("Wi-Fi 算连得过来的",
              ReadOnlyPage.reach(port: "Wi-Fi", type: "IEEE80211", ip: "192.168.99.97") == .wifi)
        check("有线以太网也算连得过来的",
              ReadOnlyPage.reach(port: "Ethernet", type: "Ethernet", ip: "10.0.0.9") == .wifi)
        check("模块自己的 USB 网卡不算局域网",
              ReadOnlyPage.reach(port: "Baiwang", type: "Ethernet", ip: "192.168.225.26") == .local)
        check("雷雳桥接不算局域网",
              ReadOnlyPage.reach(port: "Thunderbolt Bridge", type: "Bridge", ip: "192.168.1.9") == .local)
        check("iPhone USB 共享也不算局域网",
              ReadOnlyPage.reach(port: "iPhone USB", type: "Ethernet", ip: "172.20.10.2") == .local)
        check("Tailscale 的地址归到异地那一档",
              ReadOnlyPage.reach(port: "utun4", type: "", ip: "100.64.0.7") == .tailscale)
        check("能连的网卡和只能本机看的网卡不会混着列（\(links.count) 条）",
              links.allSatisfy(\.isLocalOnly) || links.allSatisfy { !$0.isLocalOnly })

        if let port = try? page.startAndWait() {
            page.update(status: pageText, log: "第一行\n第二行")
            let host = "Host: 127.0.0.1\r\n"
            func ask(_ request: String) -> Int? {
                ReadOnlyPage.probe(port: port, request: request)
            }
            check("只读页起得来（端口 \(port)）", page.isRunning)
            check("带上钥匙打得开正文页",
                  ask("GET /\(page.token)/ HTTP/1.1\r\n\(host)\r\n") == 200)
            check("带上钥匙读得到状态",
                  ask("GET /\(page.token)/status HTTP/1.1\r\n\(host)\r\n") == 200)
            check("钥匙不对只拿到 404",
                  ask("GET /nope/status HTTP/1.1\r\n\(host)\r\n") == 404)
            check("根路径也只拿到 404（扫端口的看到的是一堵墙）",
                  ask("GET / HTTP/1.1\r\n\(host)\r\n") == 404)
            check("写的动词被挡下（405）",
                  ask("POST /\(page.token)/ HTTP/1.1\r\n\(host)Content-Length: 0\r\n\r\n") == 405)
            page.stop()
            check("关掉之后就不在服务了", !page.isRunning)
        } else {
            check("只读页起得来", false)
        }

        // 模块在通话中途没了：客户拔线、模块自己重启、AT 口被别的程序抢走。
        // 这条路和 `AppModel.disconnect()` 不是同一条 —— 后者清 `call` 的那
        // 行轮不到它，而 `pollCallState()` 又要 `isConnected` 才肯跑。于是
        // `call` 一直停在「通话中」、时长接着走、通话窗一直挂着，成了一通永远
        // 挂不断的电话（2026-09-30 查到的暗病）。这一档把那场演出来。
        let unlucky = AppModel.launch(arguments: ["DJI4GMenuBar", "--sim"], announce: false)
        waitUntil(unlucky) { $0.isConnected && $0.sim.ready }
        pumpUntilIdle(unlucky)
        unlucky.simulateIncomingCall()
        waitUntil(unlucky) { $0.call.state == .ringing }
        pumpUntilIdle(unlucky)
        unlucky.answer()
        waitUntil(unlucky) { $0.call.state == .active }
        check("演之前：这通电话是接通的（\(unlucky.call.state.label)）",
              unlucky.call.state == .active)
        // 拔线。模拟器背后没有 IOKit，`verifyStillAttached()` 那条看不见它 ——
        // 而真机上「模块自己重启」「AT 口被抢走」走的也正是下面这条传输层丢掉
        // 的路，两条最后都落在 `handleTransportLoss` 里。
        unlucky.simulator?.close()
        unlucky.refreshAll()
        waitUntil(unlucky, timeout: 15) { !$0.call.state.isBusy }
        check("模块没了以后这通电话自己收掉（\(unlucky.call.state.label)）",
              !unlucky.call.state.isBusy)
        check("收掉之后不再停着「通话中」（\(unlucky.call.state.label)）",
              unlucky.call.state != .active)

        if let apnOwnerBefore {
            UserDefaults.standard.set(apnOwnerBefore, forKey: AppModel.apnOwnerSIMKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppModel.apnOwnerSIMKey)
        }
        if let apnManualBefore {
            UserDefaults.standard.set(apnManualBefore, forKey: AppModel.apnManualKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppModel.apnManualKey)
        }

        print(failures == 0 ? "SIMCHECK ok" : "SIMCHECK fail=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 来电浮层（真窗口）

    /// 来电时那张卡片是不是真的出现在屏幕上。
    ///
    /// `checkSimulator` 钉住的是「该不该弹」这一条判断；卡片本身是一块独立的
    /// `NSPanel`，它完全可以在判断为真的时候照样不出现 —— 窗口级别不对、
    /// collectionBehavior 漏了、尺寸算成 0、或者压根没被创建。那种失败在无头
    /// 自检里全绿，在客户那里是一个漏接的电话，所以这里把真实的 AppKit 窗口
    /// 跑起来再问一遍：屏幕上有没有它、装的是不是这通电话、以及最要紧的那一
    /// 步 —— 「接听」到底按不按得动。
    ///
    /// 这条路会短暂地把一张卡片盖在右上角（这正是它要验的东西），所以它是
    /// 单独的一档，不在 `--sim-check` 里跑。
    static func checkRingCard(to directory: URL? = nil) {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "  \u{2713} \(name)" : "  \u{2717} \(name)")
            if !ok { failures += 1 }
        }

        print("来电浮层（真窗口）")
        // 这里必须走 NSApplication.shared：首次访问才会把实例建出来，而
        // `NSApp` 这个全局是在那之后才被赋值的。@main 的 init() 跑在建实例
        // 之前，直接读 NSApp 会撞上 nil。
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // 真鼠标事件要有辅助功能授权才发得出去；没授权的时候结果是「点了没
        // 反应」，和按钮画错长得一模一样，所以先把这一条钉在输出里。
        print("  ·辅助功能授权：\(AXIsProcessTrusted() ? "有" : "没有 —— 真鼠标事件发不出去")")
        let homeCursor = cgCursorLocation()
        let model = AppModel.launch(arguments: ["DJI4GMenuBar", "--sim"], announce: true)
        check("--sim 演示模式（会弹卡片）", model.isInteractiveSim && model.announcesAlerts)
        pump(1.5)
        check("空闲时屏幕上没有浮层（\(floatingCards().count) 个）",
              !RingAlert.shared.isShowing && floatingCards().isEmpty)

        model.simulateIncomingCall()
        waitUntil(model) { $0.call.state == .ringing }
        check("来电进入响铃（\(model.call.state.label)）", model.call.state == .ringing)
        // 卡片是在状态落到 .ringing 之后由主线程铺上去的，多跑一会儿再问。
        pump(1.5)

        check("RingAlert 报告卡片在显示", RingAlert.shared.isShowing)
        let cards = floatingCards()
        check("屏幕上真的多出一个浮层窗口（\(cards.count) 个）", cards.count >= 1)

        if let card = cards.first, let screen = card.screen ?? NSScreen.main {
            check("窗口可见、不透明（alpha \(card.alphaValue)）",
                  card.isVisible && card.alphaValue > 0.9)
            check("浮在普通窗口之上（level \(card.level.rawValue)）", card.level == .floating)
            // 全屏看视频时来电也得能盖上来，这两条就是那个承诺。
            check("跟着客户切 Space、能盖住全屏",
                  card.collectionBehavior.contains(.canJoinAllSpaces)
                  && card.collectionBehavior.contains(.fullScreenAuxiliary))
            // 画出来不等于看得见：掉在屏幕外面、或者小成一个点，客户一样没有。
            check("整张卡片都落在屏幕可见区里（\(Int(card.frame.width))×\(Int(card.frame.height)) @ \(Int(card.frame.minX)),\(Int(card.frame.minY))）",
                  screen.visibleFrame.contains(card.frame)
                  && card.frame.width > 200 && card.frame.height > 80)

            // 尺寸是卡片按这通电话的号码现算出来的，所以它顺带证明了窗口里装
            // 的是这通来电，而不是上一通留下的东西。
            let host = NSHostingView(rootView: RingCard(
                number: model.call.number, title: "来电响铃", answer: {}, reject: {}))
            host.layout()
            let expected = host.fittingSize
            check("窗口尺寸就是这通电话的卡片（期望 \(Int(expected.width))×\(Int(expected.height))，实际 \(Int(card.frame.width))×\(Int(card.frame.height))）",
                  abs(card.frame.width - expected.width) < 2
                  && abs(card.frame.height - expected.height) < 2)

            if let directory { save(card: card, to: directory) }

            // 画得出来不代表点得动：无边框面板默认收不到鼠标，而这两个按钮是
            // 这通电话唯一的出口。这里用真事件按下去。
            let answered = pressCardButton(named: "接听", in: card)
            // 应用不在前台时第一次点击会被激活逻辑吃掉，看着和「按钮画错了」
            // 一模一样 —— 真出红字时先看这一行的前半段。
            print("  ·点之前：应用在前台=\(NSApp.isActive) 卡片是关键窗口=\(card.isKeyWindow)")
            check("「接听」按钮按得动（\(answered)）", answered)
            waitUntil(model) { $0.call.state == .active }
            check("按下去真的接通了（\(model.call.state.label)）", model.call.state == .active)
            pump(0.8)
            check("接通之后卡片自己收走（\(floatingCards().count) 个）",
                  !RingAlert.shared.isShowing && floatingCards().isEmpty)
            model.hangup()
            waitUntil(model) { $0.call.state == .idle }
        } else {
            check("拿到卡片窗口", false)
        }

        // 拒接是另一颗按钮、另一条状态迁移，客户同样会按。
        model.simulateIncomingCall()
        waitUntil(model) { $0.call.state == .ringing }
        pump(1.2)
        if let card = floatingCards().first {
            let rejected = pressCardButton(named: "拒接", in: card)
            check("「拒接」按钮按得动（\(rejected)）", rejected)
            waitUntil(model) { $0.call.state == .idle }
            check("按下去真的挂断了（\(model.call.state.label)）", model.call.state == .idle)
            pump(0.8)
            check("挂断之后卡片也收走（\(floatingCards().count) 个）",
                  !RingAlert.shared.isShowing && floatingCards().isEmpty)
        } else {
            check("第二通来电也弹卡片", false)
        }

        restoreCursor(to: homeCursor)
        print(failures == 0 ? "RINGCHECK ok" : "RINGCHECK fail=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - 通话有没有出声（纯函数）

    /// 「这一通有没有声音」的判据自检。
    ///
    /// 这一档**不碰硬件**：`CallAudioWatchdog.verdict` 是纯函数，这里把每一种
    /// 边界都摆出来跑一遍。之前那批「接起来一声没有、日志上却一切正常」，根
    /// 因正是判据的输入（按通清零的电平、按通算的回调数）本身是错的 —— 那
    /// 种错在真机上只能靠一通一通打去撞，在这里可以钉死。
    static func checkCallAudio() {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "  \u{2713} \(name)" : "  \u{2717} \(name)")
            if !ok { failures += 1 }
        }

        print("通话声音判据")

        // 一条「一切正常」的健康记录，下面按需要改某几项。
        func healthy() -> CallAudioBridge.Health {
            var health = CallAudioBridge.Health()
            health.uplinkInputCallbacks = 900
            health.uplinkOutputCallbacks = 900
            health.downlinkInputCallbacks = 900
            health.downlinkOutputCallbacks = 900
            health.uplinkPeak = 0.2
            health.downlinkPeak = 0.6
            return health
        }

        // 1. 刚建出来的记录必须是「四个环节都没跑过、两头 0」。
        //    这一条钉的是「按通清零」：计数器一旦跨通话留着，下一通的判据就
        //    再也落不下来，日志里会出现两通一模一样的峰值。
        let fresh = CallAudioBridge.Health()
        check("新记录四个环节都算没跑过（\(fresh.deadLegs.count) 个）", fresh.deadLegs.count == 4)
        check("新记录两头峰值都是 0", fresh.uplinkPeak == 0 && fresh.downlinkPeak == 0)
        check("新记录的暂存区溢出计数是 0", fresh.oversizedCallbacks == 0)

        // 2. 响铃那几秒不判：那时对端本来就没声音，拿它判只会把好电话拆掉。
        for second in [0.0, 1.0, 2.9] {
            check("通话 \(second) 秒时不判（响铃段）",
                  CallAudioWatchdog.verdict(health: CallAudioBridge.Health(),
                                            activeSeconds: second,
                                            silentRetryDone: false) == .fine)
        }

        // 3. 一条腿一个回调都没有 = 通路断了，而且要说得出是哪一条。
        let single = ["麦克风采集", "模块放音", "模块录音", "扬声器播放"]
        for (index, name) in single.enumerated() {
            var health = healthy()
            switch index {
            case 0: health.uplinkInputCallbacks = 0
            case 1: health.uplinkOutputCallbacks = 0
            case 2: health.downlinkInputCallbacks = 0
            default: health.downlinkOutputCallbacks = 0
            }
            check("少跑一个环节（\(name)）判为断了",
                  CallAudioWatchdog.verdict(health: health, activeSeconds: 5,
                                            silentRetryDone: false) == .dead(name))
        }

        // 4. 两条腿全断时，名字要一条不落 —— 自动重接的日志要能指到地方。
        var bothDead = healthy()
        bothDead.uplinkInputCallbacks = 0
        bothDead.downlinkOutputCallbacks = 0
        check("两处都断时名字都在",
              CallAudioWatchdog.verdict(health: bothDead, activeSeconds: 5,
                                        silentRetryDone: false) == .dead("麦克风采集、扬声器播放"))

        // 5. 通路断了的判定不受「有没有重接过」影响：通路是真断的，第一次
        //    就得修，修完还断就再修，不能因为「已经修过一次」就放着不管。
        check("断了就是断了（重接过也照判）",
              CallAudioWatchdog.verdict(health: bothDead, activeSeconds: 9,
                                        silentRetryDone: true) != .fine)

        // 6. 通路通着、两头一声没有 = 模块那边的语音通路没挂上（这一条正是
        //    昨天「接通后没有声音」最常见的样子）。
        var quiet = healthy()
        quiet.uplinkPeak = 0
        quiet.downlinkPeak = 0
        check("两头都 0、过了宽限期，判为要重挂",
              CallAudioWatchdog.verdict(health: quiet, activeSeconds: 4.5,
                                        silentRetryDone: false) == .silent)

        // 7. 但「两个人都还没开口」也是两头 0：宽限期之内不判，判了会把刚接
        //    起来的正常通话拆掉。
        for second in [3.0, 3.9] {
            check("两头都 0、还在宽限期内不判（\(second) 秒）",
                  CallAudioWatchdog.verdict(health: quiet, activeSeconds: second,
                                            silentRetryDone: false) == .fine)
        }

        // 8. 两头都 0 且已经为重挂修过一次：不再修。修不好说明不是这条路能
        //    修的，反复拆只会把一通好电话拆坏。
        check("两头都 0、已经重接过一次就不动它",
              CallAudioWatchdog.verdict(health: quiet, activeSeconds: 30,
                                        silentRetryDone: true) == .fine)

        // 9. 只有一头有声音就得当没事：对方在说、我方没开口，是正常通话。
        var oneWayOnly = quiet
        oneWayOnly.downlinkPeak = 0.4
        check("只有下面这头有声音也算正常",
              CallAudioWatchdog.verdict(health: oneWayOnly, activeSeconds: 9,
                                        silentRetryDone: false) == .fine)

        // 9-1. 反过来：客户在说话（上行有声），模块整整八秒没送过来一个采样
        //      点 —— 2026-09-30 01:17 那通 48 秒的电话就是这样，上行峰值
        //      0.2245、下行 0.0000，客户全程听不到对方。这一档以前每一拍都
        //      判「没事」，现在必须判得出来。
        var oneWayDead = healthy()
        oneWayDead.uplinkPeak = 0.2245
        oneWayDead.downlinkPeak = 0
        check("上行有声、下行一个采样点没有 → 判为只坏一半",
              CallAudioWatchdog.verdict(health: oneWayDead, activeSeconds: 9,
                                        silentRetryDone: false) == .oneWay("下行"))

        // 9-2. 只坏一半的宽限期比另外两档都长：它要动的是一通**已经在说话**
        //      的电话，宁可晚两秒。8 秒之内不判。
        for second in [4.0, 7.9] {
            check("只坏一半、还在宽限期内不判（\(second) 秒）",
                  CallAudioWatchdog.verdict(health: oneWayDead, activeSeconds: second,
                                            silentRetryDone: false) == .fine)
        }

        // 9-3. 底噪不算「有人在说」：安静房间里话筒底噪在 0.01 上下，没越过
        //      门槛就不能拿它当「客户在说话」的证据。
        var barelyAudible = oneWayDead
        barelyAudible.uplinkPeak = 0.01
        check("上行只有底噪不算「有人在说」",
              CallAudioWatchdog.verdict(health: barelyAudible, activeSeconds: 9,
                                        silentRetryDone: false) == .fine)

        // 9-4. 通路活着时过来的底噪（实测 0.0026）不能算「一个采样点都没有」
        //      —— 就差这一个数量级，判反了就是把一通好电话拆掉。
        var noisyIdle = oneWayDead
        noisyIdle.downlinkPeak = 0.0026
        check("下行过来的是底噪、不是死寂 → 不判",
              CallAudioWatchdog.verdict(health: noisyIdle, activeSeconds: 9,
                                        silentRetryDone: false) == .fine)

        // 9-5. 这一档每通只修一次：已经为重挂修过一次就不再动手。
        check("只坏一半、已经修过一次就不动它",
              CallAudioWatchdog.verdict(health: oneWayDead, activeSeconds: 30,
                                        silentRetryDone: true) == .fine)

        // 9-6. 三个宽限期的先后关系：这一档必须最宽，否则会把「刚接起来、
        //      只有客户在说话」的正常电话拆掉。
        check("只坏一半的宽限期是 8 秒、且比另外两档都宽（\(CallAudioWatchdog.oneWayGrace)）",
              CallAudioWatchdog.oneWayGrace == 8
              && CallAudioWatchdog.oneWayGrace > CallAudioWatchdog.silenceGrace)

        // 9-7. 「要不要连模块一起重挂」：缺的是模块那侧的两条腿才要，缺
        //      Mac 这侧的两条腿光重建桥就够了。
        check("断在模块录音 / 模块放音 → 要连模块重挂",
              CallAudioWatchdog.needsModuleRearm(deadLegs: "模块录音")
              && CallAudioWatchdog.needsModuleRearm(deadLegs: "麦克风采集、模块放音"))
        check("断在麦克风采集 / 扬声器播放 → 只重建 Mac 这头",
              !CallAudioWatchdog.needsModuleRearm(deadLegs: "麦克风采集")
              && !CallAudioWatchdog.needsModuleRearm(deadLegs: "扬声器播放"))

        // 10. 好通话一根汗毛都不许动。
        check("一切正常就不动它",
              CallAudioWatchdog.verdict(health: healthy(), activeSeconds: 60,
                                        silentRetryDone: false) == .fine)

        // 11. 判「断了」优先于判「没声音」：通路都断了，先接回来才对。
        var deadAndQuiet = quiet
        deadAndQuiet.uplinkInputCallbacks = 0
        check("又断又静音时先按「断了」处理",
              CallAudioWatchdog.verdict(health: deadAndQuiet, activeSeconds: 20,
                                        silentRetryDone: false) == .dead("麦克风采集"))

        // 12. 两个宽限期的先后关系：判「断了」等 3 秒，判「没声音」等 4 秒。
        //     后者必须更宽 —— 反过来会把「刚接起来还没人说话」当成故障。
        check("两个宽限期是 3 秒 / 4 秒（\(CallAudioWatchdog.stallGrace) / \(CallAudioWatchdog.silenceGrace)）",
              CallAudioWatchdog.stallGrace == 3 && CallAudioWatchdog.silenceGrace == 4
              && CallAudioWatchdog.silenceGrace > CallAudioWatchdog.stallGrace)

        // 13. 播放暂存区溢出的记录：这本身不是故障（按静音填了，声音不炸），
        //     但也不能把它算成「这条腿断了」。
        var oversized = healthy()
        oversized.oversizedCallbacks = 3
        check("暂存区溢出不算通路断掉",
              CallAudioWatchdog.verdict(health: oversized, activeSeconds: 9,
                                        silentRetryDone: false) == .fine)

        print(failures == 0 ? "CALLAUDIOCHECK ok" : "CALLAUDIOCHECK fail=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    /// 屏幕上真正在显示的那些浮层卡片。
    ///
    /// 只看 `RingAlert.isShowing` 是不够的：那个布尔量记的是意图，客户看到的
    /// 是窗口。这里问的是窗口。
    private static func floatingCards() -> [NSWindow] {
        NSApplication.shared.windows.filter {
            $0.isVisible && $0.level == .floating && $0.frame.width > 120 && !$0.isMiniaturized
        }
    }

    // MARK: - 面板窗口（真窗口）

    /// 排一次计时，等 App 的场景都建好再问。
    ///
    /// 这一档必须**在真 App 进程里**跑：窗口是 SwiftUI 场景开的，`--sim-check`
    /// 那种无头自检连场景都没有，怎么问都只会答「没有窗口」。
    static func schedulePanelWindowCheck(to directory: URL? = nil, after delay: TimeInterval = 3) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            checkPanelWindow(to: directory)
        }
    }

    /// 「面板弹不出来」时那条后路通不通。
    ///
    /// 客户报的是「菜单栏图标点得动，面板不弹」，而本机怎么点都正常 —— 我们
    /// 手里没有他那台机器，就得给他一个能在**他自己**的 Mac 上把后路跑一遍的
    /// 东西。这一段走的就是双击 App 图标时那条路：同一个 `PanelWindowRequest`、
    /// 同一个 `Window` 场景、同一个 `openWindow`，只是发起者从「他双击的第二下」
    /// 换成了定时器。
    ///
    /// 和 `--ring-check` 一样，它会真的在屏幕上开一个窗口（那正是它要验的东西），
    /// 所以是单独一档，不混在无头自检里。
    /// 面板内容里该不该有「自己画的那一排按钮」，以及「缩成一条」是不是真缩下去了。
    ///
    /// 客户 2026-09-29 的定论是「保留系统自带的，不要你生成的」：面板内容里不许
    /// 再出现红、黄、绿那三颗自绘的点 —— 那三颗归系统标题栏，由系统画。这一档把
    /// 这条规矩**读回来**验：摊开、折起各画一张，在位图左上角找那三颗点的色号，
    /// 数到一颗就算红。顺手再量两张图的高度，「缩成一条」得真的是一条。
    ///
    /// 这两件事本来都得在真窗口上用眼睛看，而这台出图机连窗口都建不出来
    /// （沙箱里 `--panel-window-check` 一颗窗口都拿不到）。`render` 那条路不用
    /// 窗口上屏也能画，所以换过来。
    static func checkPanelChrome(to directory: URL) {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ note: String = "") {
            let mark = ok ? "\u{2713}" : "\u{2717}"
            print("  \(mark) \(name)\(note.isEmpty ? "" : "（\(note)）")")
            if !ok { failures += 1 }
        }

        print("面板里有没有自绘的那三颗点")
        // 这台机器上插着什么模块跟这一档无关：面板是画出来的，不是读出来的。
        AppModel.scanOverride = { [] }
        let model = AppModel()
        pump(1.2)
        guard let wide = snapshot(PanelView(initialTab: .network).environmentObject(model),
                                  width: Theme.panelWidth),
              let mini = snapshot(PanelView(initialTab: .network, compact: true)
                                    .environmentObject(model),
                                  width: Theme.panelWidth) else {
            print("  \u{2717} 位图分配失败，画不出来")
            exit(1)
        }
        let wideH = Int(wide.size.height)
        let miniH = Int(mini.size.height)
        check("摊开的面板有完整高度", wideH > 400, "\(wideH)pt")
        check("折起来只剩一条", miniH < wideH / 2, "摊开 \(wideH)pt → 折起 \(miniH)pt")
        check("折起来不是空的", miniH > 18, "\(miniH)pt")

        for (label, shot) in [("摊开", wide), ("折起", mini)] {
            guard let lights = trafficLights(in: shot) else {
                check("\(label)时内容里没有自绘的红黄绿三颗点", true)
                continue
            }
            check("\(label)时内容里没有自绘的红黄绿三颗点", false,
                  String(format: "还是数到了 x = %.1f / %.1f / %.1f",
                         lights.close, lights.shrink, lights.expand))
        }

        // 点菜单栏图标时，得先把系统那扇下拉收回去。
        //
        // 下拉是系统浮层（实测层 101），比任何普通窗口都高：不收掉，新开的窗口
        // 就开在它下面，看起来和「点了没反应」一样 —— 客户 2026-09-29 报的正是
        // 这一条。收下拉走的是 `PanelDismiss.menuBarExtra`：真机上按的是系统那枚
        // 开关，而且只在它真开着的时候才按。
        //
        // 这一段真的开两扇窗（同一台机器上 `--ring-check` 已经证明建得出窗口），
        // 一扇装成面板下拉、一扇装成来电卡片，收一次，再读回来：下拉该没了，
        // 卡片该还在。判据是窗口自己的 `isVisible`，不是看代码里写了什么 ——
        // 铃声正响的时候把卡片一起收掉，是这个产品最不能出的错。
        print("收下拉收的是哪一扇")
        let dropdown = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 260),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        dropdown.level = .floating
        let card = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        card.level = .floating
        card.identifier = NSUserInterfaceItemIdentifier(RingAlert.windowIdentifier)
        dropdown.orderFrontRegardless()
        card.orderFrontRegardless()
        pump(0.6)
        if dropdown.isVisible && card.isVisible {
            PanelDismiss.menuBarExtra()
            pump(0.6)
            check("收下拉把面板下拉收走了", !dropdown.isVisible)
            check("收下拉没有碰来电卡片", card.isVisible)

            // 反过来那一半：下拉**没开着**的时候，这一按什么都不许做。
            // 收下拉按的是系统那枚「开关」—— 对着已经收好的下拉按下去，
            // 会把下拉凭空弹出来，比「点两次才开」更难看。
            dropdown.orderOut(nil)
            card.orderOut(nil)
            pump(0.4)
            PanelDismiss.menuBarExtra()
            pump(0.4)
            check("下拉没开着时，这一按不乱动",
                  !dropdown.isVisible && !card.isVisible)
        } else {
            // 没有窗口服务的机器（CI、纯 ssh）走到这里。这不是失败，是这一段
            // 没条件跑；说清楚，别让人以为验过了。
            print("  ·这台机器铺不出窗口，这一段跳过（下拉可见=\(dropdown.isVisible)"
                  + "，卡片可见=\(card.isVisible)）")
        }
        dropdown.orderOut(nil)
        card.orderOut(nil)

        for (name, shot) in [("panel-chrome", wide), ("panel-chrome-folded", mini)] {
            guard let data = shot.image.representation(using: NSBitmapImageRep.FileType.png,
                                                      properties: [:]) else { continue }
            try? data.write(to: directory.appendingPathComponent("\(name).png"))
            print("  \(name).png  \(Int(shot.size.width * shot.scale))×\(Int(shot.size.height * shot.scale))")
        }

        print(failures == 0 ? "PANELCHROME ok" : "PANELCHROME fail=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    /// 在出图的左上角找那三颗自绘的点，返回各自圆心的 x（点）。
    ///
    /// 撤掉那套之后，这个函数反过来用：`nil` 才是对的 ——「一颗都没数到」
    /// 说明内容里干干净净，没有和系统标题栏重复的第二排。
    ///
    /// 只扫左上角一小块：三颗点在面板最左边，横向 60pt、纵向 24pt 之内。
    /// 扫全图会把别处的绿也算进来，而这块面板上到处都是绿的（黑屏那一整块
    /// 就是荧光绿的字）。三个色号是从原来那套自绘点里抄过来的 —— 那套已经
    /// 撤掉（客户要系统标题栏那三颗），这里只留下来当判据：**不该再数到**。
    /// 判据留了余量，让抗锯齿的边缘也能算进去。
    private static func trafficLights(in shot: (image: NSBitmapImageRep, size: NSSize, scale: CGFloat))
        -> TrafficLights? {
        var found: [String: [CGPoint]] = ["close": [], "shrink": [],
                                          "expand": [], "expandDim": []]
        let columns = min(Int(60 * shot.scale), shot.image.pixelsWide)
        // 扫多高。菜单栏下拉那一份，三颗点贴着上沿（≈15pt）；同一个 `PanelView`
        // 挂到独立窗口上时，上面还压着一条系统标题栏，点落到 ≈44pt 处。原来
        // 只扫最上面 24pt，于是「窗口那份没画点」是**量出来的假警报** ——
        // 2026-09-29 在客户机上真踩到了。放到 72pt，再靠下面那条「三颗点必须
        // 共线」把别处混进来的同色像素挡住。
        let rows = min(Int(72 * shot.scale), shot.image.pixelsHigh)
        for row in 0..<rows {
            for column in 0..<columns {
                guard let color = shot.image.colorAt(x: column, y: row)?.usingColorSpace(.sRGB)
                else { continue }
                let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                let point = CGPoint(x: CGFloat(column) / shot.scale,
                                    y: CGFloat(row) / shot.scale)
                if r > 0.75, g < 0.60, b < 0.60, r - g > 0.25, r - b > 0.25 {
                    found["close"]?.append(point)
                } else if r > 0.85, g > 0.60, b < 0.45, g - b > 0.25, r - g > 0.10 {
                    found["shrink"]?.append(point)
                } else if g > 0.60, r < 0.55, g - r > 0.25, g - b > 0.20 {
                    found["expand"]?.append(point)
                } else if g > 0.85, g - r > 0.06, g - b > 0.06 {
                    // 压暗的那一版绿。它压在浅灰壳上读出来是 (0.81, 0.91, 0.83)，
                    // 底色是 (0.93, 0.94, 0.94) —— 两者只差几个百分点，所以判据
                    // 卡在「绿比红、比蓝都高出 0.06」上：底色那里只差 0.01，
                    // 过不来。亮绿（绿 0.80）被上面那条先接走了，也不会落到这。
                    found["expandDim"]?.append(point)
                }
            }
        }
        // 一颗 11pt 的圆在这张图上是一百多个点（scale 2），几十个也可能是
        // 半颗 —— 门槛压在 60，少了就当没找着。
        func centre(_ key: String) -> CGPoint? {
            guard let list = found[key], list.count > 60 else { return nil }
            return CGPoint(x: list.reduce(0) { $0 + $1.x } / CGFloat(list.count),
                           y: list.reduce(0) { $0 + $1.y } / CGFloat(list.count))
        }
        guard let close = centre("close"), let shrink = centre("shrink") else { return nil }
        let lit = centre("expand"), dim = centre("expandDim")
        guard let expand = lit ?? dim else { return nil }
        // 三颗点得在**同一行**上。扫得高了，别处的同色像素（绿字、红标）就有
        // 机会混进来；它们不会和另外两颗共线，这一条把它们挡在门外。
        let rows_ = [close.y, shrink.y, expand.y]
        guard let low = rows_.min(), let high = rows_.max(), high - low < 6 else { return nil }
        return TrafficLights(close: close.x, shrink: shrink.x, expand: expand.x)
    }

    /// 左上角那三颗点读回来的样子（只用来判「还在不在」）。
    private struct TrafficLights {
        var close: CGFloat
        var shrink: CGFloat
        var expand: CGFloat
    }

    static func checkPanelWindow(to directory: URL? = nil) {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "  \u{2713} \(name)" : "  \u{2717} \(name)")
            if !ok { failures += 1 }
        }

        print("面板窗口（真窗口）")
        let app = NSApplication.shared
        print("  ·开机 \(Int(ProcessInfo.processInfo.systemUptime)) 秒，"
              + "屏幕上现在有 \(app.windows.count) 个窗口：")
        // 先把已有的窗口列出来。真出红字的时候，这一段能直接回答是「窗口压根
        // 没建」、「建了但没显示」，还是「显示了但在屏幕外」—— 三种修法完全不同。
        for window in app.windows {
            print("    ·层=\(window.level.rawValue) 可见=\(window.isVisible)"
                  + " \(Int(window.frame.width))×\(Int(window.frame.height))"
                  + " 标题=\(window.title.isEmpty ? "（无）" : window.title)")
        }

        PanelWindowRequest.shared.request(reason: "自检 --panel-window-check")
        // 窗口是 SwiftUI 场景起的：建场景一帧、布局一帧、上屏一帧，给它两秒半。
        pump(2.5)

        // 认窗口靠宽度：`PanelView` 的宽度是钉死的 `Theme.panelWidth`，而菜单栏
        // 那个下拉的层号不是 0（实测 101），这样两边不会认错。
        let panels = app.windows.filter {
            $0.isVisible && $0.level == .normal && abs($0.frame.width - Theme.panelWidth) < 4
        }
        check("发了信号之后屏幕上多出一个面板窗口（命中 \(panels.count) 个）",
              panels.count == 1)
        if let window = panels.first {
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            check("窗口整块落在屏幕可见区里（\(Int(window.frame.minX)),\(Int(window.frame.minY))"
                  + " \(Int(window.frame.width))×\(Int(window.frame.height))）",
                  visible.contains(window.frame))
            // 画出来不等于有东西：一个只剩底色的空窗，客户一样什么都做不了。
            check("窗口里有内容，不是个空壳（高 \(Int(window.frame.height))）",
                  window.frame.height > 200)
            // 窗口整块可拖：客户 2026-09-29 的原话是「随意移动位置」。
            // 这一条是**读回来**验的，不是看代码里有没有那句调用 —— 哪天有人
            // 把 `bringsWindowToFront(movableByBackground:)` 的实参漏了、
            // 或者被别处的赋值盖掉，这里立刻红，不用等客户来报「挪不动」。
            check("窗口整块都能拖，不是只有窄窄一条窗沿",
                  window.isMovableByWindowBackground)
            // 左上角只该有一排按钮。
            //
            // 2026-09-29 客户在这扇窗的截图上数出两排：系统标题栏那三颗，外加
            // 内容里自己画的三颗 —— 同一个角上两套「关 / 缩 / 放」。他的定论是
            // 「保留系统自带的，不要你生成的」，自绘那套当天就撤掉了。
            //
            // 两条都要读回来验，光看代码里那个 `if` 证明不了屏幕上是什么样：
            // 一条查画的那排**不在这扇窗的内容里**（读像素），一条查系统那排
            // **在**（读窗口自己的按钮）。这一档是在客户/调试那台真机上跑的
            // （诊断包里就有它），和出图机不是同一台，两条路各验各的。
            if let shot = bitmap(of: window), let view = window.contentView {
                check("窗口内容里没有第二排按钮（画的那三颗不在这扇窗上）",
                      trafficLights(in: (shot, view.bounds.size, 2)) == nil)
            }
            let systemLights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            check("系统标题栏那三颗都在（读到 \(systemLights.count) 颗，"
                  + "\(systemLights.filter { !$0.isHidden }.count) 颗露着）",
                  systemLights.count == 3 && systemLights.allSatisfy { !$0.isHidden })
            // 缩小到 Dock 之后再抬一次。
            //
            // 客户点名要了系统那三颗按钮（「保留系统自带的」），黄的那颗就是
            // 缩小到 Dock。真按下去之后，再点「拨号」/「设置」，窗口得从 Dock
            // 里回到屏幕上 —— 而 `makeKeyAndOrderFront` 一个人办不到这件事。
            // 这一条是**读回来**验的：真缩一次、抬一次、再看窗口自己的
            // `isMiniaturized`，不是看代码里有没有那句 `deminiaturize`。
            window.miniaturize(nil)
            pump(1.0)
            if window.isMiniaturized {
                AppActivation.bring(window)
                pump(1.0)
                check("缩进 Dock 的窗口，再抬一次能回到屏幕上",
                      !window.isMiniaturized && window.isVisible)
            } else {
                print("  ·这台机器缩不进 Dock，这一段跳过")
            }

            // 跑到屏幕外的窗口（客户拔掉外接屏那种）抬一次，得回到可见区。
            // 坐标落在不存在的区域时，窗口「开了、在前台、屏幕上看不见」，
            // 客户能说的只有「打不开」。
            let parked = window.frame
            window.setFrameOrigin(NSPoint(x: parked.maxX + 3000, y: parked.minY))
            pump(0.3)
            AppActivation.bring(window)
            pump(0.3)
            if let area = (window.screen ?? NSScreen.main)?.visibleFrame {
                check("窗口跑到屏幕外时，抬一次能拉回可见区",
                      area.intersects(window.frame))
            }
            window.setFrame(parked, display: false)
            pump(0.2)

            if let directory {
                // 连系统标题栏一起画进去：客户 2026-09-29 挑出来的毛病就在
                // 那一角（「三个颜色按钮不是系统的吧」），报告里那张图得看得见
                // 它，不然下一轮还是靠猜。
                save(window: window, named: "面板窗口-屏幕实拍.png", to: directory,
                     includingChrome: true)
            }
        }

        print(failures == 0 ? "PANELCHECK ok" : "PANELCHECK fail=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    /// 把卡片此刻的样子存下来 —— 这是它盖在客户屏幕上的那一副面孔，不是
    /// `RingCard` 另外画的一份。
    private static func save(card: NSWindow, to directory: URL) {
        save(window: card, named: "来电卡片-屏幕实拍.png", to: directory)
    }

    /// 照着一个**真窗口**画一张，而不是重新渲染一遍视图：客户看到的那一副
    /// 面孔和报告里带回去的必须是同一副，否则这张图证明不了什么。
    private static func save(window: NSWindow, named name: String, to directory: URL,
                             includingChrome: Bool = false) {
        guard let bitmap = bitmap(of: window, includingChrome: includingChrome),
              let view = (includingChrome ? (window.contentView?.superview ?? window.contentView)
                                          : window.contentView) else { return }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(name))
        print("  \(name)  \(Int(view.bounds.width * 2))×\(Int(view.bounds.height * 2))")
    }

    /// 照着一个**真窗口**画一张位图。出图和读像素走同一条，见
    /// `checkPanelWindow` 里那两条关于三颗点的检查。
    ///
    /// `includingChrome` 为真时，画的是窗外那一层（`NSThemeFrame`，系统标题栏
    /// 连同红黄绿三颗都在里面），不然只画内容 —— 读像素找「有没有自绘的第二排」
    /// 时只该看内容，给客户看的图则要连标题栏一起。
    private static func bitmap(of window: NSWindow, scale: CGFloat = 2,
                               includingChrome: Bool = false) -> NSBitmapImageRep? {
        let root = includingChrome ? (window.contentView?.superview ?? window.contentView)
                                   : window.contentView
        guard let view = root, view.bounds.width > 1 else { return nil }
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * scale),
            pixelsHigh: Int(view.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// 在卡片上按下其中一颗按钮。
    ///
    /// 先走辅助功能 —— 那是旁白和自动化点它时走的同一条路；取不到就退回按
    /// 卡片自己的布局算坐标。两条都是真鼠标事件：按错了不会静默通过，下面的
    /// 通话状态断言会亮红。
    private static func pressCardButton(named title: String, in card: NSWindow) -> Bool {
        if let button = accessibilityButton(named: title, in: card.contentView) {
            if button.accessibilityPerformPress() {
                print("  ·「\(title)」走辅助功能按下")
                return true
            }
            // 找到了却按不动：这条路是给旁白走的，走不通就说明它只有一层
            // 空壳，别把红字算在按钮头上。
            print("  ·「\(title)」在辅助功能里找到了，但 AXPress 没成功")
        } else {
            print("  ·「\(title)」不在辅助功能的按钮里，改按坐标点")
        }
        return clickCardButton(named: title, in: card)
    }

    private static func accessibilityButton(named title: String,
                                            in view: NSView?) -> NSAccessibilityProtocol? {
        guard let view else { return nil }
        func search(_ node: NSAccessibilityProtocol, _ depth: Int) -> NSAccessibilityProtocol? {
            if depth > 10 { return nil }
            if node.accessibilityRole() == .button,
               (node.accessibilityLabel() ?? "") == title {
                return node
            }
            for child in node.accessibilityChildren() ?? [] {
                if let next = child as? NSAccessibilityProtocol,
                   let found = search(next, depth + 1) {
                    return found
                }
            }
            return nil
        }
        return search(view, 0)
    }

    /// 按卡片自己的布局算坐标点下去。
    ///
    /// 数字来自 `RingCard`／`CardButton` 里写死的那几个内边距：外面 8、卡片
    /// 里 14、两颗按钮等分中间留 8。这里是兜底，只在辅助功能那条路取不到时
    /// 走；它算错的结果是「点了没反应」，下面那条状态断言照样会亮红。
    private static func clickCardButton(named title: String, in card: NSWindow) -> Bool {
        let frame = card.frame
        guard frame.width > 200, frame.height > 60 else { return false }
        let inset: CGFloat = 22          // 8（外层）+ 14（卡片）
        let gap: CGFloat = 8
        let inner = frame.width - inset * 2
        guard inner > gap else { return false }
        let buttonWidth = (inner - gap) / 2
        let centerX: CGFloat
        switch title {
        case "接听": centerX = inset + buttonWidth / 2
        case "拒接": centerX = inset + buttonWidth + gap + buttonWidth / 2
        default: return false
        }
        // 按钮是卡片里的最后一行，它自己的高度是 8 + 一行 11pt 字 + 8。
        let centerY = frame.origin.y + inset + 15
        // 两个坐标系差一个 Y 轴方向：卡片报的是 AppKit 的左下原点，`CGEvent`
        // 要的是主屏左上原点。第一版漏了这一步，点在屏幕另一头 —— 卡片本身
        // 全对，按钮却永远按不响。
        let flip = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        let point = CGPoint(x: frame.origin.x + centerX, y: flip - centerY)
        print("  ·「\(title)」按布局点击 \(Int(point.x)),\(Int(point.y))")
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(80_000)
        }
        if let landed = cgCursorLocation() {
            // 落点对不上就说明还有第三个坐标系掺在里面，把差值一起打出来。
            print("  ·鼠标落在 \(Int(landed.x)),\(Int(landed.y))"
                  + (abs(landed.x - point.x) < 1.5 && abs(landed.y - point.y) < 1.5
                     ? "" : "（期望 \(Int(point.x)),\(Int(point.y))）"))
        }
        return true
    }

    /// 光标此刻的位置，换成 `CGEvent` 那套左上原点的坐标。
    ///
    /// 用 `NSEvent.mouseLocation` 而不是 `CGEvent(source:)`：后者造出来的是一
    /// 个新事件，位置字段没意义，读回来只会是 0,0，看着像点歪了。
    private static func cgCursorLocation() -> CGPoint? {
        let flip = NSScreen.screens.first?.frame.maxY ?? 0
        guard flip > 0 else { return nil }
        let point = NSEvent.mouseLocation
        return CGPoint(x: point.x, y: flip - point.y)
    }

    /// 把光标放回原处 —— 自检借客户的鼠标走了一圈，用完得还。
    private static func restoreCursor(to point: CGPoint?) {
        guard let point else { return }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// Runs the run loop until the model reaches the expected state.
    ///
    /// The simulator hands its events to the same background poll thread the
    /// live app uses, so "how long" is a property of the machine rather than of
    /// the code. Each of these has a deadline; none of them has a duration.
    ///
    /// The deadline is generous because this also runs on a machine that is
    /// mid-build or mid-index: eight seconds was enough to fail on a busy disk
    /// and say nothing about why. `line` comes from the call site — Swift
    /// evaluates default arguments there — so a wait that runs out of time
    /// names itself and prints what it was staring at, instead of leaving a
    /// bare 「没有回调」 to be puzzled over a week later.
    /// How many pixels of an image actually carry ink.
    ///
    /// A menu bar label can be present, sized correctly, and still blank:
    /// `MenuBarExtra` only composites `Text` and `Image`, so anything the label
    /// draws for itself is dropped whole. Counting painted pixels is the only
    /// way to tell that apart from a label that simply has a dark background.
    private static func ink(_ image: NSImage) -> Int {
        guard let data = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: data) else { return -1 }
        var painted = 0
        for y in 0..<representation.pixelsHigh {
            for x in 0..<representation.pixelsWide
            where (representation.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                painted += 1
            }
        }
        return painted
    }

    private static func waitUntil(_ model: AppModel, timeout: TimeInterval = 25,
                                  line: Int = #line, _ reached: (AppModel) -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !reached(model), Date() < deadline { pump(0.05) }
        if !reached(model) {
            print("  \u{23F1} 等待超时 \(Int(timeout))s（Render.swift:\(line)）"
                  + " 通话=\(model.call.state.label) 短信=\(model.messages.count)"
                  + " 忙=\(model.isWorking) 错=\(model.lastError ?? "无")")
        }
    }

    /// Blocks until no action is in flight.
    ///
    /// `run` hands each action to a background queue, so a method like
    /// `refreshAll()` returns long before its AT traffic has been applied to
    /// the model. Anything the harness seeds has to wait for that to settle.
    /// 夹具里按下数据开关，并要求它真的按下去了。
    ///
    /// `setDataEnabled` 会被「上一步操作还没结束」挡回来 —— 启动时那一次
    /// `refreshAll` 就挡得住它，而挡回来时开关不翻、面板也不说为什么。截下来
    /// 的那一帧于是写着 `4G OFF` 却连着一个已启用的网络服务，看起来像面板坏
    /// 了。这些图是拿来逐像素比对的，必须确定。
    private static func pressDataSwitch(_ model: AppModel, _ enabled: Bool) {
        pumpUntilIdle(model)
        model.setDataEnabled(enabled)
        pump(0.4)
        guard model.dataWanted == enabled else {
            let want = enabled ? "开" : "关"
            let why = model.lastError ?? "没有报错"
            FileHandle.standardError.write(Data("渲染夹具：数据开关没按到\(want)（\(why)）\n".utf8))
            exit(1)
        }
        // 等 App 自己这一步活干完就够，**不等** `isRoutable`。
        //
        // 真机上按下去之后还有一跳：网络服务要由后台的 `networksetup` 打开
        // （见 `ensureHostService()`），`dataWanted` 落得比它早。可这一跳在出图
        // 夹具里永远不会发生 —— 网卡、地址、服务名都是**这台机器上的事实**，
        // 夹具在按完开关之后才用 `seedHostLink` 把它们说进去（见各处调用）。
        // 原来这里等满十秒，等到的只是一条看着像失败的「等待超时」，图还是照
        // 画不误。图上那盏灯由种子说了算，跟这一等没有关系。
        guard enabled else { return }
        pumpUntilIdle(model)
    }

    private static func pumpUntilIdle(_ model: AppModel, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while model.isWorking, Date() < deadline { pump(0.05) }
        // One extra turn so the completion hop back to the main queue lands.
        pump(0.1)
    }

    /// Runs the main run loop for a while so the controller's background
    /// threads can deliver their events — the same path the live app uses.
    private static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            drainEvents()
        }
    }

    /// 手泵 RunLoop 只跑定时器：排给 AppKit 的鼠标和激活事件躺在队列里没人取。
    /// 真身跑的是 `NSApp.run()`，取事件的活儿是它干的；自检这条路得自己取一遍
    /// 再发下去，否则「点卡片按钮」这类检查永远等不到事件 —— 而且看起来像是
    /// 按钮画错了。
    private static func drainEvents() {
        guard let app = NSApp else { return }
        while let event = app.nextEvent(matching: .any,
                                        until: Date().addingTimeInterval(0.001),
                                        inMode: .default,
                                        dequeue: true) {
            app.sendEvent(event)
        }
    }

    /// A day of traffic: a quiet night, a working-hours hump, and enough ripple
    /// that the sparkline is not a smooth hill.
    private static var trafficShape: [Double] {
        (0..<48).map { index in
            let phase = Double(index) / 47
            let hump = exp(-pow((phase - 0.62) * 3.1, 2))
            let ripple = 0.35 + 0.65 * abs(sin(Double(index) * 0.9))
            return hump * ripple * 18_000_000
        }
    }

    private static func render<V: View>(_ view: V, _ name: String,
                                        width: CGFloat, to directory: URL) {
        guard let shot = snapshot(view, width: width) else {
            FileHandle.standardError.write(Data("位图分配失败：\(name)\n".utf8))
            return
        }
        guard let data = shot.image.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("编码失败：\(name)\n".utf8))
            return
        }
        try? data.write(to: directory.appendingPathComponent("\(name).png"))
        print("\(name).png  \(Int(shot.size.width * shot.scale))×\(Int(shot.size.height * shot.scale))")
    }

    /// 画一张离屏的图，把位图交回来。
    ///
    /// `render` 和 `checkPanelChrome` 共用这一条：一个把位图写成 PNG 给人看，
    /// 一个在位图里数像素。数的那张必须是画的同一张 —— 换一条路再画一遍，
    /// 「图上有点」这句话就证明不了屏幕上有点。
    private static func snapshot<V: View>(_ view: V, width: CGFloat)
        -> (image: NSBitmapImageRep, size: NSSize, scale: CGFloat)? {
        // `ImageRenderer` is not enough here: it cannot draw the AppKit-backed
        // pieces SwiftUI builds on (TextEditor, ScrollView, List), and silently
        // substitutes a yellow "unsupported" bar. Hosting the view in a real
        // window and caching its display goes through the same drawing path the
        // app uses on screen.
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        hosting.layoutSubtreeIfNeeded()
        let height = max(hosting.fittingSize.height.rounded(.up), 1)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

        // A borderless window parked far off-screen: AppKit views only draw
        // once they belong to a window, and this one is never ordered front.
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        // Wallpapers and posters need more pixels than a screenshot review does,
        // so the multiplier is overridable without a rebuild.
        let scale: CGFloat = ProcessInfo.processInfo.environment["DJI4G_RENDER_SCALE"]
            .flatMap(Double.init).map { CGFloat($0) } ?? 2
        defer { window.contentView = nil }
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = NSSize(width: width, height: height)
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return (bitmap, NSSize(width: width, height: height), scale)
    }
}
