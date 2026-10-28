import SwiftUI
import AppKit
import DJI4GCore

/// SwiftPM builds a bare executable, so the "menu bar only, no Dock icon"
/// behaviour normally provided by `LSUIElement` is set here instead.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// 走到这里说明这次运行是自己收的尾。`AppLog` 靠这个把「正常退出」和
    /// 「崩溃 / 被强退」分开 —— 客户下次说「刚才还好好的突然没了」的时候，
    /// 日志里得有一句话能回答他。
    func applicationWillTerminate(_ notification: Notification) {
        AppLog.markCleanExit("正常退出")
    }

    /// 客户又双击了一下 App 图标（或者用 `open -a`）时走这里。
    ///
    /// 这个 App 平时没有窗口，于是「重新打开」本来什么都不会发生：客户双击
    /// 完，屏幕上纹丝不动 —— 和他抱怨的「面板不弹」是同一个观感。所以这里
    /// 把面板铺成一个真正的窗口，这是他手上那条不经过菜单栏的后路。
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        PanelWindowRequest.shared.request(reason: "重新打开 App（双击了图标）")
        return true
    }
}

@main
struct DJI4GApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel

    /// `--render <dir>` draws every screen offscreen and exits. Hooking it here
    /// rather than in a `main.swift` keeps the whole thing on the main actor and
    /// leaves the normal launch path untouched.
    ///
    /// `--sim` / `--sim-nosim` do the same swap for the interactive app: the
    /// menu bar item is real, the module behind it is not.
    // MARK: - 旗标

    /// 这个 App 认得的全部长旗标。
    ///
    /// 加新旗标时**必须**同时加到这里，否则它会被下面那道闸门当成写错、直接
    /// 退出。这一点是故意的：漏加的话一跑就看得出来，比反过来（悄悄多起一个
    /// 图标）好得多。
    private static let knownFlags: Set<String> = [
        // 无头
        "--render", "--sim-check", "--ring-check", "--panel-window-check",
        "--call-audio-check",
        // 交互式演示
        "--sim", "--sim-nosim",
        // 只跟着 --render 用的状态开关
        "--nosim", "--nomodule", "--hardware", "--dataoff",
        "--storagefull", "--longsms", "--smsopen", "--notifyblocked", "--phoneaudio",
        "--fresh", "--micdenied", "--micunasked",
        "--panelchrome",
        // 用法
        "--help", "-h",
    ]

    /// 这些旗标只在 `--render` 那一趟里有活干：它们各自表示一种「画哪一档」
    /// 或者「顺手核一遍哪张图」，`RenderHarness.run()` 是唯一读它们的地方。
    ///
    /// 单跑其中一个等于什么都没要求 —— 而 `--panelchrome` 又在 `headless`
    /// 那张表里，于是单跑它会**跳过单实例那道闸**、掉进正常启动，菜单栏上
    /// 并排多出一个一模一样的 4G 图标。2026-09-29 复现过一次：本机已经装着
    /// 常驻的那一份，再敲一次 `DJI4GMenuBar --panelchrome`，两个图标都在，
    /// 两个都能点开 —— 客户 09-26 报的「有两个 4g 图标」就是同一个观感。
    ///
    /// 所以这一组不许单跑：少了 `--render` 就在闸门那里停住，和写错旗标
    /// 同样处理。开发时敲错一个字，看到的是用法说明，不是第二个图标。
    private static let renderSubFlags: Set<String> = [
        "--nosim", "--nomodule", "--hardware", "--dataoff",
        "--storagefull", "--longsms", "--smsopen", "--notifyblocked", "--phoneaudio",
        "--fresh", "--micdenied", "--micunasked",
        "--panelchrome",
    ]

    private static let usageText = """
    用法：DJI4GMenuBar [旗标]

    不带旗标就是正常启动：菜单栏出一个 4G 图标，点开是面板。

      --help, -h                就是这份说明

      --render <输出目录>       把每一屏离屏画成 PNG 再退出，用来核对版面
          --nosim               画「插了模块但没插卡」那一档
          --nomodule            画「没插模块」那一档
          --hardware            画硬件详情那一档
          --dataoff             画「数据开关关掉」那一档
          --storagefull         画「套餐用满」那一档
          --longsms             画「长短信拼接」那一档
          --smsopen             画「点开一条短信」那一档（白卡 + 回复按钮）
          --notifyblocked       画「通知被系统挡住」那一档
          --micdenied           画「麦克风没打开」那一档（面板条 + 通话窗）
          --micunasked          画「麦克风还一次没问过」那一档
          --phoneaudio          画「为插 iPhone / iPad 把模块声卡关掉」那一档
          --fresh               画「模块刚拿到手、两样都还没开」那一档
                                （安装图解第 2、3 步用的是它）
          --panelchrome         画「摊开的面板」和「缩成一条」，并数像素核对
                                （顺带核对：面板内容里没有自绘的红黄绿三颗点）

    上面这一组（--nosim … --panelchrome）都要跟在 --render 后面；
    单跑会直接退出——它们自己不会起界面，单跑只会在菜单栏多出一个图标。

      --sim-check               界面自检（122 项）
      --ring-check [目录]       把来电卡片铺到屏幕上验一次，可顺手存图
      --call-audio-check        通话声音判据自检（不接硬件）
      --panel-window-check [目录]
                                只验「双击图标把面板铺成窗口」这条路

      --sim                     用模拟模块跑交互界面（机器上没模块时看效果）
      --sim-nosim               同上，模拟「没插卡」
    """

    /// 旗标写错了就到此为止。
    ///
    /// 2026-09-26：`--help` 之前会**把整个图形界面起起来** —— 菜单栏上因此
    /// 多出一个一模一样的 4G 图标，客户分不出该点哪个（和 09-25 那次「两份
    /// 实例」是同一个观感）。根因是启动时只问「有没有某个无头旗标」，从不问
    /// 「给的这个旗标认不认识」，于是任何拼错的长参数都等于「正常启动」。
    ///
    /// 只拦 `--` 打头的：Finder 在某些情况下会捎带 `-psn_0_12345` 这类单横线
    /// 参数，把它当错误会让双击图标直接打不开 —— 那比现状更糟。
    private static func rejectUnknownFlags() {
        let given = CommandLine.arguments.dropFirst()
        if given.contains("--help") || given.contains("-h") {
            print(usageText)
            exit(0)
        }
        // 只跟着 `--render` 用的那几个，单跑就是走错路（见 `renderSubFlags`）。
        // 先拦这一条再拦「认不出」：这两个集合不相交，但先问具体的那条，
        // 报出来的话才直接说得出缺什么。
        if !given.contains("--render"), let orphan = given.first(where: renderSubFlags.contains) {
            FileHandle.standardError.write(Data("""
            \(orphan) 要跟着 --render <输出目录> 一起用

            \(usageText)

            """.utf8))
            exit(2)
        }
        let unknown = given.filter { $0.hasPrefix("--") && !knownFlags.contains($0) }
        guard !unknown.isEmpty else { return }
        FileHandle.standardError.write(Data("""
        认不出这些旗标：\(unknown.joined(separator: " "))

        \(usageText)

        """.utf8))
        exit(2)
    }

    init() {
        // 无头路径不该往日志里写字：它们的输出要能逐字节比对，多一行时间戳
        // 就比对不了。正常启动（含 --sim 演示）才开。
        //
        // `--panel-window-check` 也在这里面，而且是两件事都要豁免：诊断脚本
        // 会在 App 正跑着的时候调它，把「App 已经在跑」当成「别跑了」会把
        // 诊断本身挡掉；它自己那份 AppLog 也会在客户的日志里留下一次假的
        // 「没有正常收尾」。
        // 先过闸门：旗标写错的不许往下走，否则就是第二个 4G 图标。
        Self.rejectUnknownFlags()
        let headless = ["--render", "--sim-check", "--ring-check", "--panel-window-check",
                        "--call-audio-check", "--panelchrome"]
            .contains { CommandLine.arguments.contains($0) }
        // 客户双击第二下起的那一份，在这里就退掉（还没碰模块、还没画图标）。
        if !headless { SingleInstance.yieldToRunningInstance() }
        if !headless { AppLog.install() }
        if !headless { PanelWindowRequest.shared.startListening() }
        // 和日志同一档：无头路径不该申请这张票据（它们几秒就退，节流也够用），
        // 正常启动才持 —— 平时没有窗口，不持有就会被系统按 App Nap 掐。
        if !headless { AppNap.hold() }

        if CommandLine.arguments.contains("--render") {
            RenderHarness.run()
        }
        if CommandLine.arguments.contains("--sim-check") {
            RenderHarness.checkSimulator()
        }
        // 纯函数那一档：判据的每一种边界都跑一遍，不碰模块、不碰声卡。
        if CommandLine.arguments.contains("--call-audio-check") {
            RenderHarness.checkCallAudio()
        }
        // 单独一档：这一条会真的把来电卡片铺到屏幕上（它验的就是这个），所以
        // 不能混在无头的 --sim-check 里跑。带目录时顺手把卡片存成图。
        if let flag = CommandLine.arguments.firstIndex(of: "--ring-check") {
            let directory = CommandLine.arguments.count > flag + 1
                ? URL(fileURLWithPath: CommandLine.arguments[flag + 1])
                : nil
            RenderHarness.checkRingCard(to: directory)
        }
        // 后路那一档只为看窗口，不该去碰客户的模块（诊断时模块多半正被 App
        // 占着，读它只会多出一条红字）。
        if let flag = CommandLine.arguments.firstIndex(of: "--panel-window-check") {
            let directory = CommandLine.arguments.count > flag + 1
                && !CommandLine.arguments[flag + 1].hasPrefix("--")
                ? URL(fileURLWithPath: CommandLine.arguments[flag + 1])
                : nil
            RenderHarness.schedulePanelWindowCheck(to: directory)
            _model = StateObject(wrappedValue: AppModel.launch(
                arguments: ["DJI4GMenuBar", "--sim"], announce: false))
        } else {
            _model = StateObject(wrappedValue: AppModel.launch())
        }
    }

    var body: some Scene {
        MenuBarExtra {
            // 下拉本身什么都不画。它是**桥**，不是面板 —— 见 `PanelBridge`。
            PanelBridge()
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("DJI 4G 通话", id: WindowID.call) {
            CallWindow().environmentObject(model).bringsWindowToFront(WindowID.call)
        }
        .windowResizability(.contentSize)

        Window("DJI 4G 设置", id: WindowID.setup) {
            SetupWindow().environmentObject(model).bringsWindowToFront(WindowID.setup)
        }
        .windowResizability(.contentSize)

        Window("DJI 4G 网络诊断", id: WindowID.netdiag) {
            NetDiagWindow().bringsWindowToFront(WindowID.netdiag)
        }
        .windowResizability(.contentSize)

        // 面板的「后路副本」：同一个 `PanelView`，但挂在一个真正的窗口上。
        //
        // 客户那台机器上面板弹不出来时，菜单栏里那条路就断了；这条不断 ——
        // 双击 App 图标就会走到这里（见 `AppDelegate.applicationShouldHandleReopen`
        // 和 `SingleInstance`）。两处共用同一个 `PanelView`，所以「面板是什么
        // 样」永远只有一份答案。
        Window("DJI 4G 面板", id: WindowID.panel) {
            PanelWindowRoot().environmentObject(model)
                // 这扇窗的标题栏连同那三颗交通灯都是系统给的（2026-09-29
                // 客户定论：保留系统自带的，不要自绘的）。标题栏那一条只有
                // 二十几点高，客户挪窗口时多半直接按在内容上 —— 整块可拖就是
                // 他那天提的那句「把这个窗口改成可拖动的，随意移动位置」。
                // 通话窗和设置窗**不**要：那两扇里要选字、拉滑杆，整块可拖
                // 会把窗口蹭走。
                .bringsWindowToFront(WindowID.panel, movableByBackground: true)
        }
        .windowResizability(.contentSize)
    }
}

enum WindowID {
    static let call = "dji4g.call"
    static let setup = "dji4g.setup"
    static let panel = "dji4g.panel"
    static let netdiag = "dji4g.netdiag"
}

/// 独立面板窗口的内容。
///
/// 比菜单栏下拉多出来的只有一件事：**把这个 App 拎到前台**。它没有 Dock
/// 图标，不显式激活的话窗口会开在客户正在用的那个窗口后面 —— 他双击了图标，
/// 屏幕上什么都没变，看起来和「面板不弹」是同一个毛病。
private struct PanelWindowRoot: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // 关这扇窗走系统标题栏最左边那颗红按钮（2026-09-29 起不再自己画），
        // 关完 App 照样在菜单栏那一格上，点图标或者双击 App 随时再开。
        PanelView()
            .environmentObject(model)
            // 和来电卡片同一句：菜单栏 App 平时不抢前台，这一下是为了
            // 让客户真的看见它。
            .onAppear { AppActivation.activate() }
    }
}

/// 把这个 App 拎到前台。
///
/// 它是菜单栏程序（没有 Dock 图标，`AppDelegate` 里设的 `.accessory`），
/// 系统默认不让它抢前台。于是新开的窗口会落在客户正在用的那个窗口**后面**：
/// 他点了「通话」或者「设置」，屏幕上什么都没变，得先把别的窗口挪开才看得见
/// —— 和「点了没反应」是同一个观感。
///
/// 2026-09-27：这个动作原来只做在面板后路那一处，通话窗和设置窗漏了。现在
/// 收进一处，三条窗口共用。
@MainActor
enum AppActivation {
    static func activate() {
        // 藏起来的 App 不先放出来，`activate` 只是把它标成「当前」，屏幕上
        // 一片都不会变 —— 客户换个说法就是「点了没反应」。
        if NSApp.isHidden { NSApp.unhide(nil) }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    static func bring(_ window: NSWindow, movableByBackground: Bool = false) {
        activate()
        if movableByBackground { makeDraggableByBackground(window) }
        // 缩到 Dock 里的窗口，`makeKeyAndOrderFront` 抬不出来。
        //
        // 客户 2026-09-29 点名要了系统那三颗红黄绿（「保留系统自带的」），
        // 黄色那颗就是缩小到 Dock。真按下去之后，再点「拨号」/「设置」，
        // 窗口得从 Dock 里回到屏幕上 —— 不然它只在 Dock 里亮一下，屏幕上
        // 什么都不变，又是一次「点了没反应」。
        if window.isMiniaturized { window.deminiaturize(nil) }
        pullBackOnScreen(window)
        window.makeKeyAndOrderFront(nil)
    }

    /// 把落在屏幕外的窗口拉回可见区。
    ///
    /// 窗口的坐标是记着的：客户把它拖到外接屏上，拔掉那台屏；或者把分辨率
    /// 一换 —— 原来的坐标就落在了一块不存在的区域里。这种情况下窗口确实开
    /// 了、确实在前台，屏幕上就是没有它。客户能说的只有「打不开」。
    ///
    /// 判据是「有没有压着任意一块屏的可见区」：只要还压着一个角就不动它，
    /// 客户自己摆的位置永远优先。
    static func pullBackOnScreen(_ window: NSWindow) {
        let frame = window.frame
        let screens = NSScreen.screens
        if screens.contains(where: { $0.visibleFrame.intersects(frame) }) { return }
        guard let target = NSScreen.main ?? screens.first else { return }
        let area = target.visibleFrame
        var origin = frame.origin
        origin.x = min(max(origin.x, area.minX), max(area.maxX - frame.width, area.minX))
        origin.y = min(max(origin.y, area.minY), max(area.maxY - frame.height, area.minY))
        window.setFrameOrigin(origin)
        AppLog.log("窗口跑到屏幕外了，拉回可见区")
    }

    /// 把某一扇**已经开着**的窗口抬到最前面。
    ///
    /// `openWindow(id:)` 对没开过的那扇管用，对已经开着的那扇却不一定重新抬
    /// 一次 —— 客户 2026-09-29 报的就是这一条：「拨打窗口要默认点开跳到前面
    /// 才行」。窗口在落位那一刻登记过（见 `WindowRegistry`），这里按名字把它
    /// 找回来再抬一手。
    ///
    /// 找不着就什么都不做：那种情况窗口是刚建的，它自己那一手 `bring`
    /// （`BringWindowToFront`）会兜住。
    static func raise(_ id: String) {
        for delay in raiseDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [delay] in
                guard let window = WindowRegistry.window(id) else { return }
                // 第二手才抬到前面，说明第一手落在了「下拉还没收完」那一拍里
                // —— 记一行，客户下次说「点了没反应」时能对得上时间。
                if delay > 0 { AppLog.log("窗口补抬到最前面：\(name(of: id))") }
                bring(window)
            }
        }
    }

    /// 抬几手、各隔多久。
    ///
    /// 一手不够，是 2026-09-29 客户那句「我点完拨打，主页面就缩回」量出来的：
    ///
    /// ① `openWindow` 之后那扇窗是 SwiftUI **下一拍**才建的，建窗时
    ///    `BringWindowToFront` 会抬一次（见那里）；
    /// ② 可客户是在菜单栏下拉里按的「拨号」，而收那块下拉的动作本身也排在
    ///    队上 —— `PanelDismiss.menuBarExtra` 那一按排在 +0.18 秒；
    /// ③ 两件事一撞：窗口刚被摆到前面，下拉收完，系统顺手把前台还给上一个
    ///    App，窗口就落到它后面去了。
    ///
    /// 结果客户看到的是「面板收走了，通话窗没在眼前」—— 和「点了没反应」是
    /// 同一个观感。多抬一手没有代价（窗口已经在前台时这一手是空动作），少抬
    /// 一手客户就得自己去别的窗口底下把它翻出来。
    private static let raiseDelays: [Double] = [0, 0.3]

    /// 这几个窗口在日志里叫什么。写标题比写内部编号有用。
    static func name(of id: String) -> String {
        switch id {
        case WindowID.call: return "通话"
        case WindowID.setup: return "设置"
        case WindowID.panel: return "面板"
        default: return id
        }
    }

    /// 让窗口**整块**都能拖，而不是只有标题栏那一小条。
    ///
    /// 2026-09-29 客户提的：「把这个窗口改成可拖动的，随意移动位置」。面板
    /// 窗口上能按住的地方几乎全是内容，标题栏只有二十几点高 —— 客户想挪它，
    /// 十有八九按在内容上，拖不动就当这窗口是挪不了的。来电卡片从一开始就是
    /// 这么干的（`RingAlert.makePanel` 里那一句），这里和它对齐。
    ///
    /// 只给面板开，别顺手三个窗口都开：通话窗和设置窗有系统标题栏，拖那儿
    /// 是客户已经会的动作；整块可拖反而会让他在选字、拉滑杆的时候把窗口
    /// 蹭走，那是新毛病。
    static func makeDraggableByBackground(_ window: NSWindow) {
        window.isMovableByWindowBackground = true
    }
}

/// 这扇窗是哪一扇：`WindowID` 那三个名字到 `NSWindow` 的一本账。
///
/// 为什么要记：客户第二次点「拨号」时，窗口已经开着了，`openWindow(id:)` 不
/// 保证把它重新抬起来（见 `AppActivation.raise`）。要抬它，就得先知道它是
/// 哪一扇 —— `BringWindowToFront` 在窗口落位那一拍把它登记进来。
///
/// 存的是弱引用：窗口关掉之后 SwiftUI 会把 `NSWindow` 释放，这一条自己变成
/// nil，不用谁去清理。也不去动 `window.identifier` —— 那是 SwiftUI 自己的
/// 地盘，借来当便签，哪天就会跟它撞上。
@MainActor
enum WindowRegistry {
    private static var windows: [String: WeakWindow] = [:]

    private final class WeakWindow {
        weak var value: NSWindow?
        init(_ window: NSWindow) { value = window }
    }

    static func register(_ window: NSWindow, as id: String) {
        windows[id] = WeakWindow(window)
    }

    static func window(_ id: String) -> NSWindow? {
        windows[id]?.value
    }
}

/// 挂进窗口内容里，让这个窗口出现时走到最前面。
///
/// 光在按按钮那一拍激活 App 还不够：窗口是 SwiftUI 随后才建出来的，建出来
/// 的时候如果没被摆到前面，它照样躲在别人的窗口后面。这里盯的是
/// `viewDidMoveToWindow` —— 视图真的拿到窗口的第一拍，隔一拍（`async`）再动，
/// 等 SwiftUI 把窗口摆好、编号定下来。
private struct BringWindowToFront: NSViewRepresentable {
    /// 这扇窗是哪一扇（`WindowID` 里那几个）。落位那一刻按这个名字登记进
    /// `WindowRegistry`：第二次点「拨号」时，靠它把已经开着的那扇找回来。
    var id: String
    /// 见 `AppActivation.makeDraggableByBackground`：默认不整块可拖，只有
    /// 面板窗口那份传 `true`。
    var movableByBackground: Bool = false

    func makeNSView(context: Context) -> NSView {
        FrontView(id: id, movableByBackground: movableByBackground)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? FrontView else { return }
        view.movableByBackground = movableByBackground
        // 视图已经挂上窗口了就顺手再落一手：SwiftUI 之后还会重排、重建好几轮，
        // 「整块可拖」是窗口自己的属性，多设一次没有任何代价。
        if movableByBackground, let window = view.window {
            AppActivation.makeDraggableByBackground(window)
        }
    }

    private final class FrontView: NSView {
        var movableByBackground: Bool
        private let id: String

        init(id: String, movableByBackground: Bool) {
            self.id = id
            self.movableByBackground = movableByBackground
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("这个视图不从 nib 来") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // 身份牌当场挂：客户第二次点「拨号」时要用它把这扇窗找回来
            // （见 `WindowRegistry`、`AppActivation.raise`）。
            WindowRegistry.register(window, as: id)
            // 「整块可拖」当场落，不排给下一拍。
            //
            // 原来这一句和下面那句一起排在 `DispatchQueue.main.async` 里，在自检
            // 那条路（`pump` 手摇 RunLoop）上就永远不跑 —— 主队列不会在自己排
            // 的块里被再抽一次，于是 `--panel-window-check` 报「拖不动」，
            // 而真机上到底行不行谁也说不准。窗口属性不依赖 SwiftUI 摆位，
            // 早设这一拍没有任何代价。
            if movableByBackground { AppActivation.makeDraggableByBackground(window) }
            // 拎到前台那句要等 SwiftUI 把窗口摆好、编号定下来，仍排在下一拍。
            DispatchQueue.main.async {
                AppActivation.bring(window, movableByBackground: self.movableByBackground)
            }
        }
    }
}

extension View {
    /// 让所在的窗口出现时走到最前面（见 `BringWindowToFront`）。
    ///
    /// 只挂在 `Window` 那一层：截图那条路是直接画 `CallWindow` / `SetupWindow`，
    /// 不经过这里，离屏出图的像素一个都不受影响。
    ///
    /// `movableByBackground` 只给面板窗口开，理由写在
    /// `AppActivation.makeDraggableByBackground` 上。
    func bringsWindowToFront(_ id: String, movableByBackground: Bool = false) -> some View {
        background(BringWindowToFront(id: id, movableByBackground: movableByBackground)
            .frame(width: 0, height: 0))
    }
}

/// 菜单栏下拉里那一块 —— 它自己不显示任何东西，只负责把真窗口叫出来。
///
/// 为什么还留着一个下拉：`openWindow` 这个动作只有活在 SwiftUI 场景里的视图
/// 拿得到，而 `MenuBarExtra` 的 label 是唯一一份从启动到退出一直在的视图
/// （面板窗口、通话窗口、设置窗口都是点开才存在）。下拉一露面，这里就发一次
/// `PanelWindowRequest` —— 和双击 App 图标走的是同一个信号 —— 再把下拉收回去。
/// 客户看到的是「点一下图标，窗口出来了」。
///
/// 块本身只有 2×2 且全透明：它展开的那一下不该被看见。要等 0.25 秒才收，是
/// 因为收下拉那一下按的是系统的开关（`PanelDismiss.menuBarExtra`）—— 对着一个
/// 还没铺好的下拉按下去，系统那本「现在开着」的账翻不过来，下一次点图标就得
/// 点两下（2026-09-29 客户报过这个）。
private struct PanelBridge: View {
    var body: some View {
        Color.clear
            .frame(width: 2, height: 2)
            .onAppear {
                PanelWindowRequest.shared.request(reason: "点了菜单栏图标")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    PanelDismiss.menuBarExtra()
                }
            }
    }
}

/// 菜单栏上那一项：平时是信号条 ＋ `4G`，来电时是电话 ＋ 号码。
///
/// 2026-09-25：客户报「图标点得动，菜单面板不弹」。视频里能看到关键的一帧
/// —— 他点下去的那一刻，图标从 `4G` 变成一根斜杠天线，两秒多又变回来。
/// 也就是说**模块在点击那一瞬间掉线了**，而掉线在这个视图里意味着换分支。
///
/// 换分支是要出事的：三个分支的**视图结构不一样**（两块 / 两块 / 一块），
/// SwiftUI 会把菜单栏那一项拆掉重建，重建又正好撞在面板正在弹的那一瞬，
/// 面板跟着没了。本机 macOS 15 上掉线从不落在点击那一瞬间，怎么点都正常，
/// 所以一直没被发现。
///
/// 现在标签**永远是同一个 `Image`**：信号条、`4G`、号码全都画进同一张位图。
/// 状态变化只是换像素，视图结构从头到尾不变，菜单栏那一项就不会被拆。
/// 看得见的样子和原来一致。
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel) { self.model = model }

    var body: some View {
        Image(nsImage: MenuBarLabel.image(for: model))
            // 面板窗口那条后路就挂在这儿 —— 因为**只有它一直在**：菜单栏那一项
            // 从启动到退出都在，而面板自己是点开才存在的。客户那台机器上面板
            // 弹不出来时，没有任何一个「面板里的视图」收得到这个信号。
            .onReceive(PanelWindowRequest.shared.$ticket.dropFirst()) { _ in
                // 面板那一扇窗只从这一条路开：点菜单栏图标（`PanelBridge`）
                // 和双击 App 图标（`SingleInstance`）都发同一个信号。
                AppActivation.activate()
                openWindow(id: WindowID.panel)
                AppActivation.raise(WindowID.panel)
            }
    }

    /// 高度钉死，宽度随内容走。
    ///
    /// 15 是量出来的：11pt 的一行文字是 14 高，最大的那个 SF Symbol 是 15。
    /// 钉死高度是为了让三种状态连**尺寸**都一样 —— 只要和状态有关的东西还
    /// 在变，就还是有机会把那一项弄重建。
    static let labelHeight: CGFloat = 15
    static let spacing: CGFloat = 3
    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    enum Part {
        case symbol(String)
        case bars(Int)
        case text(String)
    }

    /// 菜单栏是客户的第一眼。来电时它必须和平时不一样，否则「有提示」和
    /// 「没提示」在客户眼里是同一件事。
    static func parts(for model: AppModel) -> [Part] {
        if model.call.state == .ringing || model.call.state == .waiting {
            return [.symbol("phone.arrow.down.left"),
                    .text(model.call.number.isEmpty ? "来电" : model.call.number)]
        }
        if model.isConnected {
            return [.bars(model.bars),
                    .text(model.unreadCount > 0 ? "\(model.unreadCount)" : "4G")]
        }
        return [.symbol("antenna.radiowaves.left.and.right.slash")]
    }

    /// 数据开关关掉、又不是来电/等待时，菜单栏图标该变灰。
    /// 抽成纯函数，渲染自检里逐条钉边界（数据开/数据关/来电时数据关）。
    static func shouldDim(dataWanted: Bool, callAlerting: Bool) -> Bool {
        !dataWanted && !callAlerting
    }

    /// 所有状态都从这一张图里出。
    ///
    /// 最后标成模板图：模板只取 alpha，颜色交给菜单栏自己决定，深色浅色
    /// 菜单栏都不会画错 —— 这也正好绕开「符号本来是什么颜色」这个问题。
    static func image(for model: AppModel) -> NSImage {
        let pieces = parts(for: model).compactMap(bitmap)
        guard !pieces.isEmpty else { return SignalBars.image(bars: 0, height: labelHeight) }
        // 数据开关关掉时整枚图标变灰：模板图只认 alpha，把每块按 0.4 的
        // 不透明度合成，菜单栏上出来的就是「灰」。来电 / 等待那两档不跟着灰
        // —— 那是紧急提示，和数据开关无关。
        let callAlerting = model.call.state == .ringing || model.call.state == .waiting
        let dimmed = Self.shouldDim(dataWanted: model.dataWanted, callAlerting: callAlerting)
        let width = pieces.reduce(0) { $0 + $1.size.width }
            + spacing * CGFloat(pieces.count - 1)
        let composed = NSImage(size: NSSize(width: width.rounded(), height: labelHeight),
                               flipped: false) { _ in
            var x: CGFloat = 0
            let fraction: CGFloat = dimmed ? 0.4 : 1.0
            for piece in pieces {
                let y = ((labelHeight - piece.size.height) / 2).rounded()
                let rect = NSRect(x: x, y: y,
                                  width: piece.size.width, height: piece.size.height)
                piece.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction)
                x += piece.size.width + spacing
            }
            return true
        }
        composed.isTemplate = true
        return composed
    }

    private static func bitmap(_ part: Part) -> NSImage? {
        switch part {
        case .symbol(let name):
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        case .bars(let bars):
            return SignalBars.image(bars: bars, height: 11)
        case .text(let value):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]
            let size = (value as NSString).size(withAttributes: attributes)
            return NSImage(size: NSSize(width: ceil(size.width), height: labelHeight),
                           flipped: false) { _ in
                // 行盒（14 高）在 15 高的位图里居中：0.5 就是那半点的余量，
                // 不留它，字形的上下缘正好压边，会被裁掉一丝。
                (value as NSString).draw(at: NSPoint(x: 0, y: (labelHeight - size.height) / 2),
                                         withAttributes: attributes)
                return true
            }
        }
    }
}

/// Four ascending bars, filled to `bars`.
///
/// Painted into a template `NSImage` instead of being composed from
/// `RoundedRectangle`. A `MenuBarExtra` label only composites `Text` and
/// `Image` into the menu bar — anything SwiftUI draws itself is dropped whole.
/// Measured 2026-09-25: this same view rendered correctly inside the panel and
/// showed *nothing* up in the menu bar, so the reading a customer glances at
/// first was missing next to 「4G」 while every automatic check stayed green.
/// A template image survives both places, and unlike an SF Symbol it still
/// works from macOS 13 up.
struct SignalBars: View {
    var bars: Int
    var height: CGFloat = 11

    var body: some View {
        Image(nsImage: Self.image(bars: bars, height: height))
    }

    /// How many of the four bars come out solid. A five-bar reading rounds up.
    static func filledCount(_ bars: Int) -> Int {
        Int((Double(max(0, min(bars, 5))) / 5.0 * 4.0).rounded())
    }

    static let barWidth: CGFloat = 2.2
    static let barGap: CGFloat = 1.2

    static func image(bars: Int, height: CGFloat) -> NSImage {
        let filled = filledCount(bars)
        let width = 4 * barWidth + 3 * barGap
        let image = NSImage(size: NSSize(width: width, height: height),
                            flipped: false) { _ in
            for index in 0..<4 {
                let barHeight = height * (0.4 + 0.2 * CGFloat(index))
                let rect = NSRect(x: CGFloat(index) * (barWidth + barGap),
                                  y: 0,
                                  width: barWidth,
                                  height: barHeight)
                let shade: CGFloat = index < filled ? 1 : 0.28
                NSColor.black.withAlphaComponent(shade).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 0.8, yRadius: 0.8).fill()
            }
            return true
        }
        // Template so the menu bar and the panel each tint it with their own
        // foreground colour, which is what the shapes did before.
        image.isTemplate = true
        return image
    }
}
