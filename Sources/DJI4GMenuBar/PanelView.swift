import SwiftUI
import AppKit
import DJI4GCore

/// 2026-09-29 之前这个面板有两个家：菜单栏下拉，和双击图标开出来的独立
/// 窗口；两边共用同一个 `PanelView`，差别只在「收起」的时候收的是谁。
///
/// 现在只剩一个家：**面板本身就是那扇系统窗口**（`WindowID.panel`）。点一下
/// 菜单栏图标就是开它 —— 客户要的「系统默认的窗口设计」只有这样才给得出来：
/// 下拉是系统给的浮层，装不上真的交通灯，自己画一套假的，他 2026-09-29
/// 在截图上一眼就认出来了。收起走系统标题栏那颗红按钮，不用我们再转一手。

enum PanelTab: String, CaseIterable {
    case network = "NETWORK"
    case module = "MODULE"
    case sms = "SMS"
}

/// The drop-down: a black dot-matrix main screen, the three control pills, and
/// three mini screens that double as tabs for the detail area underneath.
struct PanelView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var tab: PanelTab
    @State private var showConsole = false
    /// 头部那颗箭头按下去之后折起来的迷你版（见 `HeaderView`）。
    @State private var compact: Bool
    private let consoleOutput: String
    private let consolePresets: Bool
    private let consoleUSSD: String
    /// 出图夹具用：SMS 页一打开就把某一条摊开（见 `SMSDetail.init`）。
    private let initialSMS: SMSMessage?

    /// The panel always opens on NETWORK in the real app; the screenshot
    /// harness asks for a specific tab so every detail view gets rendered.
    ///
    /// `consoleVisible` 同理：AT 控制台平时是收起的，只有截图会把它摊开 ——
    /// 那块回显的配色改过之后，没有一张图能看的话，下次再糊也没人发现。
    init(initialTab: PanelTab = .network, consoleVisible: Bool = false,
         consoleOutput: String = "", consolePresets: Bool = false,
         consoleUSSD: String = "", compact: Bool = false,
         initialSMS: SMSMessage? = nil) {
        _tab = State(initialValue: initialTab)
        _showConsole = State(initialValue: consoleVisible)
        _compact = State(initialValue: compact)
        self.consoleOutput = consoleOutput
        self.consolePresets = consolePresets
        self.consoleUSSD = consoleUSSD
        self.initialSMS = initialSMS
    }

    var body: some View {
        VStack(spacing: compact ? 7 : 10) {
            HeaderView(compact: $compact)
            if !compact { fullBody }
        }
        .padding(compact ? 8 : 12)
        .frame(width: Theme.panelWidth)
        .background(Theme.chrome)
        // 这一行是「点不开」那个 bug 的分水岭。客户再报一次的时候，日志里
        // 有它 → 面板确实弹出来了，问题在别处；没它、而进程一直活着 →
        // 点击压根没走到这里，就是没弹。两者要修的地方完全不同。
        .onAppear {
            AppLog.panelOpened()
            // 客户人在的时候问麦克风最合适：没授权就弹一次，已经授权的这一句
            // 是空转（系统也只认第一次）。不写活动列表 —— 面板一天要开几十次。
            model.askForMicrophoneIfNeeded(announceGranted: false)
        }
    }

    /// 面板摊开时的全部内容。
    ///
    /// 折成一条的时候这里一块都不画：折的意义就是「只剩该看的几个字」，
    /// 留着其中任何一块，那条小条都得跟着它长高。
    @ViewBuilder private var fullBody: some View {
        Group {
            if model.notificationsBlocked { NotificationWarning() }
            if model.micNeedsAttention { MicrophoneWarning() }
            if model.call.state.isBusy { CallBanner() }
            MainScreen()
            ControlRow()
            HStack(spacing: 8) {
                ForEach(PanelTab.allCases, id: \.self) { item in
                    MiniScreen(tab: item, selected: tab == item) { tab = item }
                }
            }
            Divider().overlay(Theme.chromeEdge)

            Group {
                switch tab {
                case .network: NetworkDetail()
                case .module: ModuleDetail()
                case .sms: SMSDetail(initialSelected: initialSMS)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showConsole {
                ConsolePanel(seededOutput: consoleOutput, presetsExpanded: consolePresets,
                             seededUSSD: consoleUSSD)
            }
        }
        FooterView(showConsole: $showConsole,
                   // 两条都走 `openAndRaise`：先把这个 App 拎到前台，再开窗、
                   // 再把已经开着的那扇抬起来。少任何一步，客户看到的就是
                   // 「点了没反应」—— 见那个函数的注释。
                   openCall: { openAndRaise(WindowID.call) },
                   openSetup: { openAndRaise(WindowID.setup) })
        if let error = model.lastError {
            Text(error)
                .label(9)
                .foregroundStyle(Theme.alertInk)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 从这块面板里开一扇窗口：点一下，窗口就得在最前面。
    ///
    /// 三步缺一不可，客户 2026-09-29 报的正是中间漏掉的那一步：
    /// ① `AppActivation.activate` —— 菜单栏程序平时不抢前台，不激活的话新
    ///    窗口会开在别人窗口后面，客户看到的是「点了没反应」；
    /// ② `openWindow` —— 开窗，或者把已经开着的那扇叫出来；
    /// ③ `AppActivation.raise` —— 已经开着的那扇，上面那一步不保证把它抬起来。
    private func openAndRaise(_ id: String) {
        AppActivation.activate()
        openWindow(id: id)
        AppActivation.raise(id)
    }
}

// MARK: - Header

struct HeaderView: View {
    @EnvironmentObject private var model: AppModel
    /// 摊开还是折起来。
    @Binding var compact: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isConnected ? Theme.phosphorInk : Theme.inkSoft.opacity(0.5))
                .frame(width: 7, height: 7)
            Text("DJI 4G").label(compact ? 12 : 15).foregroundStyle(Theme.ink)
            if !compact {
                Text("一代").label(9).foregroundStyle(Theme.inkNote)
            }
            Spacer(minLength: 4)
            if compact, model.call.state.isBusy {
                Image(systemName: "phone.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusTint)
            }
            Text(status).label(10).foregroundStyle(statusTint).lineLimit(1)
            if model.isWorking && !compact {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            // 「缩成一条」的入口。原来是左上角那颗黄点 —— 三颗自绘点一起撤掉
            // （2026-09-29，客户要系统的窗口设计），折起来这件事总得有个看得见
            // 的出口，就挪到刷新旁边，还是一颗普通的图标按钮。
            Button {
                compact.toggle()
            } label: {
                Image(systemName: compact ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.ink)
            .help(compact ? "展开面板" : "缩成一条")
            .accessibilityLabel(compact ? "展开面板" : "缩成一条")
            Button {
                model.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.ink)
            .help("重新读取模块状态")
            .accessibilityLabel("重新读取模块状态")
        }
    }

    /// 折起来之后这一行就是全部，所以它得说满：电话正在响 > 没连上 > 制式
    /// 带未读。摊开时上面几块已经把话说完了，这里只留制式 —— 原来的样子。
    private var status: String {
        guard compact else {
            return model.network.accessTechnology.isEmpty ? "--" : shortRAT
        }
        if model.call.state.isBusy { return model.call.state.label }
        if !model.isConnected { return "未连接" }
        if model.unreadCount > 0 { return "\(shortRAT) · \(model.unreadCount) 条未读" }
        return shortRAT
    }

    /// 折起来的时候颜色是唯一能喊的：正在通话用警示色，其余交给次级墨色。
    private var statusTint: Color {
        compact && model.call.state.isBusy ? Theme.alertInk : Theme.inkNote
    }

    private var shortRAT: String {
        let text = model.network.accessTechnology.uppercased()
        if text.contains("LTE") { return "LTE" }
        if text.contains("WCDMA") { return "3G" }
        if text.contains("GSM") { return "2G" }
        return text
    }
}

// MARK: - 通知没开

/// 「电话来了没弹窗」的那半句话，放在面板顶上。
///
/// 2026-09-25 真机日志里每次启动都写着「系统通知没允许」。这句话当时只写进
/// 活动列表 —— 可活动列表是客户自己要求收起的，于是唯一能解释「电话为什么
/// 没弹」的那句，正好被折在看不见的地方。客户不会去翻系统设置确认 App 有没有
/// 通知权限，得有人把他送到那一页。
///
/// 顶在头部下面而不是塞进底部的细则里：漏接电话是这个产品最要命的失败，
/// 它值得占常态版面。权限一给，这行自己就没了。
///
/// 2026-09-26 改文案。原文是「系统没允许通知，来电不会弹窗」，而它是错的：
/// `RingAlert` 那张卡片压根不走任何授权 —— 浮在全屏之上、`canJoinAllSpaces`、
/// 带循环铃声，没有通知权限照样弹。客户读到「来电不会弹窗」只会以为自己要漏
/// 接电话，转头去怀疑模块坏了。这里丢掉的只是系统横幅和通知中心里的那条历史，
/// 所以照实写，别再吓人。
struct NotificationWarning: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: 10, weight: .semibold))
            // 2026-09-26：原句中间夹了个拉丁词「App」。Doto 只画得出 3×5 个点
            // 的拉丁字形，9pt 时笔画铺不满，同一个 `ink` 读出来比两边的汉字淡
            // 一档；再加上 `.label()` 那 0.6 的 tracking，一句话被切成了三段，
            // 放大截图里「弹  App  浮层」中间空得像是掉了个词。同一句话里的
            // 字就该是一个颜色、一个密度 —— 换成汉字，整句连起来。
            Text("系统通知没开，来电只弹应用浮层").label(9).lineLimit(1)
            Spacer(minLength: 4)
            Button("去打开") { Notifier.openNotificationSettings() }
                .buttonStyle(.plain)
                .label(9)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.chrome))
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.alert.opacity(0.22))
        )
    }
}

// MARK: - 麦克风没授权

/// 「打电话没声音」的那半句话。
///
/// 和上面那条通知一样，它说的是**另一件客户自己看不见的事**：麦克风没授权
/// 的时候，通话只剩一个方向 —— 对方说什么都听得见，自己说什么对方都听不见。
/// 系统那个授权框一辈子只弹一次，弹在一个没有窗口的 App 背后，十有八九没人
/// 看见；错过之后它不再弹、界面也不报错，看上去就是「模块坏了」。
///
/// 2026-09-30 那通「接通 33 秒才出声」的电话就是这一条缺着。授权一次之后
/// 这行自己就没了，所以它值得占常态版面。
struct MicrophoneWarning: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(model.micDenied ? "麦克风没打开，对方听不到您" : "麦克风没授权，对方听不到您")
                .label(9).lineLimit(1)
            Spacer(minLength: 4)
            Button(model.micDenied ? "去打开" : "去授权") { model.handleMicrophoneAction() }
                .buttonStyle(.plain)
                .label(9)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.chrome))
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.alert.opacity(0.22))
        )
    }
}

// MARK: - 通话横幅

/// 面板顶上的通话条。
///
/// 来电原来只有两条路：系统通知（客户可能根本没允许），和那个要先自己点开的
/// 「通话」窗口。两条都要求客户先知道有电话进来 —— 2026-09-24 的实测就是这
/// 样：电话在响，客户面前什么都没有，因为号码只出现在手动点开的面板里。
/// 这条横幅把状态、号码和按钮放进客户一定会看的那个面板，并且跟着通话状态
/// 自己出现、自己消失。
struct CallBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: glyph)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.call.state.label).label(9).foregroundStyle(Theme.phosphorDim)
                Text(number).label(16).foregroundStyle(tint).lineLimit(1)
            }
            Spacer(minLength: 2)
            actions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.screen)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tint.opacity(0.55), lineWidth: 1.2)
                )
        )
    }

    /// 响铃和等待要的是「接」或「不接」，通话中要的是「挂断」——同一排按钮
    /// 换文案而不是换位置，客户不必重新找。
    private var ringing: Bool {
        model.call.state == .ringing || model.call.state == .waiting
    }

    private var glyph: String {
        switch model.call.state {
        case .ringing, .waiting: return "phone.arrow.down.left"
        case .held: return "pause.fill"
        default: return "phone.fill"
        }
    }

    private var tint: Color {
        model.call.state == .ringing || model.call.state == .waiting ? Theme.phosphor : Theme.ink
    }

    private var number: String {
        model.call.number.isEmpty ? "未知号码" : model.call.number
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            if ringing {
                button("接听", Theme.phosphor) { model.answer() }
                button("拒接", Theme.alert) { model.reject() }
            } else {
                button("挂断", Theme.alert) { model.hangup() }
            }
        }
    }

    private func button(_ title: String, _ tint: Color,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).label(10).foregroundStyle(tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(tint.opacity(0.14))
                        .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Main screen

struct MainScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Screen(radius: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.quotaGB > 0 ? "DATA LEFT" : "SIGNAL").label(9)
                        .foregroundStyle(Theme.phosphorDim)
                    Spacer()
                    Text(model.quotaGB > 0 ? "实时估算" : model.network.band)
                        .label(9)
                        .foregroundStyle(Theme.phosphorDim)
                }
                HStack(spacing: 12) {
                    ZStack {
                        DotRing(progress: model.remainingFraction)
                        VStack(spacing: 0) {
                            Text(headline).label(22).foregroundStyle(Theme.phosphor)
                            Text(headlineUnit).label(8).foregroundStyle(Theme.phosphorDim)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(subhead).label(11).foregroundStyle(Theme.phosphor)
                        Text(model.signalCaption + " · " + model.network.carrier.shortName)
                            .label(9)
                            .foregroundStyle(Theme.phosphorDim)
                        Sparkline(samples: model.trafficSamples)
                            .frame(height: 34)
                    }
                }
                HStack(spacing: 12) {
                    Text("今日 \(format(model.todayBytes))").label(9)
                    Text("\(model.data.counterSource == .module ? "模块计数" : "本月") \(format(model.monthBytes))").label(9)
                    Spacer()
                    Text(model.data.ipv4Address.isEmpty ? "无 IPv4" : model.data.ipv4Address).label(9)
                }
                .foregroundStyle(Theme.phosphorDim)
            }
        }
    }

    private var headline: String {
        if let remaining = model.remainingGB { return String(format: "%.1f", remaining) }
        return model.signal.rsrp.map { String(format: "%.0f", $0) } ?? "--"
    }

    private var headlineUnit: String {
        model.remainingGB != nil ? "GB" : "dBm RSRP"
    }

    private var subhead: String {
        if model.quotaGB > 0 {
            let percent = Int((model.remainingFraction * 100).rounded())
            return String(format: "%d%% LEFT", percent)
        }
        return model.stateLine
    }

    /// 单位写成两个字母（`GB` 而不是 `G`）。
    ///
    /// 这条规矩来自 2026-09-26 的一次误读：复盘截图时我把 `100.0 M` 看成了
    /// 「100.0 H」，当成数据 bug 查了半天 —— Doto 是点阵字，`M` 中间那个 V
    /// 当时只画了下半截，9pt 下顶上留空，确实跟 `H` 难分。
    ///
    /// 字形的根因当天已经修掉（V 整体上移一格，`M` 三笔到顶；验收样张就是
    /// 面板底部那行 `ECM (macOS / Linux)`）。两个字母的写法仍然保留：详情页
    /// 和环形图用的也是 `MB`/`GB`，全 app 口径一致，扫一眼不用停顿。
    private func format(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= 1_000_000_000 { return String(format: "%.2f GB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0f KB", value / 1_000) }
        return "\(bytes) B"
    }
}

/// Rolling throughput trace, drawn from the module's own byte counters.
struct Sparkline: View {
    var samples: [Double]

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            let peak = max(samples.max() ?? 1, 1)
            var path = Path()
            for (index, sample) in samples.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(samples.count - 1)
                let y = size.height * (1 - CGFloat(sample / peak))
                index == 0 ? path.move(to: CGPoint(x: x, y: y))
                           : path.addLine(to: CGPoint(x: x, y: y))
            }
            context.stroke(path, with: .color(Theme.phosphor.opacity(0.85)), lineWidth: 1.2)
        }
    }
}

// MARK: - Controls

struct ControlRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // 这一排只剩一颗开关。
        //
        // 原来并排三颗：`QUERY` / `4G ON` / `AUTO`，2026-09-29 客户换中文时
        // 把它们读了一遍，结论是「只有中间的数据开关点击是有用的」—— 说得对：
        //
        //   · 刷新：头顶那支 ⟳ 做的是同一件事（`refreshAll`），同一扇面板上
        //     两颗按钮一个功能，客户还得猜它俩是不是不一样；
        //   · 联网（写运营商 APN）：卡插上、模块报出运营商以后**自己就写**了
        //     （见 `writeCarrierAPNIfPossible`）；真到了认不出卡的时候，设置页
        //     那四颗「移动 / 联通 / 电信 / 广电」本来就能手点，比这颗空按一下
        //     还准。
        //
        // 少两颗之后，这一颗也换过两次样子：
        //
        //   ① 铺满整行的大胶囊（`4G ON` → `数据` + 一盏灯）。它其实不是开关，
        //      是一块**状态牌**：客户按哪儿都亮，按哪儿都动，2026-09-30 的原话
        //      是「不像开关，而且整个窗口都可以点击，容易误点击」——320pt 宽的
        //      命中区，想点别的东西手指一滑就把它拨了。
        //   ② 现在是系统的小号开关，摆在整行最右，只有它自己那 30pt 接得住
        //      点击；左边那颗「数据」是标签，点它什么都不会发生。
        //
        // 认得出的开关形状、认得出的开 / 关位置，是这里唯一要买的东西 ——
        // 状态牌那套「实心灯 / 空心绿环 / 空心灰环」跟着一起撤了：开关自己的
        // 位置就写着状态，再画一盏灯是同一句话说两遍。
        HStack(spacing: 6) {
            Text("数据").label(12).foregroundStyle(Theme.ink)
            // 「开了但还没接通」是真实存在的一段时间（要等 macOS 那条网络服务
            // 起来）。开关此刻已经在右边那一档，光看它读不出「正在接」，所以
            // 这里补两个字；接通或者关掉，它自己就没了。
            if model.dataWanted && !model.data.isRoutable {
                Text("连接中").label(9).foregroundStyle(Theme.inkNote)
            }
            Spacer(minLength: 12)
            DataSwitch(on: model.dataWanted,
                       // 模块没上电时按下去只会失败在「通道已关闭」上，那句红字
                       // 对客户什么也没说明（面板顶上已经写着「模块未连接」）。
                       // 灰掉比报错诚实。
                       enabled: model.isConnected && !model.isWorking) {
                model.setDataEnabled($0)
            }
            .help(model.isConnected
                  ? (model.dataWanted
                     ? "关掉 4G 数据：默认路由交回 Wi-Fi（模块和电话都还在）"
                     : "打开 4G 数据：上网流量走模块")
                  : "模块没连上，等面板上出现信号再动这里")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 数据开关的画法。
///
/// 这颗用系统 `Toggle` 画过一次，换掉的原因是它**只在 App 是前台窗口时才认得出来**：
/// 面板挂在菜单栏上，客户切到别的窗口之后这张脸就退成一片浅灰，
/// 开了和关了长得一模一样 —— 2026-09-30 的原话是「鼠标不点击这个程序的时候
/// 按钮一直显示关闭的」。开关是要被读一眼就懂的，它的样子不能取决于谁拿着焦点，
/// 所以自己画：轨道 + 滑块，两种状态两种颜色，任何窗口状态下都读得出。
///
/// 命中区只包着这 34×20 自己（上一版那颗铺满整行的大胶囊就是在这里吃的亏：
/// 320pt 宽，想点别的东西手指一滑就把它拨了）。
struct DataSwitch: View {
    var on: Bool
    var enabled: Bool
    var action: (Bool) -> Void

    private let width: CGFloat = 34
    private let height: CGFloat = 20

    var body: some View {
        Button {
            action(!on)
        } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(on ? Theme.phosphorInk : Theme.chromeEdgeStrong.opacity(0.55))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Theme.chromeEdgeStrong.opacity(on ? 0.0 : 0.7),
                                          lineWidth: 1)
                    )
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: width, height: height)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        .accessibilityLabel("4G 数据")
        .accessibilityValue(on ? "已打开" : "已关闭")
    }
}

// MARK: - Mini screens

struct MiniScreen: View {
    @EnvironmentObject private var model: AppModel
    var tab: PanelTab
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Screen(radius: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(tab.rawValue).label(8).foregroundStyle(Theme.phosphorDim)
                        Spacer()
                        if tab == .network { SignalBars(bars: model.bars, height: 9) }
                        else { Circle().fill(Theme.phosphor).frame(width: 4, height: 4) }
                    }
                    Text(primary).label(15).foregroundStyle(Theme.phosphor).lineLimit(1)
                    Text(secondary).label(8).foregroundStyle(Theme.phosphorDim).lineLimit(1)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Theme.phosphor.opacity(0.7) : .clear, lineWidth: 1.4)
            )
        }
        .buttonStyle(.plain)
    }

    private var primary: String {
        switch tab {
        case .network:
            let text = model.network.accessTechnology.uppercased()
            if text.contains("LTE") { return "LTE" }
            if text.contains("WCDMA") { return "3G" }
            return model.isConnected ? (text.isEmpty ? "在线" : text) : "离线"
        case .module: return model.temperatureLabel
        case .sms: return model.messages.isEmpty ? "0 条" : "\(model.messages.count) 条"
        }
    }

    private var secondary: String {
        switch tab {
        case .network: return model.network.band.isEmpty ? model.stateLine : model.network.band
        case .module:
            // 断开时不能说「未识别」—— 模块不在，谈不上识别不出来。见
            // `AppModel.liveIdentity`：`identity` 断开后留着的是上一份值。
            guard let live = model.liveIdentity else { return "未连接" }
            return live.model.isEmpty ? "未识别" : live.model
        case .sms: return model.unreadCount > 0 ? "\(model.unreadCount) 条未读" : "无未读"
        }
    }
}

// MARK: - Footer

struct FooterView: View {
    @Binding var showConsole: Bool
    var openCall: () -> Void
    var openSetup: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            icon("phone.fill", "拨号 / 接听") { openCall() }
            icon("slider.horizontal.3", "模块设置") { openSetup() }
            icon("terminal", "AT 控制台") { showConsole.toggle() }
            Spacer()
            // 这里原来贴着「串口 /dev/cu.usbmodem…」那行 8pt 灰字：面板最下面
            // 最靠边的一行小字，也是开机时最容易读成「糊了」的那行。它是排查
            // 用的信息，已经搬进控制台抽屉 —— 收起时看不见，点开就在第一行。
            icon("power", "退出") { NSApplication.shared.terminate(nil) }
        }
    }

    private func icon(_ name: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 24, height: 21)
                // 和中间那排操作胶囊穿同一身：近白的面 + 压深的边框。
                //
                // 这里原来是 `chromeEdge` 兑一半透明度 —— 比面板底(0.94)还暗，
                // 画出来是一枚灰片，和上面刚立起来的白胶囊摆在一起像两个东西。
                // 2026-09-26 把胶囊整体加重时顺手统一，底部这几个是面板的主要
                // 入口，不是次要到可以糊掉的装饰。
                .background(
                    Capsule().fill(Theme.chromeHi)
                        .overlay(Capsule().strokeBorder(Theme.chromeEdgeStrong, lineWidth: 1.2))
                        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
