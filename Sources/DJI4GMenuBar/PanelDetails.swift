import SwiftUI
import DJI4GCore

/// The line that turns "未插卡" into an action.
///
/// The field itself only has room for the short label, and a customer who has
/// already pushed a card in reads 未插卡 as the app being wrong rather than as
/// the card not being seated. The next step belongs on screen, not only in the
/// console. The wording comes from `SIMStatus` so the panel and the CLI cannot
/// drift apart.
struct SIMHint: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // 两句话，一红一灰：红的说卡怎么了，灰的说卡还没插的这几天能先做
        // 什么。只写前一句，客户会以为整个模块在等卡 —— 而 USB 网卡和通话
        // 音频正好相反，是趁没插卡的时候做才不折腾。
        VStack(alignment: .leading, spacing: 3) {
            if !model.isConnected {
                // 「没插卡」和「没插模块」是两件事。模块没上电的时候它一个字
                // 都没报告过，卡座检测也就无从谈起；这时要是接着念卡座的台
                // 词，客户会去拆一个还没插上的模块。这一句不是报错，所以不
                // 上红色。
                Text("模块未连接 · 插到 Mac 的 USB 口")
                    .label(9)
                    .foregroundStyle(Theme.inkNote)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("直插 Mac 的 USB 口，别经过扩展坞。插上后这里会自动出现卡和网络状态。")
            } else {
                if !model.sim.ready, !model.sim.guidance.isEmpty {
                    Text("SIM \(model.sim.shortLabel)：\(model.sim.guidance)")
                        .label(9)
                        .foregroundStyle(Theme.alertInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let note = model.preCardSetupNote {
                    Text(note)
                        .label(9)
                        .foregroundStyle(Theme.inkNote)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// `NETWORK` tab — what the modem is attached to and how much it has moved.
struct NetworkDetail: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // 这一页是打开面板时的默认页，卡的问题必须先于一切出现。
            SIMHint()
            // 十二格读的是一个**表**：栏要竖着对齐，还要把整行用完。
            //
            // 2026-09-28 之前每一行写成 `Field / Spacer / Field / Spacer /
            // Field`，三格的起点由各自的内容决定（中栏差 12pt、右栏差 55pt，
            // 放大真机截图量出来的）—— 读一列数字时每换一行都要重新找一次
            // 起点，眼睛得来回横跳。之后换成 `Grid`，栏是对齐了，可栏宽是内容
            // 量出来的：最长的一格是 `192.168.225.23`，整张表就停在 216pt 处，
            // 右边空掉一百来点。2026-09-30 客户一句「右边留白太多，重新排版
            // 整理」说的就是这个。
            //
            // 现在是写死的三栏：85 / 85 / 130，间隔 10pt，加起来正好 320pt =
            // 正文宽。最宽的那栏留给每一行最长的一串（频段 / 连接方式 / IPv4）,
            // 也是 13pt 的纯拉丁值唯一放得下的地方（见 `Field.valueSize`）。
            tableRow(Field(caption: "注册", value: registered),
                     Field(caption: "制式", value: model.network.accessTechnology.isEmpty
                           ? "--" : model.network.accessTechnology),
                     Field(caption: "频段", value: model.network.band.isEmpty
                           ? "--" : model.network.band))
            // SIM 归属（卡是哪家的）与当前驻留网络（现在连到哪家）分开摆：
            // 香港卡在大陆漫游时这两格会不一样，不能混成一个「运营商」。
            tableRow(Field(caption: "SIM 归属",
                           value: model.sim.homeCarrier.apn.isEmpty
                               ? "--" : model.sim.homeCarrier.shortName),
                     Field(caption: "当前网络",
                           value: model.network.carrier.name.isEmpty
                               ? "--" : model.network.carrier.shortName),
                     Field(caption: "漫游",
                           value: model.isConnected
                               ? (model.network.isRoaming ? "漫游中" : "本地")
                               : "--"))
            tableRow(Field(caption: "RSRP",
                           value: model.signal.rsrp.map { String(format: "%.0f dBm", $0) } ?? "--"),
                     Field(caption: "RSRQ",
                           value: model.signal.rsrq.map { String(format: "%.0f dB", $0) } ?? "--"),
                     Field(caption: "SINR",
                           value: model.signal.sinr.map { String(format: "%.1f dB", $0) } ?? "--"))
            // 两个来源要分清楚：模块里真有的那个（`data.apn`，连上时读过一次），
            // 和「按运营商该用的那个」（`carrier.apn`）。前者是事实，后者只是
            // 提示；混在一起写会让人以为已经配好了 —— 于是面板看起来一切正常，
            // 却怎么都上不了网。
            //
            // 2026-09-30 复核：这一格原来写着 `APN` / `APN（待写入）`，是给排障
            // 看的英文缩写，客户界面里不该出现。改成「接入点」；没写进模块的
            // 时候值直接说「待写入」，不再拿「该用的那串」冒充「已有的那串」。
            tableRow(Field(caption: "接入点",
                           value: model.data.apn.isEmpty
                               ? (model.network.carrier.apn.isEmpty ? "--" : "待写入")
                               : model.data.apn),
                     Field(caption: "接口", value: model.data.interfaceName.isEmpty
                           ? "未找到" : model.data.interfaceName),
                     // 这一格说的是模块的 USB 网卡按哪一档工作，词就用设置页上那
                     // 两个字（Mac 版 / 移动版）。读不出来就写 `--`：模块自己报的
                     // 那一串是给排障看的，客户在面板上读到「这台 Mac（推荐）」这种
                     // 半句话说不出结论，反而要去设置页里找那个已经不存在的下拉。
                     Field(caption: "连接方式", value: model.hostModeNow?.label ?? "--"))
            tableRow(Field(caption: "下行", value: bytes(model.data.bytesIn)),
                     Field(caption: "上行", value: bytes(model.data.bytesOut)),
                     Field(caption: "IPv4", value: model.data.ipv4Address.isEmpty
                           ? "--" : model.data.ipv4Address))
            // The interface can be up and hold an address while macOS still
            // routes nothing over it, so the service gets its own row rather
            // than being folded into "接口".
            HStack {
                // Red only when there is something to fix: no interface at all
                // just means the module is unplugged, which is not an error.
                Field(caption: "Mac 网络服务",
                      value: model.data.serviceLabel,
                      tint: model.data.serviceEnabled
                          ? Theme.phosphorInk
                          : (model.data.hasInterface ? Theme.alertInk : Theme.inkNote))
                Spacer()
                if model.data.hasInterface {
                    // 「开关」这个词说的是一个**东西**，不是一个动作：客户读到
                    // 它不知道按下去会发生什么；它又被 `Spacer()` 推到整行最右，
                    // 和左边的「Baiwang 已启用」隔着一整个面板宽 —— 2026-09-26
                    // 放大截图里，它就是一行没人管的灰字，紧贴在底部图标条上面。
                    //
                    // 改成写出动作的胶囊按钮：亮着的时候按下去是「停用」，熄着的
                    // 时候按下去是「启用」，按之前就知道结果。它自己也有边框和面，
                    // 和上面那排 刷新 / 数据开 / 自动联网 是同一族的白色塑料件，客户
                    // 一眼认得出这是能点的东西。
                    Button {
                        model.setHostService(!model.data.serviceEnabled)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: model.data.serviceEnabled
                                  ? "pause.circle" : "play.circle")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(model.isWorking ? "处理中"
                                 : (model.data.serviceEnabled ? "停用" : "启用")).label(9)
                        }
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Theme.chromeHi)
                                .overlay(Capsule().strokeBorder(Theme.chromeEdgeStrong,
                                                                lineWidth: 1))
                        )
                    }
                    .buttonStyle(.plain)
                    // 跑在 `run(…)` 里，中途 `isWorking` 会亮；那一秒里再按一次
                    // 只会被拒，所以直接锁上。
                    .disabled(model.isWorking)
                    .help(model.data.serviceEnabled
                          ? "停用 macOS 里这条网络服务，默认路由回到 Wi-Fi"
                          : "启用 macOS 里这条网络服务，流量改走模块")
                }
            }
        }
    }

    /// 表格的一行。三栏宽度钉在这里（85 / 85 / 130 + 10pt 间隔 = 320pt），
    /// 行与行之间才真的对得齐 —— 交给 `Spacer()` 会按内容漂，交给 `Grid`
    /// 会按内容算宽，两种都把右边空出一大块。
    @ViewBuilder
    private func tableRow(_ first: Field, _ second: Field, _ third: Field) -> some View {
        HStack(alignment: .top, spacing: 10) {
            first.frame(width: 85, alignment: .leading)
            second.frame(width: 85, alignment: .leading)
            third.frame(width: 130, alignment: .leading)
        }
    }

    private var registered: String {
        // 模块没插的时候，卡和注册都还无从谈起。这一格要是写「未知」，读起来
        // 像是模块回了一句听不懂的话，而事实是模块根本不在。
        guard model.isConnected else { return "未连接" }
        // "未插卡" and "未就绪" are different jobs for the user: the first one
        // means opening the module, the second one means waiting.
        guard model.sim.ready else { return model.sim.shortLabel }
        // 看分组域：LTE 上网由 `AT+CEREG?` 说话，电路域那句「被拒绝」
        // 属于通话，不该出现在「能不能上网」这一格里。
        return model.network.dataRegistered ? "已注册" : "未注册"
    }

    private func bytes(_ value: UInt64) -> String {
        let size = Double(value)
        if size >= 1_000_000_000 { return String(format: "%.2f GB", size / 1_000_000_000) }
        if size >= 1_000_000 { return String(format: "%.1f MB", size / 1_000_000) }
        if size >= 1_000 { return String(format: "%.0f KB", size / 1_000) }
        return "\(value) B"
    }
}

/// `MODULE` tab — identity, thermals, and the USB composition that decides
/// whether call audio can exist at all.
struct ModuleDetail: View {
    @EnvironmentObject private var model: AppModel

    /// 这一页上的每一格都是「模块现在报了什么」。断开以后 `identity` / `sim` /
    /// `data` 里留着的是上一次的读数，而同一屏底下正写着「模块未连接」——
    /// 两句话摆在一起，客户会以为温度、IMEI、存储这些数字还是活的。见
    /// `AppModel.liveIdentity`：一律经这里取，读不到就 `--`。
    private var live: ModuleIdentity? { model.liveIdentity }
    private var composition: USBComposition? { model.isConnected ? model.data.composition : nil }

    /// 「没有模块」和「模块没报这一项」对客户是同一件事：这一格没有值。
    private func text(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "--" }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Field(caption: "型号", value: text(live?.model)).column()
                Field(caption: "版本", value: text(live?.revision)).column()
            }
            HStack {
                Field(caption: "IMEI", value: text(live?.imei)).column()
                Field(caption: "本机号码",
                      value: model.isConnected ? text(model.sim.ownNumber) : "--").column()
            }
            HStack {
                Field(caption: "温度", value: heat)
                Spacer()
            }
            HStack {
                // 这一格原来直接把模块的七位开关摆在客户眼前：`USB 组态
                // 1,1,1,1,1,0,1`。客户读不出这是好是坏，只会以为屏幕上
                // 有个东西坏着。他要的只有一件事 —— 插上电脑能不能上网，
                // 所以这里改成同样一句话的网卡版，原始那串数字挪进悬停
                // 提示，运行日志里照旧有一份（支持时要念的就是那一份）。
                Field(caption: "电脑网卡",
                      value: composition.map { $0.network ? "已开启" : "未开启" } ?? "--",
                      tint: Theme.ink)
                    .help(composition.map { "模块内部参数 \($0.flagString)（一般不用管）" } ?? "")
                    .column()
                // 这一栏以前叫「通话音频」，没开的时候还标成红的 —— 客户照着
                // 理解成「电话坏着，去开一下就好」，开完打过去还是没声音，因为
                // 声卡只是载体，语音通路要另外装一次（见 `ModuleVoiceSetup`）。
                // 现在它只说事实：声卡有没有被写进 USB 组态。拨号、接听、收发
                // 短信都跟它无关。
                Field(caption: "模块声卡",
                      value: composition.map { $0.supportsVoice ? "已开启" : "未开启" } ?? "--",
                      tint: Theme.ink)
                    .help(composition.map { "模块内部参数 \($0.flagString)（一般不用管）" } ?? "")
                    .column()
            }
            if composition?.supportsVoice == false {
                Text("未开启不影响拨号、接听、短信")
                    .label(9)
                    .foregroundStyle(Theme.inkNote)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("它只决定模块要不要给电脑显示一张声卡；通话语音要另外装一次，见「通话」窗口。")
            }
            HStack {
                Field(caption: "SIM", value: model.isConnected ? model.sim.shortLabel : "--").column()
                Field(caption: "存储", value: model.isConnected ? model.controller.sms.storage.label : "--").column()
            }
            // ICCID 以前只画后 8 位（`suffix(8)`），标题却写着「ICCID」——
            // 客户拿它跟卡上印的那串对，对不上，就会以为模块读错了卡。
            // 这一格存在的意义就是把卡念给运营商听，后 8 位念不出卡，所以改成
            // 整串，并让它独占一行：20 位放在原来那个三分之一栏里会被截成
            // 「8986032504…」，比只显示后 8 位更糟。
            Field(caption: "ICCID",
                  value: model.isConnected ? text(model.sim.iccid) : "--")
            SIMHint()
        }
    }

    /// 温度是三个端点各报一个，`59 / 52 / 52 °C`。断线时 `live` 是 nil。
    private var heat: String {
        guard let temperatures = live?.temperatures, !temperatures.isEmpty else { return "--" }
        return temperatures.joined(separator: " / ") + " °C"
    }
}

/// `SMS` tab — the mailbox plus the compose row.
struct SMSDetail: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: SMSMessage?
    @State private var draft = ""
    @State private var recipient = ""
    @State private var confirmingClear = false
    @State private var status: String?
    /// 按了「回复」之后光标落在内容框里 —— 回复的全部意义就是接着打字，
    /// 客户不该再自己去点一次那个框。
    @FocusState private var draftFocused: Bool

    /// 出图夹具用：面板一打开就把某一条摊开，省得为了给「点开的样子」出一张
    /// 图去模拟一次点击。真机路径上永远是 nil。
    init(initialSelected: SMSMessage? = nil) {
        _selected = State(initialValue: initialSelected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 短信存在模块里而不是卡里，所以收件箱里可能有旧短信 —— 提示不能
            // 挂在"收件箱为空"那一支上。
            SIMHint()
            if let selected {
                // 点开后的全文卡片。
                //
                // 它原来是一块黑屏加荧光绿，穿的是模块那几块小屏的衣服。可
                // 读一条短信跟读一串信号值不是一回事：客户在这里是读信，不是
                // 读仪表。2026-09-30 的原话是「点开后的字体也换成黑色就行，
                // 不用绿色」—— 换成面板上那层白塑料，字全用 `ink` 那支黑
                // （白底 17.5:1），发件人、时间、关闭键跟着从荧光绿挪到黑 /
                // 灰。整张卡片上只剩未读那盏绿点还带着颜色。
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(selected.sender)
                            .reading(SMSFont.body, .semibold)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(2)
                            .layoutPriority(1)
                        Spacer()
                        Text(timeText(selected))
                            .reading(SMSFont.meta)
                            .foregroundStyle(Theme.inkNote)
                        // 命中区不能跟着字形走：这里是关掉全文卡片唯一的出口，
                        // 2026-09-25 用鼠标实测连点几次都打不中 —— 客户只会
                        // 以为「点不动」。外框看不见，只把命中区放大。
                        Button {
                            self.selected = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.inkSoft)
                        .help("关闭")
                    }
                    SMSBody(text: selected.text)
                    // 「回复」摆在正文下面：客户读完一条短信，下一个动作十有
                    // 八九就是这个。按下去对方号码自动填进下面的输入框、光标
                    // 也跟过去 —— 中间那两步（抄号码、点输入框）不用他做。
                    HStack(spacing: 6) {
                        Spacer()
                        Button { reply(to: selected) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrowshape.turn.up.left.fill")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("回复").reading(11.5, .medium)
                            }
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Theme.chrome)
                                    .overlay(Capsule().strokeBorder(Theme.chromeEdgeStrong,
                                                                    lineWidth: 1))
                            )
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("回复这条短信：对方号码自动填进下面的输入框")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.chromeHi)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Theme.chromeEdgeStrong, lineWidth: 1)
                        )
                )
            } else if model.messages.isEmpty {
                // 模块没连上的时候，同一个 `VStack` 顶上的 `SIMHint` 已经说过
                // 「把模块插到 Mac 的 USB 口」了。这里再补一句「未连接模块」是
                // 同一页里两句话讲同一件事 —— 客户会以为其中一句在说别的故障，
                // 而收件箱是不是空的，没连上模块本来就无从知道。
                if model.isConnected {
                    Text("收件箱为空").reading(11.5).foregroundStyle(Theme.inkNote)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.messages, id: \.storageIndex) { message in
                            Button {
                                selected = message
                            } label: {
                                // 一行拆成两行：上面是「谁发的 + 什么时候」，
                                // 下面是正文开头。
                                //
                                // 原来三样东西挤在一条 15pt 高的线上（发件人
                                // 10pt、正文 9pt、时间 8pt）。线上再怎么放大都
                                // 是三种字号互相压，预览正文只剩得到 120pt ——
                                // 十来个汉字就断，最该读的那一行反而最短。
                                // 2026-09-30 客户的原话是「这里字体太小了，
                                // 大一点。看不清」。拆开之后两行各占一个整宽，
                                // 字号跟着抬到能读的大小，号码和时间也不再跟
                                // 正文抢那点宽度。
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(message.isUnread ? Theme.phosphorInk : .clear)
                                            .frame(width: 5, height: 5)
                                        Text(message.sender)
                                            .reading(SMSFont.row, .medium)
                                            .foregroundStyle(Theme.ink)
                                            .lineLimit(1)
                                            .layoutPriority(1)
                                        Spacer(minLength: 6)
                                        // 时间钉成固定宽度：`21:11` 和 `09-24`
                                        // 都是 5 个字符，对齐成一列以后扫下去
                                        // 不用一个字一个字读。
                                        Text(timeText(message))
                                            .reading(SMSFont.meta)
                                            .foregroundStyle(Theme.inkNote)
                                            .frame(width: 42, alignment: .trailing)
                                    }
                                    // 第二行跟着发件人的起点缩进 10pt（那颗点
                                    // 5pt 加 5pt 间隔），两行才不各起各的。
                                    Text(message.text.replacingOccurrences(of: "\n", with: " "))
                                        .reading(SMSFont.row)
                                        .foregroundStyle(Theme.inkSoft)
                                        .lineLimit(1)
                                        .padding(.leading, 10)
                                }
                                // 行高钉死，不让字体自己撑。见 `listHeight` 的说明。
                                .frame(height: Self.listRowHeight, alignment: .center)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("回复") { reply(to: message) }
                                Button("删除") { model.deleteSMS(message) }
                            }
                            // 两行一组的排版里，两条短信之间只靠 2pt 间距分隔
                            // 太弱了：预览那行是 `inkSoft`，一条的正文压到下一
                            // 条的发件人上，扫起来会连成一片。补一条极浅的分隔
                            // 线（比边框再淡一半），分组立刻出来，又不至于把
                            // 收件箱画成表格。最后一条不画，免得贴着「清空」。
                            //
                            // 线用 `overlay` 叠在行底，不占高度。写成 `VStack`
                            // 里的兄弟视图时，10 行会变成 10×38 + 9×1 = 389pt，
                            // 而 `listHeight` 给的是 380 —— 第 10 行正好被切掉
                            // 一行正文（2026-09-30 出图实测）。行高既然钉死，
                            // 这条线也只能落在行内。
                            .overlay(alignment: .bottom) {
                                if message.storageIndex != model.messages.last?.storageIndex {
                                    Rectangle()
                                        .fill(Theme.chromeEdge.opacity(0.5))
                                        .frame(height: 1)
                                        .padding(.leading, 10)
                                }
                            }
                        }
                    }
                }
                // 高度得自己算，不能只写上界。
                //
                // 面板是 `MenuBarExtra` 的下拉，窗口大小按「内容的理想高度」定，
                // 而 `ScrollView` 的理想高度是 0 —— 只给一个上界，整个收件箱会被
                // 压成一条线：卡片上写着「6 条」，下面却是空的，两行输入框直接贴
                // 上来（2026-09-25 实测）。按条数给出确定高度，窗口才会把它算进去。
                .frame(height: Self.listHeight(count: model.messages.count))

                // 短信存在模块里，换卡也不会换掉它 —— 转手出去的模块，客户
                // 一插上就看到上一位机主的验证码和营销短信。逐条删要删十几下，
                // 所以给一个一次清干净的口子。位置贴着列表右下角，不抢写信框
                // 的视线。
                //
                // 二次确认用的是「按钮自己改字」而不是 `alert`：这一页活在
                // `MenuBarExtra` 的下拉里，模态弹窗在那个容器里点不到确认键
                // （点了没反应，客户只会以为 App 卡死）。改字这种两段式在
                // 下拉面板里一定能用，而且不用另起一层。
                HStack {
                    Spacer()
                    Button(confirmingClear ? "再点一下，清空 \(model.messages.count) 条" : "清空收件箱") {
                        if confirmingClear {
                            confirmingClear = false
                            model.clearSMS()
                        } else {
                            confirmingClear = true
                        }
                    }
                    .reading(11)
                    .buttonStyle(.plain)
                    .foregroundStyle(confirmingClear ? Theme.phosphorInk : Theme.inkNote)
                    .help("删掉模块里存着的全部短信，卡上的不受影响")
                }
                .padding(.top, 2)
            }

            HStack(spacing: 4) {
                // 占位符必须自带颜色，理由和设置页那个「100」一样：不写就是系统
                // 占位灰，落在白框里只有 1.8:1 —— 面板上最淡的一处，而它是
                // 客户填第一格时要读的字（2026-09-26 夜里的截图实测）。
                TextField("", text: $recipient)
                    .textFieldStyle(.roundedBorder)
                    .reading(12)
                    .frame(width: 100)
                    .ownPlaceholder("对方号码", size: 12, shows: recipient.isEmpty)
                // 「UCS-2」是编码器的内部叫法，客户读到的是天书；他真正需要知道的
                // 只有一件事：中文写长了会分成几条发出去（也就按几条算钱）。
                // 那句话收进悬停 —— 框里只留「短信内容」四个字。
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .reading(12)
                    .focused($draftFocused)
                    .ownPlaceholder("短信内容", size: 12, shows: draft.isEmpty)
                    .onSubmit(send)
                    .help("中文写长了会分成几条发出去，也就按几条算钱。")
                // 同理：发送的唯一入口，命中区跟着字形大的话也是一枚点不中的小点。
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.ink)
                .disabled(draft.isEmpty || recipient.isEmpty)
                .help("发送")
            }
            if let status {
                Text(status).reading(11).foregroundStyle(Theme.inkNote)
            }
            // 收件箱下面这一行，是「存储满」这个哑巴故障唯一的可见处。
            //
            // 模块自己只有 23 个格子，满了以后网络把新短信**直接丢掉**：发的
            // 人那边一切正常，面板不报错，客户只会觉得「最近没人给我发短信」。
            // 说明书里承诺「SMS 小屏里能看到存储几分之几」——那句话得是真的，
            // 所以数字放在客户已经在看的这一页，而不是隔壁 MODULE 页。
            //
            // 平时只是一枚灰色的「存储 6/23」，只有快满和已满才变红并把「右键
            // 删除」说出来：删除藏在右键菜单里，界面上没有按钮，而需要删的时候
            // 正是最不能让人去找的时候。
            if let storage = storageNote {
                Text(storage.text)
                    .reading(10.5)
                    .foregroundStyle(storage.tint)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// 存储一行的文案与颜色。`total == 0` 表示还没问过模块（`AT+CPMS?` 没回
    /// 话），这时什么都不说 —— 编一个「0/0」出来只会让客户以为格子没了。
    ///
    /// 2026-09-26：这一行现在还负责把「条数」和「格数」两个口径讲清楚。
    /// 真机上卡在 6 条 / 7 格上查了半晚 —— 小屏写着「SMS / 6 条」，底下写着
    /// 「存储 7/40」，中间那条短信像是丢了。实际是 slot 3 和 slot 4 是同一组
    /// 长短信（UDH ref 0x10，2 段），`assemble` 把它们合成一条显示，所以
    /// **条数比格数少 1 是对的**。数据没丢，问题出在两个数并排出现却对不上时，
    /// 界面一句话都不解释 —— 客户只能自己去猜哪条不见了。
    ///
    /// 所以：格数对得上就什么都不加（正常情况一个字都不多）；格数多出来的部分
    /// 是长短信占的，就说「长短信占 N 格」；真的是有 PDU 解不开导致对不上，
    /// 那是丢数据，要报警不能让客户以为只是长短信。
    private var storageNote: (text: String, tint: Color)? {
        // 断线时 `storage` 里是上一次问到的数字（见 `AppModel.liveIdentity`）。
        // 上面刚说完「模块未连接」，下面还报「存储 7/40」，客户会去删一条
        // 早就不在那儿的短信，然后以为删除坏了。
        guard model.isConnected else { return nil }
        let storage = model.controller.sms.storage
        guard storage.total > 0 else { return nil }

        let note = reconciliation
        if storage.isFull {
            return ("存储 \(storage.label) 已满，新短信会被丢掉 · 右键旧短信可删除" + note.suffix,
                    Theme.alertInk)
        }
        if storage.total - storage.used <= 3 {
            return ("存储 \(storage.label) 将满 · 右键旧短信可删除" + note.suffix, Theme.alertInk)
        }
        return ("存储 \(storage.label)" + note.suffix,
                note.isAlarm ? Theme.alertInk : Theme.inkNote)
    }

    /// 「条数」和「格数」差在哪。见 `storageNote` 的说明。
    ///
    /// 两个数其实各说各话，都对：「条数」是客户数得出来的短信条数，「格数」是
    /// 模块收件箱被占掉的格子。长短信一条占两格，这两个数就差 1。
    ///
    /// 判据是**格数** `used` 对**格数账** `slots`（每条自己记的 `segmentCount`
    /// 之和）：这两个对不上才是真出事了 —— 有短信没进列表。对得上，那「条数」
    /// 比「格数」少就只剩长短信一个解释。（2026-09-26 第一版这里拿 slots 跟
    /// used 比去解释长短信，两个数在正常情况本来就相等，提示永远不出现 ——
    /// 渲染出来才发现。）
    private var reconciliation: (suffix: String, isAlarm: Bool) {
        let sms = model.controller.sms
        let used = storageUsed()
        let slots = model.messages.reduce(0) { $0 + $1.segmentCount }
        // 有 PDU 解不开：这是真的少了一条，先报这个。
        if !sms.decodeFailures.isEmpty {
            return (" · \(sms.decodeFailures.count) 条读不出来", true)
        }
        if slots != used {
            return (" · \(abs(slots - used)) 格对不上", true)
        }
        // 账对得上，剩下能解释「条数 < 格数」的只有长短信占的格子。
        let extra = used - model.messages.count
        if extra > 0 { return (" · 长短信占 \(extra) 格", false) }
        // 长短信只到了一半，会先按半条显示。等另一半到了自己会接上，所以只是提
        // 一句，不是故障。
        if model.messages.contains(where: \.isConcatenated) { return (" · 长短信未收全", false) }
        return ("", false)
    }

    private func storageUsed() -> Int { model.controller.sms.storage.used }

    /// 「回复」：把对方号码填进收件人那一格，光标送进内容框。
    ///
    /// 只填号码、不动草稿 —— 客户可能已经打了一半正准备发给别人，替他清空
    /// 是拿他的字换我的方便。这一条原来没有回复入口：要回一条短信，得先把
    /// 那串号码抄下来（`106903001234` 这种 12 位服务号在屏幕上还没法选中），
    /// 客户的原话是「每一条信息下面要加上回复功能」。
    private func reply(to message: SMSMessage) {
        recipient = message.sender
        status = nil
        draftFocused = true
    }

    private func send() {
        guard !draft.isEmpty, !recipient.isEmpty else { return }
        let body = draft
        status = "发送中…"
        model.sendSMS(text: body, to: recipient) { ok in
            status = ok ? "已发送" : "发送失败"
            if ok { draft = "" }
        }
    }

    /// 收件箱要的高度。
    ///
    /// 行高必须钉死在这里、并且真的加到每一行上（见列表里的 `.frame`）。
    /// 之前只按「一行 14pt」估算、行高交给字体撑：实测行距是 ≈14.35pt，
    /// 攒到 9 行时算出来的框正好落在第 9 行中间，半行字露在外面 ——
    /// 收件箱只有三五条时看不出来，塞到 23 条才现形（2026-09-25）。
    /// 现在高度永远是行高的整数倍，那条缝不存在了。
    ///
    /// 整数倍是严格整数倍，不留「再给 4pt 免得切字」的余量：行高既然钉死，
    /// 字就不会溢出自己那一行，而那 4pt 余量反而会在末尾露出下一行的字头
    /// （同样是塞满 23 条才看得见）。边界正好落在两行之间，两头都干净。
    /// 一行的高度：发件人那一行 16pt、正文那一行 15pt、中间 2pt，再加一点
    /// 余量。行里所有字号都归 `SMSFont` 管，改字号要回来看这里一眼。
    static let listRowHeight: CGFloat = 38
    /// 最多露 10 行，再多就滚动 —— 短信再多也不把面板顶到屏幕外面去。
    ///
    /// 6 → 10 是 2026-09-30 客户点名的（「列表增加到 10 条可以阅览」）：一行
    /// 拆成两行之后能同时读到的条数只有原来的三分之二，翻起来太碎。10 行
    /// 380pt 是面板还能站住的上限，再往上就要顶到屏幕外了。
    static let listVisibleRows = 10

    static func listHeight(count: Int) -> CGFloat {
        min(CGFloat(max(count, 1)), CGFloat(listVisibleRows)) * listRowHeight
    }

    /// 两个 `DateFormatter` 常驻，而不是每条消息现造一个：面板每次重画都要算
    /// 一遍时间，而 `DateFormatter` 的构造要读 locale 和时区，几百条短信时
    /// 这一项就能把首屏拖出肉眼可见的停顿。
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    private func timeText(_ message: SMSMessage) -> String {
        guard let timestamp = message.timestamp else { return "" }
        return Calendar.current.isDateInToday(timestamp)
            ? Self.clockFormatter.string(from: timestamp)
            : Self.dayFormatter.string(from: timestamp)
    }
}

/// 短信全文。短的照原样摊开，长的收进一块固定高度的滚动区。
///
/// 卡片高度不能被最长的那条短信牵着走：运营商的通知动辄两三百字，11pt 的
/// 正文在 296pt 宽的卡片里要排二十多行 —— 卡片自己长到屏幕外面，底下那排
/// 「清空 / 对方号码 / 短信内容」全被顶走，客户连回复的入口都看不到。
/// 超过十来行的正文收进 208pt 的滚动区，卡片高度到此为止。
private struct SMSBody: View {
    var text: String

    /// 280 字 ≈ 12 行（一行 24 个汉字）。短于这个数就不滚动 —— 能一眼看完
    /// 的短信不该多出一道滚动条。
    private static let scrollThreshold = 280
    private var isLong: Bool { text.count > Self.scrollThreshold }

    var body: some View {
        if isLong {
            ScrollView { bodyText }
                .frame(height: 208)
        } else {
            bodyText
        }
    }

    /// 名字不能叫 `body`：`View` 已经占了那一个，重名会让类型推导自相矛盾
    /// （编译器的原话是「ambiguous inference of associated type 'Body'」）。
    private var bodyText: some View {
        Text(text)
            .reading(SMSFont.body)
            .foregroundStyle(Theme.ink)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A raw AT console. Useful when a firmware revision answers differently from
/// what the parsers expect.
struct ConsolePanel: View {
    @EnvironmentObject private var model: AppModel

    /// 截图专用：AT 回显要按下「发送」之后才回来，而 `--render` 里没有人在
    /// 键盘前 —— 不塞一段进来的话，这块黑屏在截图里永远是空的，配色坏掉也
    /// 没人会看见。正常启动时是空串，行为不变。
    var seededOutput: String = ""
    /// 同样只给截图用：展开态的快捷指令抽屉平时要点一下才看得到。
    var presetsExpanded: Bool = false
    /// 也是给截图用的：USSD 的答案要真发一条 `AT+CUSD` 才回来，截图进程里
    /// 没有模块也没有卡 —— 那一行不塞一条示例进去就永远是一张白纸。
    var seededUSSD: String = ""

    @State private var command = "AT+QNWINFO"
    @State private var output = ""
    @State private var showPresets = false

    // `AT+CUSD=1,"*100#",15` 是国内三家都认的查话费写法，放最后是因为它
    // 发出去以后**答案不会立刻回来** —— 见下面那行 USSD。扫网那条要等
    // 二十秒到一分钟，模块整段时间占着 AT 口，别连着点。
    private let presets = ["ATI", "AT+CSQ", "AT+QENG=\"servingcell\"", "AT+QCFG=\"usbcfg\"",
                           "AT+CPMS?", "AT+CLCC", "AT+CUSD=1,\"*100#\",15", "AT+COPS=?", "AT+COPS=0"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 通道是这条命令行自己的一半语境（另一条路是 TCP，回显格式不一样），
            // 所以它跟着控制台走：收起时面板底部是干净的，点开就在第一行。
            Text(model.transport).label(9).foregroundStyle(Theme.inkNote).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                TextField("", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .label(10)
                    .ownPlaceholder("AT 指令", size: 10, shows: command.isEmpty)
                    .onSubmit(run)
                Button("发送", action: run).label(10).buttonStyle(.plain).foregroundStyle(Theme.ink)
            }
            // 这排 8pt 快捷指令原来一直摊在最底下：字号已经贴着可读下限，又
            // 卡在面板边缘被裁掉半行，浅底上糊成一片绿灰（子像素渲染在小字上
            // 的彩色描边最明显）。收成一行标题，点开才摊平 —— 展开后每条占
            // 一整行、黑底荧光绿 10pt，长指令也不会被截断。
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { showPresets.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(showPresets ? 90 : 0))
                    Text("快捷指令").label(10).foregroundStyle(Theme.ink)
                    Text("\(presets.count) 条").label(9).foregroundStyle(Theme.inkNote)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showPresets ? "收起" : "点开查看，点一条就发送")

            if showPresets {
                Screen(radius: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(presets, id: \.self) { preset in
                            Button {
                                command = preset
                                run()
                            } label: {
                                Text(preset)
                                    .label(10)
                                    .foregroundStyle(Theme.phosphor)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("点一下直接发送")
                        }
                    }
                    .padding(.horizontal, -4)
                }
            }
            if !ussdText.isEmpty {
                // USSD 的答案不走上面那个回显框：它不是「发送」这一步回来的，
                // 单独占一行，免得被下一条命令冲掉。
                HStack(alignment: .top, spacing: 5) {
                    Text("USSD").label(9).foregroundStyle(Theme.inkNote)
                    Text(ussdText)
                        .label(10)
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chromeHi))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.chromeEdgeStrong, lineWidth: 1.2))
            }
            if !output.isEmpty {
                // 回显以前是浅灰底上的暗绿小字，两种颜色都灰，读起来是糊的。
                // 模块的原话本来就该印在「模块的屏」上：黑底 + 荧光绿是这块
                // 面板自己的语言，10pt 在这个对比度下比原来 9pt 清楚得多。
                // 高度封顶，回一长串 `AT+QENG` 不会把面板顶到屏幕外面去。
                //
                // 这里给的是确定高度而不是上界：`ScrollView` 在下拉面板里的理想
                // 高度是 0，只写上界的话回显框会缩成一条什么都没有的黑条，客户
                // 敲完命令看不到模块的回复（2026-09-25 实测）。
                Screen(radius: 8) {
                    ScrollView {
                        Text(output).label(10).foregroundStyle(Theme.phosphor)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 132)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.chromeEdge.opacity(0.4)))
        .onAppear {
            if output.isEmpty { output = seededOutput }
            if presetsExpanded { showPresets = true }
        }
    }

    /// 真机上永远是模块刚回的那一条；只有截图会落到种子里。
    private var ussdText: String {
        model.ussdResult.isEmpty ? seededUSSD : model.ussdResult
    }

    private func run() {
        let text = command
        output = "…"
        // USSD 单独走一条路：它的答案不会出现在回显框里（模块只回 OK，
        // 正文另发一条上报），失败时回的码也得翻译成人话。其余照旧。
        if let code = Self.ussdCode(in: text) {
            model.sendUSSD(code) { result in output = result }
            return
        }
        model.runAT(text) { response in output = response }
    }

    /// 认出形如 `AT+CUSD=1,"*100#",15` 的那一行，把 `*100#` 取出来。
    /// 认不出就返回 nil，那条命令照常原样发给模块 —— 这条判断只用来分流，
    /// 不替客户改一个字。
    private static func ussdCode(in command: String) -> String? {
        let head = "AT+CUSD=1"
        let upper = command.uppercased()
        guard upper.hasPrefix(head), upper.count >= head.count else { return nil }
        let rest = command.dropFirst(head.count)
        guard let open = rest.firstIndex(of: "\""),
              let close = rest[rest.index(after: open)...].firstIndex(of: "\"") else { return nil }
        let code = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return code.isEmpty ? nil : code
    }
}
