import SwiftUI
import AppKit
import DJI4GCore

/// 「运营商」那一栏先按地区分：自动识别（默认）/ 中国大陆 / 中国香港 /
/// 自定义。香港与大陆是两套卡、两套 APN，混在一个列表里客户反而点错。
private enum OperatorRegion: String, CaseIterable, Identifiable {
    case auto = "自动识别"
    case mainland = "大陆"
    case hongKong = "香港"
    case custom = "自定义"

    var id: String { rawValue }
}

/// Dial, answer, hang up, and route the call audio to the module.
struct CallWindow: View {
    @EnvironmentObject private var model: AppModel
    @State private var number = ""
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Screen(radius: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle()
                            .fill(model.call.state.isBusy ? Theme.phosphor : Theme.inkSoft.opacity(0.4))
                            .frame(width: 7, height: 7)
                        Text(model.call.state.label).label(14).foregroundStyle(Theme.phosphor)
                        Spacer()
                        Text(model.call.state == .active ? model.call.durationLabel : "")
                            .label(14).foregroundStyle(Theme.phosphor)
                    }
                    Text(model.call.number.isEmpty ? "—" : model.call.number)
                        .label(20).foregroundStyle(Theme.phosphor)
                    // 2026-09-27：这一行原来在空闲时写着「输入号码拨号，或等对方
                    // 打进来」—— 一句大白话占着窗口最显眼的位置。现在空闲时不写
                    // 字（还是留着这个 `Text`，好让窗口高度不跳），有事才写
                    // 「呼出 / 来电」。
                    Text(model.call.state.isBusy ? model.call.direction.label : " ")
                        .label(9).foregroundStyle(Theme.phosphorDim)
                }
            }

            // Whatever refused the last click is reported in the window that
            // was clicked. The panel sits behind this one, so a reason shown
            // only there leaves the customer pressing a button that appears
            // dead.
            if let error = model.lastError {
                // 这个窗口里没有别处写「为什么不行」，而「没插卡」的完整理由
                // 有六十多个字：两行会被截在「插好了仍显示未插卡」中间。
                Text(error)
                    .label(9)
                    .foregroundStyle(Theme.alertInk)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 通话语音这一格。
            //
            // 它和下面那行「模块声卡」说的是两件事，别合并：声卡是 USB 上的
            // 一张硬件（有没有被写进 `usbcfg`），通话语音是模块里的驱动 +
            // 出厂校准 + PCM 桥（声音到底走不走）。出厂状态下声卡可能在、
            // 语音却一定不通 —— 以前这里只报前者，客户于是打了一通没声音的
            // 电话，而屏幕上没有任何一处能读到为什么。
            HStack {
                Field(caption: "通话语音",
                      value: model.voiceStatusLabel,
                      tint: model.voiceSetup.ready ? Theme.phosphorInk : Theme.ink)
                Spacer()
                if model.callVoiceLive {
                    Circle().fill(Theme.phosphorInk).frame(width: 6, height: 6)
                } else if !model.voiceSetup.ready {
                    // 通话中不给这个按钮：安装的第一步会重启模块，而桥正挂在
                    // USB 声卡上 —— 点了就是把这一通电话掐成没声音的。
                    Button(model.voiceRepairing ? "补装中…" : "一键安装") { model.installCallVoice() }
                        .label(10)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.ink)
                        .disabled(!model.isConnected || model.call.state.isBusy
                                  || model.isWorking || model.voiceRepairing)
                        .help("把通话要用的语音功能准备好。模块会重启一次。")
                }
            }

            // 麦克风授权。只有没授权的时候才出现 —— 授权是常态，常态不占地方。
            //
            // 2026-09-30 那通「接通 33 秒才出声」的电话就是这一条缺着：授权框
            // 只有第一次会弹，弹在这个没有窗口的 App 背后没人点，CoreAudio 就
            // 一直等在那儿。被拒过一次之后系统不再弹框，所以这里必须留一条
            // 直接跳「隐私与安全性 → 麦克风」的路，否则「没声音」没有出口。
            if model.micNeedsAttention {
                HStack(spacing: 6) {
                    Text("麦克风").label(9).foregroundStyle(Theme.inkNote)
                    Text(model.micDenied ? "没打开" : "没授权").label(9).foregroundStyle(Theme.alertInk)
                    Spacer()
                    Button(model.micDenied ? "去打开" : "去授权") { model.handleMicrophoneAction() }
                        .label(9)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.ink)
                        .help(model.micDenied
                              ? "打开系统设置的「麦克风」，把这一项打开，对方才听得到您说话。"
                              : "点一下会弹出系统的麦克风授权框，允许之后对方才听得到您说话。")
                }
            }

            if model.callVoiceLive {
                VStack(alignment: .leading, spacing: 3) {
                    LevelBar(caption: "麦克风 → 模块", level: model.callLevels.up)
                    LevelBar(caption: "对方 → 扬声器", level: model.callLevels.down)
                }
            }

            // 不摆说明书：这一格的结论（已就绪 / 还没装好）和那颗「一键安装」
            // 就在上面，为什么 / 怎么装全在 `.help` 里。
            //
            // 唯一要占一行的是「两件事撞在一起」的那种状态 —— 上面写着「已就绪」
            // （模块里的通路好着），模块声卡却关着（客户为插手机 / 平板关的），
            // 这时候打出去是一通两边都没声音的电话。这一行只在那一档出现。
            if model.data.composition?.audio == false {
                Text("模块声卡没开，打电话没声音")
                    .label(9)
                    .foregroundStyle(Theme.alertInk)
                    .help("在「模块设置」里把「使用模式」切回 Mac 版，模块重启一次就好。")
            }

            // 手动路由那一行。绝大多数客户用不到 —— 通话语音走的是上面的桥，
            // 全程不动系统默认设备。留着它是给「想拿模块当普通 USB 声卡用」的
            // 人一条路，顺手把声卡状态也报在这里。
            HStack(spacing: 6) {
                Text("模块声卡").label(9).foregroundStyle(Theme.inkNote)
                Text(model.voice.label).label(9).foregroundStyle(Theme.inkNote).lineLimit(1)
                Spacer()
                Button(model.voice.isRouted ? "已切换" : "切到模块") { model.routeAudioToModule() }
                    .label(9)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.inkNote)
                    .disabled(model.voice.moduleDevice == nil)
            }

            // 号码这一行只管号码。
            //
            // 2026-09-29：它右边原来还挂着一颗「拨号」，而动作归下面那一排 ——
            // 一个「打电话」被拆到两行里，客户在按钮排里找不到它。现在号码只
            // 负责号码，动作全归下面那一排（回车照样能拨）。
            TextField("", text: $number)
                .textFieldStyle(.roundedBorder)
                .label(12)
                .ownPlaceholder("号码", size: 12, shows: number.isEmpty)
                .onSubmit { dial() }

            // 这一排只摆此刻真按得动的动作，跟着通话状态换 —— 和菜单栏面板顶上
            // 那条来电横幅同一套规矩（`PanelView` 的 `actions`）。
            //
            // 2026-09-29 客户盯着空闲时的这一排问「正常应该就拨打、挂断吧」。
            // 那一版摆的是接听 / 挂断 / 拒接三颗，全灰：一来打电话的按钮不在
            // 这一排，二来「接听」「拒接」在没有来电的时候根本不成立。现在空闲
            // 摆「拨号 + 挂断」，接听 / 拒接只在真有人打进来时才出现。
            HStack(spacing: 8) {
                let state = model.call.state
                switch state {
                case .ringing:
                    PillButton(title: "接听", glyph: "phone.arrow.down.left",
                               tint: Theme.phosphorInk) { model.answer() }
                    PillButton(title: "拒接", glyph: "phone.down",
                               tint: Theme.alertInk) { model.reject() }
                case .waiting:
                    // 第二路来电时「接听」会被读成接起手上这一通，名字写全。
                    PillButton(title: "接听新来电", glyph: "phone.arrow.down.left",
                               tint: Theme.phosphorInk) { model.answer() }
                    PillButton(title: "拒接新来电", glyph: "phone.down",
                               tint: Theme.alertInk) { model.reject() }
                    PillButton(title: "挂断全部", glyph: "phone.down.fill",
                               tint: Theme.alertInk) { model.hangup() }
                case .idle, .ended:
                    // 号码是空的时候按不动：按下去只会换来一句「号码是空的」
                    // 红字，而这件事客户一眼就看得见。
                    PillButton(title: "拨号", glyph: "phone.arrow.up.right",
                               tint: Theme.phosphorInk,
                               isEnabled: !number.isEmpty) { dial() }
                    // 此刻没东西可挂。留着它是让客户知道「挂断在这儿」，而不是
                    // 满窗口找一颗不存在的按钮。
                    PillButton(title: "挂断", glyph: "phone.down.fill",
                               tint: Theme.alertInk,
                               isEnabled: false) { model.hangup() }
                default:
                    // 呼出中 / 对方振铃 / 通话中 / 保持中：这一刻只有一件事能做。
                    PillButton(title: "挂断", glyph: "phone.down.fill",
                               tint: Theme.alertInk) { model.hangup() }
                }
            }

            // 按键音键盘。只在真正接通后出现 —— 自动语音台（「按 1 转人工」）
            // 是它唯一的用场，别的时候一格都不占。
            //
            // 2026-09-30 之前这里是系统输入框 + 一行素字按钮（用户原话：
            // 「这个 UI 设计很丑，参考优秀设计，重新设计」）。键盘就是电话
            // 机上那张：三列四行，按一位发一位。
            if model.call.state == .active {
                VStack(alignment: .leading, spacing: 5) {
                    Text("按键音").label(10).foregroundStyle(Theme.ink)
                    DTMFKeypad { model.sendDTMFKey($0) }
                }
            }

            historySection
        }
        .padding(14)
        .frame(width: 320)
        .background(Theme.chrome)
        .onAppear {
            // 打开这一页时读一次模块的现状（只读）。不然客户刚装完的语音通路
            // 要等到下一次拨号才在界面上变成「已就绪」。
            model.refreshVoiceSetup()
            // 麦克风那一行同理：客户刚在系统设置里把开关打开，回到这一页就得
            // 看到那一行消失。这一句不弹框，只读状态。
            model.refreshMicrophoneState()
        }
    }

    private func dial() {
        guard !number.isEmpty else { return }
        model.dial(number)
    }

    // MARK: - 通话记录

    /// 通话记录那一块。
    ///
    /// 模块不给这个：`AT+CLCC` 只报「此刻在响 / 在通」的那几路，一代 QDC507
    /// 问不出过去（`AT+CPBS` 那套真机试过，读回来是空的）。所以这一列是 App
    /// 自己攒的 —— 每接通一次、每响一次铃就抄一行下来，存在
    /// `~/Library/Application Support/DJI4G/calllog.json`，重启之后还在，
    /// 最多留 200 条。
    @ViewBuilder
    private var historySection: some View {
        let rows = model.callRecords.reversed()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text("通话记录").label(10).foregroundStyle(Theme.ink)
                if !model.callRecords.isEmpty {
                    Text("\(model.callRecords.count)").label(9).foregroundStyle(Theme.inkNote)
                }
                Spacer()
                if !model.callRecords.isEmpty {
                    Button(confirmingClear ? "再点一下" : "清空") {
                        if confirmingClear {
                            confirmingClear = false
                            model.clearCallHistory()
                        } else {
                            confirmingClear = true
                        }
                    }
                    .label(9)
                    .buttonStyle(.plain)
                    .foregroundStyle(confirmingClear ? Theme.phosphorInk : Theme.inkNote)
                    .help("清掉这份列表。只删这台 Mac 上记着的，模块和卡都不动。")
                }
            }

            if model.callRecords.isEmpty {
                // 空着就写「暂无记录」四个字，不再多解释一句 —— 这一格没有
                // 任何要客户动手的地方。
                Text("暂无记录").label(10).foregroundStyle(Theme.inkNote)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { record in
                            historyRow(record)
                        }
                    }
                }
                // 和收件箱同一笔账：面板 / 窗口的高度按内容的理想高度定，而
                // `ScrollView` 的理想高度是 0 —— 只给上界就会被压成一条线。
                // 按条数给出确定高度，窗口才把它算进去。
                .frame(height: Self.historyHeight(count: model.callRecords.count))
            }
        }
    }

    private func historyRow(_ record: CallRecord) -> some View {
        Button {
            // 点一下把号码填回拨号栏。打回去是这一列最常用的一件事，而
            // 号码本身在 292pt 里还会被截断，抄不了。
            if !record.number.isEmpty { number = record.number }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: record.outgoing ? "arrow.up.right" : "arrow.down.left")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.inkNote)
                    .frame(width: 10)
                Text(record.number.isEmpty ? "—" : record.number)
                    .label(10)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                // 结果这一列的色按「要不要客户回头看一眼」分：接通的绿着，
                // 没接到的红着，自己按掉的（拒接 / 呼出没通）走中性灰 ——
                // 后者是客户自己的动作，不该在列表里喊。
                Text(record.outcome.label)
                    .label(9)
                    .foregroundStyle(resultTint(record.outcome))
                    .frame(width: 40, alignment: .leading)
                Text(record.seconds > 0 ? CallRecord.durationLabel(record.seconds) : "")
                    .label(8)
                    .foregroundStyle(Theme.inkNote)
                    // 时长是这一行里唯一的数字结论，不能被省略号截掉：栏宽按
                    // 最长那种（`999:59`，六个字符）给，`CallRecord.durationLabel`
                    // 也按这个宽度做了分钟不进位的写法。
                    .frame(width: 36, alignment: .trailing)
                Text(record.timeLabel())
                    .label(8)
                    .foregroundStyle(Theme.inkNote)
                    .frame(width: 32, alignment: .trailing)
            }
            .frame(height: Self.historyRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(record.detailLabel())
        .contextMenu {
            Button("复制号码") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.number, forType: .string)
            }
            .disabled(record.number.isEmpty)
        }
    }

    private func resultTint(_ outcome: CallOutcome) -> Color {
        switch outcome {
        case .answered: return Theme.phosphorInk
        case .missed: return Theme.alertInk
        case .rejected, .failed: return Theme.inkNote
        }
    }

    /// 一行记录的高度。钉死，不让字体自己撑 —— 行高差个零点几，封顶那一档
    /// 就会把最后一行切一半（收件箱那边踩过同一个坑）。
    private static let historyRowHeight: CGFloat = 17
    /// 露四行，再多就在框里滚。
    private static func historyHeight(count: Int) -> CGFloat {
        CGFloat(min(count, 4)) * historyRowHeight + 2
    }
}

/// 通话里的按键音键盘 —— 电话机上那一张。
///
/// 只画不管发：按下去是一次 `sendDTMFKey(_:)`，排队与发送在 `AppModel`
/// （连点两下不能被「上一步操作还没结束」顶回来）。
private struct DTMFKeypad: View {
    var action: (String) -> Void

    /// 电话机的次序，不是 `1…9` 横排 —— 客户找「1」的手是从左上角开始的。
    /// 第二个是数字底下那行字母，和电话机上印的一样（0 底下是「+」，
    /// `*` `#` 底下空着）。
    private static let rows: [[(digit: String, letters: String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")],
    ]

    private static let columnGap: CGFloat = 26
    private static let rowGap: CGFloat = 9

    var body: some View {
        // 整块居中：十二颗键的宽度钉死在键帽上，排完把这一段摆到页面中间，
        // 而不是把每颗键抻开铺满整行 —— 那样键与键之间会空出 47pt，看着散。
        VStack(spacing: Self.rowGap) {
            ForEach(Self.rows.indices, id: \.self) { rowIndex in
                HStack(spacing: Self.columnGap) {
                    ForEach(Self.rows[rowIndex].indices, id: \.self) { columnIndex in
                        KeyCap(digit: Self.rows[rowIndex][columnIndex].digit,
                               letters: Self.rows[rowIndex][columnIndex].letters) {
                            action(Self.rows[rowIndex][columnIndex].digit)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Everything that has to be written into the module before the stock
/// firmware will do calls and ECM data at the same time.
struct SetupWindow: View {
    @EnvironmentObject private var model: AppModel
    @State private var quotaText = ""
    @State private var showLog: Bool
    @State private var operatorRegion: OperatorRegion = .auto
    @State private var customAPN = ""
    private let debugExpanded: Bool

    /// `logExpanded` 只有截图会传：运行日志默认收起，而它的展开态也得留一张
    /// 图，不然「点开以后长什么样」永远是客户先看到。
    init(logExpanded: Bool = false, debugExpanded: Bool = false) {
        _showLog = State(initialValue: logExpanded)
        self.debugExpanded = debugExpanded
    }

    /// 模块现在就是「Mac 版」的样子（USB 网卡走 ECM、模块声卡开着）。顶上
    /// 「一键启用」那颗按钮和它下面那句绿字都按这一个结论走 —— 两处各算各的，
    /// 迟早会出现按钮说「没开」、绿字说「已开启」的自相矛盾。
    private var fullFunctionReady: Bool { model.hostModeNow == .mac }

    /// 给客户看的通话语音状态。里面那套「缺驱动 / 桥未运行」是排障用的字，
    /// 客户只需要知道装好没有 —— 具体卡在哪一步，鼠标停上去能看到（`.help`），
    /// 诊断包里也有。
    private var voicePlainLabel: String {
        if model.callVoiceLive { return "通话中" }
        if model.voiceRepairing { return "正在装…" }
        return model.voiceSetup.ready ? "已就绪" : "还没装好"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            // 2026-09-27：这一页原来是一行功能配一段两三行的灰字，一屏九段，
            // 用户的原话是「按钮没几个，全是字」。现在整页只剩「功能名 + 控件」，
            // 说明全部退到 `.help`（鼠标停上去才展开）。
            //
            // 顶上那张黑卡也换了主角：原来是三行说明，而下面那颗真正要按的
            // 按钮长得像标题；现在按钮就摆在卡里，白药丸压在黑底上，是整页
            // 最亮的一块。已经开好的时候不摆按钮 —— 一颗主按钮摆在「没事可做」
            // 的页面上，等于请客户白重启一次模块，重启会把刚上线的网掐十几秒。
            Screen(radius: 14) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Text("一键启用（联网 + 声音）").label(11).foregroundStyle(Theme.phosphor)
                        Spacer(minLength: 4)
                        // 右上角只报一件事：模块现在在哪一档。名字和下面「使用
                        // 模式」那两颗胶囊一模一样，客户不用在两套词之间翻译。
                        Text(model.hostModeNow?.label ?? "—")
                            .label(9).foregroundStyle(Theme.phosphorDim)
                    }

                    if fullFunctionReady {
                        Text("已开好").label(9).foregroundStyle(Theme.phosphor)
                    } else if model.hostModeNow == .mobile {
                        // 客户自己选的「移动版」：这一档天生就没有模块声卡，不是
                        // 「没开好」。这里的按钮要说人话 —— 在这一档上写「启用并
                        // 重启模块」，读起来像在说「你现在是坏的」，而其实他只要
                        // 决定「插电脑用」这一件事。
                        PillButton(title: "切回 Mac 版",
                                   glyph: "bolt.fill",
                                   lamp: model.isConnected ? .pending : .off,
                                   isEnabled: model.isConnected) { model.applyHostMode(.mac) }
                            .help("插电脑用要切回 Mac 版：插上电脑打电话，两个方向才有声音。"
                                  + "模块重启一次，约一分钟。")
                    } else {
                        PillButton(title: "启用并重启模块",
                                   glyph: "bolt.fill",
                                   lamp: model.isConnected ? .pending : .off,
                                   isEnabled: model.isConnected) { model.enableFullFunction() }
                            .help(enableHelp)
                    }
                }
            }

            // 这一页只有一件事要客户选：这模块插在哪台设备上用。原来它是
            // 「手机外放」一行（一颗「改成正常」按钮）加下面那个四档下拉
            // （Windows 电脑 / 这台 Mac / 特殊用途 MBIM / 特殊用途 QMI）——
            // 一个概念被拆成两处、四个协议名字，客户读到的都不知道能不能动。
            //
            // 2026-09-27 起合并成两档，名字就是客户嘴里的说法：Mac 版 / 移动版。
            // 插回电脑时程序会自己回到上次选的那一档（`restoreHostModeIfNeeded`），
            // 所以平时这里不用动。
            SetupRow(title: "使用模式",
                     help: "插电脑用选「Mac 版」，插手机、平板用选「移动版」。"
                         + "换一档要重启模块一次，约一分钟。"
                         + "插回电脑时，程序会自动回到你上次选的那一档。") {
                HStack(spacing: 5) {
                    ForEach(HostMode.allCases, id: \.self) { mode in
                        let active = model.hostModeNow == mode
                        Button(mode.label) { model.applyHostMode(mode) }
                            .label(9)
                            .buttonStyle(.plain)
                            .disabled(!canChangeModule)
                            .foregroundStyle(active ? Theme.phosphorInk : Theme.ink)
                            // 和上面 APN 那四颗同一套语汇：正在用的那一档描绿边、
                            // 铺极浅绿底，另一档白面灰边。模块没连上时读不出是哪
                            // 一档，两颗都不点亮，整行一起压暗。
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(
                                Capsule()
                                    .fill(active ? Theme.phosphorInk.opacity(0.14) : Theme.chromeHi)
                                    .overlay(
                                        Capsule().strokeBorder(
                                            active ? Theme.phosphorInk.opacity(0.75)
                                                   : Theme.chromeEdgeStrong,
                                            lineWidth: 1.2
                                        )
                                    )
                            )
                            .opacity(canChangeModule ? 1 : 0.55)
                            .help(mode.help)
                    }
                }
            }

            // 通话语音是另一件事：上面那颗按钮写的是声卡有没有打开，语音通路在
            // 模块里面（驱动、出厂校准都在那儿）。装好就收起来，不占客户的地方。
            if !model.voiceSetup.ready, model.voiceSetup.adbBinary != nil {
                SetupRow(title: "通话语音",
                         note: voicePlainLabel,
                         help: "要能听见对方说话，得先把这一步装进模块。"
                             + "第一次装会重启一次模块，约一分钟。"
                             + "装好以后每次拔线都会丢一次，插回来程序会自己补，不用管。") {
                    RowButton(model.voiceRepairing ? "装着呢…" : "一键安装",
                              isEnabled: canChangeModule) {
                        model.installCallVoice()
                    }
                }
            }

            Divider()

            // 运营商按地区分组：自动识别（默认）先认卡，认不出再手选地区。
            // 香港卡和大陆卡是两套 APN，混在一个列表里客户会点错 —— 这正是
            // CMHK 曾被当成大陆移动、3HK 曾被配成 3GNET 的根子。
            SetupRow(title: "运营商",
                     note: model.isConnected ? "" : "先连上模块",
                     help: model.isConnected
                         ? "默认自动识别。认不出卡是哪一家、或要用套餐专属 APN 时，"
                           + "先选地区再点对应那一家；虚拟运营商在「自定义」里填 APN。"
                         : "模块连上以后才能点。卡还没认到也不影响 —— 选地区、"
                           + "点哪一家就按哪一家配置。") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        ForEach(OperatorRegion.allCases) { region in
                            let active = operatorRegion == region
                            Button(region.rawValue) { operatorRegion = region }
                                .label(9)
                                .buttonStyle(.plain)
                                .foregroundStyle(active ? Theme.phosphorInk : Theme.ink)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3.5)
                                .background(
                                    Capsule()
                                        .fill(active ? Theme.phosphorInk.opacity(0.14) : Theme.chromeHi)
                                        .overlay(
                                            Capsule().strokeBorder(
                                                active ? Theme.phosphorInk.opacity(0.75)
                                                       : Theme.chromeEdgeStrong,
                                                lineWidth: 1.2))
                                )
                        }
                    }

                    switch operatorRegion {
                    case .auto:
                        autoOperatorControl
                    case .mainland:
                        operatorButtons(CarrierCatalog.mainlandChina)
                    case .hongKong:
                        operatorButtons(CarrierCatalog.hongKong)
                    case .custom:
                        customAPNControl
                    }
                }
            }

            Divider()

            SetupRow(title: "套餐总量",
                     help: "填这个周期的总流量（GB），主面板按它画用量进度；"
                         + "留空则主面板显示信号强度。") {
                HStack(spacing: 6) {
                // 占位符必须自带颜色。原来写的是 `TextField("GB", …)`，占位
                // 用的是系统占位灰，套上点阵字之后落在系统白框里几乎看不见
                // ——2026-09-26 的截图放大两倍才勉强认出那两个字，客户第一眼
                // 看到的是一个空框。单位挪到框外做常驻标签，框里只留一个示例
                // 数字，并显式给它 `inkSoft`（4.7:1，和白框分得开）。
                    TextField("", text: $quotaText)
                        .textFieldStyle(.roundedBorder)
                        .label(12)
                        .foregroundStyle(Theme.ink)
                        .frame(width: 58)
                        .ownPlaceholder("100", size: 12, shows: quotaText.isEmpty)
                    Text("GB").label(10).foregroundStyle(Theme.inkNote)
                    RowButton("保存") { model.quotaGB = Double(quotaText) ?? 0 }
                }
            }

            SetupRow(title: "开机自启",
                     help: "重启电脑后自动运行，来电和短信才收得到。") {
                Button {
                    model.setStartAtLogin(!model.startAtLogin)
                } label: {
                    HStack(spacing: 7) {
                        Text(startAtLoginNote)
                            .label(9)
                            .foregroundStyle(model.startAtLogin ? Theme.inkNote : Theme.alertInk)
                        PipSwitch(isOn: model.startAtLogin)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if model.isInteractiveSim {
                Divider()
                SimulatorSection()
            }

            Divider()

            // 底部这截小字收进抽屉：前半段是模块自己报的诊断，后半段是这个
            // App 干过什么。以前它一直摊在窗口最下面 120pt，9pt 灰字糊成一片，
            // 而客户要的只是「有没有报错」—— 所以默认只看标题，点开才铺出来。
            LogDrawer(title: "运行日志", hint: logHint, expanded: $showLog) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.controller.data.diagnostics(), id: \.self) { line in
                            Text(line).label(9).foregroundStyle(Theme.phosphor)
                        }
                        ForEach(model.activity.prefix(12), id: \.self) { line in
                            Text(line).label(9).foregroundStyle(Theme.phosphor.opacity(0.72))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
            }

            Divider()

            // 临时的一截：只读查看页。不需要了就删掉这两行和 `RemoteDebug.swift`，
            // 别处没有牵连。
            RemoteDebugSection(expanded: debugExpanded)
        }
        .padding(14)
        .frame(width: 380)
        .background(Theme.chrome)
        .onAppear {
            quotaText = model.quotaGB > 0 ? String(format: "%g", model.quotaGB) : ""
            model.refreshStartAtLogin()
            // 「通话语音」那一格要如实反映模块现状。这是只读的一次体检
            // （`ModuleVoiceSetup.inspect()` 不动模块上的任何东西）。
            model.refreshVoiceSetup()
        }
    }

    /// 「启用并重启模块」停上去看的那段话。
    ///
    /// 这页的规矩是「看得见的只有功能名，怎么用写在悬停里」，所以原本摊在
    /// 按钮上下那几段（点一下会重启、不用等卡、已经开好了）全挪到这里。
    private var enableHelp: String {
        var lines = ["把联网和声音两样一次写好。模块会重启一次，约二十秒。"]
        if let preCard = model.preCardSetupNote {
            lines.append(preCard)
        } else if fullFunctionReady {
            lines.append("现在两样都已经开好了，插上卡就能用。")
        }
        return lines.joined(separator: "\n")
    }

    /// 「现在这一行的按钮能不能按」：没连模块、正在打电话、正忙、正在补语音
    /// —— 四件事里任意一件都让这些按钮按不动。原来这段判断在每一行里抄了
    /// 一遍，四处各写一遍迟早会有一处漏改。
    private var canChangeModule: Bool {
        model.isConnected && !model.call.state.isBusy
            && !model.isWorking && !model.voiceRepairing
    }

    /// 一行按钮的右侧小字，念的是「开着会怎样 / 关着会丢什么」，不是开关本身。
    private var startAtLoginNote: String {
        model.startAtLogin
            ? "重启后自动运行"
            : "重启后不会自动运行"
    }

    /// 收起时也要看得出「里面有没有东西」：一个空的抽屉和一个装着报错的
    /// 抽屉长得一样的话，客户不会知道值不值得点开。
    private var logHint: String {
        let lines = model.controller.data.diagnostics().count + min(model.activity.count, 12)
        return lines == 0 ? "暂无记录" : "\(lines) 行"
    }

    /// 正在用的那家点亮，其余压暗 —— 四个按钮长得一模一样，客户点完要知道
    /// 到底落在哪一家上。
    private func apnTint(for carrier: Carrier) -> Color {
        // 不要再叠一层透明度：胶囊自己已经 `.opacity(0.55)` 压过一道，
        // 这里再来一次就是 0.25，四个运营商名字会淡到只剩影子。
        guard model.isConnected else { return Theme.inkNote }
        return apnActive(for: carrier) ? Theme.phosphorInk : Theme.ink
    }

    /// 这一家是不是当前生效的那家（用于胶囊描边/填充）。没连模块时一律不算
    /// 「生效」—— 那时候读回来的 APN 还是上一次的缓存，点亮它是在骗人。
    private func apnActive(for carrier: Carrier) -> Bool {
        model.isConnected
            && carrier.matches(apn: model.data.apn)
    }

    /// 自动识别：一个按钮按下就用「卡归属运营商」配 APN；旁边一行字把当前
    /// 认到的卡和网络摆出来，让客户知道程序看到了什么。
    @ViewBuilder
    private var autoOperatorControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RowButton(model.isConnected ? "自动识别" : "自动识别", isEnabled: model.isConnected) {
                    model.applyCarrierAPN(force: true, carrier: nil)
                }
                Text(autoDetectCaption)
                    .label(9)
                    .foregroundStyle(Theme.inkNote)
            }
        }
    }

    private var autoDetectCaption: String {
        let home = model.sim.homeCarrier
        if home.apn.isEmpty {
            let current = model.network.carrier.name
            return current.isEmpty ? "还没认到运营商" : "驻留网络：\(current)"
        }
        let roaming = model.network.isRoaming ? "（漫游）" : ""
        let current = model.network.carrier.name
        var text = "SIM 归属：\(home.name)\(roaming)"
        if !current.isEmpty, current != home.name { text += " · 驻留：\(current)" }
        return text
    }

    /// 一列运营商按钮，每个写自己的 APN。
    @ViewBuilder
    private func operatorButtons(_ carriers: [Carrier]) -> some View {
        HStack(spacing: 5) {
            ForEach(carriers, id: \.self) { carrier in
                let active = apnActive(for: carrier)
                Button(carrier.shortName) { model.applyCarrierAPN(force: true, carrier: carrier) }
                    .label(9)
                    .buttonStyle(.plain)
                    .disabled(!model.isConnected)
                    .foregroundStyle(apnTint(for: carrier))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(
                        Capsule()
                            .fill(active ? Theme.phosphorInk.opacity(0.14) : Theme.chromeHi)
                            .overlay(
                                Capsule().strokeBorder(
                                    active ? Theme.phosphorInk.opacity(0.75)
                                           : Theme.chromeEdgeStrong,
                                    lineWidth: 1.2))
                    )
                    .opacity(model.isConnected ? 1 : 0.55)
                    .help("按 \(carrier.name) 配置上网参数（\(carrier.apn)）")
            }
        }
    }

    /// 自定义 APN：给香港虚拟运营商、或套餐 APN 与默认不同的卡。
    @ViewBuilder
    private var customAPNControl: some View {
        HStack(spacing: 6) {
            TextField("", text: $customAPN)
                .textFieldStyle(.plain)
                .ownPlaceholder("例如 mobile.lte.three.com.hk", size: 12,
                                shows: customAPN.isEmpty)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.chromeHi)
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Theme.chromeEdgeStrong, lineWidth: 1))
                )
            RowButton("保存", isEnabled: model.isConnected && !customAPN.isEmpty) {
                model.applyCustomAPN(customAPN)
            }
        }
    }
}

/// 设置页每一行的骨架：左边功能名，右边控件。
///
/// 2026-09-27 之前这页是「一行功能 + 一段两三行的灰字」，一屏九段 —— 用户的
/// 原话是「按钮没几个，全是字」。现在一行只说一样东西，为什么 / 什么时候用
/// 写进 `.help`：鼠标停上去才展开，停在页面上就是干净的几行。
///
/// `note` 是留给「这一行现在的状态」的（插手机没声音 / 还没装好 / 先连上模块），
/// 也是九个字以内 —— 再长就又变回段落了。
private struct SetupRow<Trailing: View>: View {
    var title: String
    var note: String = ""
    var help: String = ""
    @ViewBuilder var trailing: Trailing

    var body: some View {
        content
    }

    // `.help("")` 会挂出一个空的白框，比没有提示还糟，所以没词的时候干脆
    // 不加这个修饰器。
    @ViewBuilder private var content: some View {
        if help.isEmpty {
            row
        } else {
            row.help(help)
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Text(title).label(11).foregroundStyle(Theme.ink)
            if !note.isEmpty {
                Text(note).label(9).foregroundStyle(Theme.inkNote).lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing
        }
    }
}

/// 设置页里的动作按钮。
///
/// 比面板上那颗 `PillButton` 小一号：一屏里最多出现两颗，是二级动作，
/// 不该跟顶上「启用并重启模块」那颗主按钮抢。样子沿用面板的白药丸 ——
/// 同一套视觉语汇，客户不用重新学哪个是能按的。
private struct RowButton: View {
    private let title: String
    private let isEnabled: Bool
    private let action: () -> Void

    init(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).label(10)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Theme.chromeHi)
                        .overlay(Capsule().strokeBorder(Theme.chromeEdgeStrong, lineWidth: 1.1))
                        .shadow(color: .black.opacity(0.10), radius: 1.5, y: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        // 灰掉而不是藏起来：客户至少知道「这里有东西，只是现在动不了」。
        .opacity(isEnabled ? 1 : 0.55)
    }
}

/// The controls that exist only under `--sim`.
///
/// A ring and an unread badge are the two things this app is for, and neither
/// can be produced without a card in a module — so without this block the two
/// paths that matter most are the two that can never be walked on a bench. The
/// buttons drive the in-memory module directly.
///
/// The block is keyed off `isInteractiveSim`, not off `simulator`: the
/// offscreen renderer is a simulator too, and the screenshots it produces go to
/// customers, so they must keep showing the window as it really is.
private struct SimulatorSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("模拟器").label(11).foregroundStyle(Theme.ink)
                Spacer()
                Text("不接模块、也不改本机网络").label(9).foregroundStyle(Theme.inkNote)
            }
            Text("这个 App 是用 --sim 启动的：模块由内存里的模拟件代替，所以来电和短信" 
                 + "都可以手动造出来。正常启动时这里不会出现。")
                .label(9).foregroundStyle(Theme.inkNote)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                simButton("来一条短信", "envelope") { model.simulateIncomingSMS() }
                simButton("模拟来电", "phone.arrow.down.left") { model.simulateIncomingCall() }
                simButton("对方挂断", "phone.down") { model.simulateRemoteHangup() }
            }
        }
    }

    private func simButton(_ title: String, _ glyph: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: glyph).font(.system(size: 9, weight: .semibold))
                Text(title).label(10)
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.chromeEdge.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }
}
