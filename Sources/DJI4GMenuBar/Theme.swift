import SwiftUI
import CoreText
import DJI4GCore

/// The panel is a physical object in the reference: white plastic chrome around
/// a black dot-matrix screen. Keeping the palette in one place is what stops
/// the sections from drifting apart.
enum Theme {
    /// 黑屏上的荧光绿。只给黑底用 —— 它铺到浅灰面板上对比度只有 1.3:1，
    /// 2026-09-25 的截图里那一片「已注册 / CHNET / en17」糊成一片就是这个
    /// 原因。浅底请用 `phosphorInk`。
    static let phosphor = Color(red: 0.38, green: 0.95, blue: 0.50)
    /// 同一支绿的次级亮度，给黑屏上的第二层小字（来电状态、短信时间）。
    ///
    /// 原来写的是 0.20/0.52/0.28，在黑底上只有 4.1:1；9pt 的点阵字本来就细，
    /// 那点余量不够，读起来发灰。提到 7.8:1，色相不变，层级还是靠它压住。
    static let phosphorDim = Color(red: 0.30, green: 0.74, blue: 0.40)
    /// 浅灰面板上的绿。
    ///
    /// 同一个色相的深版：铺在 chrome 上是 6.3:1（荧光绿是 1.3:1）。字段值、
    /// 状态点、浅底上的按钮都用它 —— 「绿的」这个身份留着，读不清的部分去掉。
    static let phosphorInk = Color(red: 0.04, green: 0.40, blue: 0.19)
    static let screen = Color(red: 0.055, green: 0.065, blue: 0.065)
    static let chrome = Color(red: 0.94, green: 0.95, blue: 0.95)
    static let chromeEdge = Color(red: 0.80, green: 0.82, blue: 0.83)
    /// 药丸的面。比面板底（`chrome` 0.94）亮一档。
    ///
    /// 原来药丸填的就是 `chrome` —— 和面板同一个颜色，等于没有填充，整颗
    /// 按钮只剩一圈 1pt 的浅边框撑着。2026-09-26 用户的原话：「这个胶囊的
    /// 设计太弱化了，已经有点看不清了」。同一个色号刷两层，中间那个台阶
    /// 就没了；按钮要立起来，面必须比底亮。
    static let chromeHi = Color(red: 0.995, green: 1.0, blue: 1.0)
    /// 药丸的边框。原来用 `chromeEdge`（0.80）压在 0.94 的底上，只差 0.14，
    /// 缩到 Retina 上就是一条毛边。压到 0.61 才真的把按钮框出来。
    static let chromeEdgeStrong = Color(red: 0.61, green: 0.645, blue: 0.665)
    static let ink = Color(red: 0.10, green: 0.11, blue: 0.11)
    /// 浅灰面板上的次级字：字段的小标题（注册 / 制式 / 频段 / MAC 网络服务）、
    /// 说明句、还没有值的那几格。
    ///
    /// 原色 0.42/0.45/0.46 铺在 chrome（0.94）上是 4.3:1 —— 差的这一点点，
    /// 配上点阵字那种「一根字由几十个点拼出来」的画法，实际观感比数字更淡。
    /// 2026-09-25 到 09-26 用户连着两次提到小字发虚（先是底部那行绿字，后是
    /// 胶囊），所以这里直接压到 5.4:1：层级还在（`ink` 是 15:1，仍旧明显更
    /// 重），但客户不用凑近看。白底上（设置页那个输入框）从 4.9:1 变成 6.1:1。
    static let inkSoft = Color(red: 0.36, green: 0.39, blue: 0.40)

    /// 小一号的点阵字专用墨色（≤10pt）。
    ///
    /// 2026-09-26 实测：Doto 的每一画都是点出来的，字号越小点越小，抗锯齿把
    /// 它们抹平得越厉害 —— 同一个 `inkSoft`，11pt 渲染出来是 5.3:1，9pt 只剩
    /// 4.4:1，8pt 4.3:1，正好卡在 4.5 的门槛下面。这不是色值写错了，是「点阵
    /// 字在小号上铺不满」。字体那边已经没余量：`wght` 打包的就是 900（Black），
    /// `ROND` 默认 0（方点，比圆点多 20~30% 的墨），都到顶了。
    ///
    /// 所以小号字单独配一支更深的墨：分量各乘 0.78，渲染回来是 5.9～6.4:1，
    /// 仍然明显轻于 `ink`（11～15:1）——层级没丢，但读得清。
    ///
    /// 规则：`label(10)` 及以下用 `inkNote`，11pt 以上继续用 `inkSoft`。
    static let inkNote = Color(red: 0.28, green: 0.30, blue: 0.31)
    /// 黑屏上的警示色（来电浮层的「拒接」、通话横幅的「挂断」）。浅珊瑚红
    /// 铺在 `screen` 上是 7.1:1，读得清，也确实是「红」。
    static let alert = Color(red: 1.00, green: 0.45, blue: 0.38)
    /// 浅灰面板上的警示色。
    ///
    /// 和 `phosphor` → `phosphorInk` 是同一件事：上面那支红是给黑底调的，
    /// 铺到 chrome（0.94）上只有 2.38:1 —— 比修之前的荧光绿还糟。2026-09-26
    /// 夜里的截图里，「存储将满」「Mac 网络服务」「关掉查看页」这些字就是
    /// 一团粉影。压到同一个色相的深版是 5.7:1，和 `inkSoft` 一个层级：够
    /// 读，又明显比正文的 `ink`（15:1）轻，警示的身份还在。
    ///
    /// 用它之前先看底：黑屏仍旧用 `alert`，别拿这支深红去黑底上刷（2.9:1）。
    static let alertInk = Color(red: 0.72, green: 0.13, blue: 0.09)
    static let panelWidth: CGFloat = 344
}

/// Doto is the dot-matrix face the reference uses. It ships with the app; if it
/// cannot be registered the system monospaced face keeps the layout intact.
enum DotFont {
    static let family: String = {
        // 不用 Bundle.module：它只认 app 根目录和编译机上的 .build 目录，
        // 客户机上两条都不存在，一点开面板就崩（见 AppResources）。
        guard let url = AppResources.url(forResource: "doto", withExtension: "ttf") else { return "" }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let name = CTFontDescriptorCopyAttribute(descriptors[0], kCTFontFamilyNameAttribute) as? String
        else { return "" }
        return name
    }()

    static func mono(_ size: CGFloat) -> Font {
        family.isEmpty ? .system(size: size, design: .monospaced)
                       : .custom(family, size: size)
    }
}

extension View {
    func label(_ size: CGFloat = 11) -> some View {
        self.font(DotFont.mono(size)).tracking(0.6)
    }

    /// 短信页的阅读字体：系统 UI 字体。
    ///
    /// 和 `label()` 分开的原因是字距：那一支带着 0.6 的 tracking，是给点阵
    /// 字补空隙用的，铺到系统字体上会把一行汉字撑散。所以这一页只放字号。
    func reading(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        font(.system(size: size, weight: weight))
    }

    /// 把一格铺满它自己那一栏。
    ///
    /// 两栏的详情（模块页）原来是 `Field / Spacer / Field`：两格各自按内容
    /// 定宽，第二格的起点就等于「面板宽 − 它自己有多宽」。于是「固件」和
    /// 「模块声卡」明明在同一栏，起点却差了 77pt（2026-09-28 放大真机截图
    /// 量出来的）—— 上一格是 14 个字符的长值，下一格只有三个字。
    ///
    /// 铺满之后两栏各占一半，栏位不再跟着内容跑。这里不能靠 `Grid`：模块页
    /// 中间夹着一条「未开启不影响拨号」的条件提示，`Grid` 会被它切成两段，
    /// 两段各算各的栏宽，反而更歪。
    func column() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 自己画的输入框占位符。
///
/// 2026-09-26 实测：`TextField` 的 `prompt:` 里给文字上色，**在 macOS 的
/// `.roundedBorder` 样式上根本不生效**。全 App 有五处都写成
/// `prompt: Text(…).foregroundColor(Theme.inkNote)`，离屏渲染和真机截图两边
/// 量出来都还是系统那支占位灰：白框上 1.84:1，比它附近任何一行 9pt 小字都淡。
/// 而它偏偏是客户往里填东西之前唯一能读的字 ——「号码」「对方号码」
/// 全在这个盲区里。上一轮以为改好了，是因为只看了源码没量渲染结果。
///
/// 所以不再跟这个样式较劲：字自己叠上去。颜色由 `inkNote` 说了算，字号跟着
/// 框里的 `.label(n)` 走，缩进对齐 `.roundedBorder` 的内边距。框里一有字就
/// 自己消失，也不吃点击。
private struct OwnPlaceholder: ViewModifier {
    var text: String
    var size: CGFloat
    var shows: Bool

    /// 跟着面板那条老规矩走：10pt 及以下用 `inkNote`，11pt 以上用 `inkSoft`。
    /// 顺带保住了「占位符比真输入淡一档」——框里打进去的字是 `Theme.ink`
    /// （白底 17.5:1），占位符要是也压到那个深度，客户会以为框里已经有内容了。
    private var ink: Color { size <= 10 ? Theme.inkNote : Theme.inkSoft }

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            if shows {
                Text(text)
                    .label(size)
                    .foregroundStyle(ink)
                    .padding(.leading, 7)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// `shows` 传绑定是不是空的 —— 占位符只在真正空着的时候露面。
    func ownPlaceholder(_ text: String, size: CGFloat = 10, shows: Bool) -> some View {
        modifier(OwnPlaceholder(text: text, size: size, shows: shows))
    }
}

/// A black screen inset into the chrome, with the subtle inner border the
/// reference panels have.
struct Screen<Content: View>: View {
    var radius: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.screen)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    )
            )
    }
}

/// 药丸右端那盏灯。
///
/// 原来只有「亮 / 不亮」两种，而「不亮」既是「这个开关是关的」也是「这里
/// 根本没有灯」—— 面板中间那颗数据开关因此丢了「关」的样子：标题写死
/// `4G ON`、灯只在有链路时才亮，关掉数据以后它还是一个写着 `4G ON` 的胶囊，
/// 读起来是标签而不是开关。2026-09-26 用户的原话：「是不是要加一个数据的
/// 开关，不是只有一个关机图标，只能退出和启动」。
///
/// 空心环把「关着」画出来，两个位置才都看得见；`pending` 是给「按了开、
/// 链路还在接」的中间态留的 —— 切 ECM 会让模块重启，那几秒里既不能说
/// 「已经通了」，也不能退回「关」。
enum PillLamp: Equatable {
    /// 不画灯（普通按钮）。
    case none
    /// 实心绿点：开着，链路也真的通了。
    case lit
    /// 空心绿环：开着，但还没接通。
    case pending
    /// 空心灰环：关着。
    case off
}

/// The white pill buttons under the main screen.
struct PillButton: View {
    var title: String
    var glyph: String?
    var lamp: PillLamp = .none
    var tint: Color = Theme.ink
    /// 按不动的时候整颗药丸压暗、并且真的不响应点击。
    ///
    /// 模块没连上时的数据开关就是这一态：按下去只会失败在「通道已关闭」上，
    /// 那句红字对客户什么也没说明（面板顶上已经写着「模块未连接」）。灰掉
    /// 比报错诚实 —— 一眼看得出来现在动不了。
    var isEnabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let glyph {
                    Image(systemName: glyph).font(.system(size: 10.5, weight: .semibold))
                }
                // 10pt 的点阵字在浅底上会糊成一团灰：Doto 每个字都是点出来的，
                // 10pt 时一颗点比屏幕像素还小，抗锯齿直接把它抹平 —— 2026-09-26
                // 用户说「字体也不清晰」。12pt 才落得下完整的点阵。
                // 竖向内边距同时从 9 收到 8，整颗药丸的高度保持不变，底下那排
                // 小屏的排版不会跟着动。
                Text(title).label(12)
                lampView
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                // 面用一道极浅的上亮下暗：白塑料按钮在照片里就是这样，平平的
                // 一块白反而更像贴纸。跨度只有 7%，不会影响点阵字的可读性。
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Theme.chromeHi, Theme.chromeHi.opacity(0.93)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .overlay(Capsule().strokeBorder(Theme.chromeEdgeStrong, lineWidth: 1.4))
                    .shadow(color: .black.opacity(0.14), radius: 2, y: 1.5)
            )
            // 压暗到 0.62 而不是 0.5：0.5 配上原来那身浅填充，模块没插时整颗
            // 开关几乎要从面板上消失，客户找不到它；0.62 是「看得出来在这儿，
            // 但现在按不动」。
            .opacity(isEnabled ? 1 : 0.62)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    /// 白色药丸上的指示灯。实心用浅底绿（荧光绿铺在 chrome 上只有 1.3:1，
    /// 等于没画）；空心环用同一个绿、灰灯用 inkSoft 的淡版，环线只有 1.4pt，
    /// 太淡就只剩一个白点。
    @ViewBuilder private var lampView: some View {
        switch lamp {
        case .none:
            EmptyView()
        case .lit:
            Circle().fill(Theme.phosphorInk).frame(width: 5.5, height: 5.5)
        case .pending:
            Circle().strokeBorder(Theme.phosphorInk.opacity(0.85), lineWidth: 1.5)
                .frame(width: 5.5, height: 5.5)
        case .off:
            // 灰环原来 0.55 的透明度在浅底上几乎看不见，关着和没画一样；
            // 提到 0.75，让「关」也有一个明确的样子。
            Circle().strokeBorder(Theme.inkSoft.opacity(0.75), lineWidth: 1.5)
                .frame(width: 5.5, height: 5.5)
        }
    }
}

/// 通话里的按键音键帽 —— 电话机上的那一颗。
///
/// 2026-09-30 用户先嫌旧版（系统输入框 + 一行素字按钮）丑，改成一排宽药丸
/// 之后又追一句「按键音好像不准确」：点阵数字看着像没画准，十二颗宽药丸排
/// 开也更像一台计算器。现在照着电话机来 —— 圆键、居中一个大数字、数字底
/// 下缀一行字母（2=ABC…）。那行字母不是装饰：有它才一眼认得出这是电话键盘。
///
/// 数字不走 `label()` 那支点阵字：Doto 的每一画都是点出来的，小号铺不满，
/// 在键帽上就是一团糊影（同一件事短信页已经踩过——用户原话「不要这种像素
/// 字体」）。键帽用系统字体，笔画是实心的，缩到 2× 截图上仍旧是干净的。
struct KeyCap: View {
    var digit: String
    /// 数字底下那行字母。空串照样占一行 —— 十二颗键的数字才不会一颗高
    /// 一颗低。
    var letters: String = ""
    var action: () -> Void

    @State private var lit = false

    /// 键帽直径。52 是「一眼看得出是电话」和「这一页别长出一百点」的折中：
    /// 再小字母就压到 7pt 以下，再大通话窗就要顶到屏幕上沿。
    static let diameter: CGFloat = 52

    /// 十颗数字键用系统字体 21pt 就正；`*` 和 `#` 不是 —— 这俩在系统字体
    /// 里走的是数学轴对齐（`*` 画得又小又高、`#` 笔画偏细），照 21pt 排出来
    /// 会比旁边的数字矮一截。所以单独给字号：`*` 用星号符号放大顶满，
    /// `#` 提到 24pt。十二颗键的视觉重量这才齐。
    @ViewBuilder private var glyph: some View {
        switch digit {
        case "*":
            Image(systemName: "asterisk").font(.system(size: 18, weight: .medium))
        case "#":
            Text("#").reading(23, .medium)
        default:
            Text(digit).reading(21, .medium)
        }
    }

    var body: some View {
        Button {
            action()
            // 亮起不等动画（要跟手），退回去走一小段淡出。
            lit = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                withAnimation(.easeOut(duration: 0.18)) { lit = false }
            }
        } label: {
            VStack(spacing: -1) {
                glyph
                    .foregroundStyle(lit ? Theme.screen : Theme.ink)
                // 用一个空格顶住这一行：空串会被排版收掉，一行有字一行没有，
                // 数字就错开了。
                Text(letters.isEmpty ? " " : letters)
                    .reading(7.5, .semibold)
                    .tracking(0.9)
                    .foregroundStyle(lit ? Theme.screen.opacity(0.75) : Theme.inkNote)
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .background(
                Circle()
                    .fill(LinearGradient(colors: [Theme.chromeHi, Theme.chromeHi.opacity(0.93)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().fill(Theme.phosphor).opacity(lit ? 1 : 0))
                    .overlay(Circle().strokeBorder(Theme.chromeEdgeStrong, lineWidth: 1.2))
                    .shadow(color: .black.opacity(0.13), radius: 1.8, y: 1.2)
            )
            // 只认那颗圆：方框四角不接点击。
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// The dotted progress ring on the big panel.
struct DotRing: View {
    var progress: Double
    var segments: Int = 56

    var body: some View {
        ZStack {
            ForEach(0..<segments, id: \.self) { index in
                let lit = Double(index) / Double(segments) <= min(max(progress, 0), 1)
                Circle()
                    .fill(lit ? Theme.phosphor : Color.white.opacity(0.16))
                    .frame(width: lit ? 4.2 : 3, height: lit ? 4.2 : 3)
                    .offset(y: -34)
                    .rotationEffect(.degrees(Double(index) / Double(segments) * 360))
            }
        }
        .frame(width: 92, height: 92)
    }
}

/// The panel's own on/off switch, drawn rather than handed to AppKit.
///
/// `Toggle(…).toggleStyle(.switch)` goes through `NSSwitch`, which
/// `ImageRenderer` does not draw honestly: the offscreen render came out
/// showing "off" for a switch that was on. That is exactly the kind of thing
/// these renders exist to catch, so the state is drawn here instead — which
/// also keeps the control inside the palette.
struct PipSwitch: View {
    var isOn: Bool

    private let track = CGSize(width: 32, height: 17)
    private let knob: CGFloat = 13

    var body: some View {
        Capsule()
            .fill(isOn ? Theme.phosphor : Theme.chromeEdge)
            .frame(width: track.width, height: track.height)
            .overlay(
                Circle()
                    .fill(isOn ? Theme.screen : Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    .offset(x: isOn ? (track.width - knob) / 2 - 2
                                    : -((track.width - knob) / 2 - 2))
            )
    }
}

/// A two-line mini readout: tiny caption, then the value.
struct Field: View {
    var caption: String
    var value: String
    var tint: Color = Theme.phosphorInk

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // 小标题从 8pt 提到 9pt（2026-09-26 真机实测）。
            //
            // 8pt 的问题是「三字母的拉丁词根本铺不满」：同样的 `inkNote`，
            // 「注册」这种汉字小标题量出来 7.72:1 —— 汉字笔画密，点阵排得满；
            // 而「APN」三个字母每个只有 3×5 个点，抗锯齿一抹就散，只剩
            // 4.31:1，卡在门槛下面。`RSRP` 稍好（5.07:1）也是同一个道理，
            // 字母越多、越接近汉字那种密度，就越亮。
            //
            // 字号是这里唯一还有余量的旋钮：字体本身已经到顶（wght 900、
            // ROND 0 都试过），色号也不想再加第四档灰 —— 加一档是加一层要
            // 维护的层级，而 8→9pt 只是让同样的墨多铺一圈点。同一批字段
            // 里「APN」这一格是最长的（`APN（还没写进模块）`），9pt 下
            // 约 88pt，三栏每栏 100pt 出头，仍然排得下。
            Text(caption.uppercased()).label(Field.captionSize(caption))
                .foregroundStyle(Theme.inkNote)
            Text(value).label(Field.valueSize(value)).foregroundStyle(tint).lineLimit(1)
        }
    }

    /// 值这一行的字号，按「这一串里有没有汉字」分两档。
    ///
    /// Doto 是点阵字，汉字占满整个字面（11pt 量出来墨高 10pt），拉丁字母只有
    /// 三分之二（同样 11pt，cap 高 7.5pt）。同一行里「已注册」和「FDD LTE」
    /// 并排，客户一眼读到的就是「大小不一、深浅也不一」—— 2026-09-30 他就是
    /// 这么说的。字体的字面比例改不了（包里只有一个 wght 900 的实例），能拧的
    /// 只有字号：纯拉丁那一格放大到 13pt，两边的墨高就落回同一条线上（8.8pt
    /// 对 10pt，剩下那点差肉眼分不出来）。含汉字的串不动 —— 它就是参照物；
    /// 混排（`Mac 版`、`Baiwang 已启用`）按汉字算，那串里显眼的本来就是汉字。
    static func valueSize(_ text: String) -> CGFloat { text.hasCJK ? 11 : 13 }

    /// 小标题同理，整体小一档（9 / 10.5pt）。一格里上下两行说的是同一件事，
    /// 只管值不管标题，标题那一行还是会一眼大一眼小。
    static func captionSize(_ text: String) -> CGFloat { text.hasCJK ? 9 : 10.5 }
}

extension String {
    /// 串里有没有汉字。`Field` 用它做上面那套光学补正。
    var hasCJK: Bool {
        unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) }
    }
}

/// 短信页的字号。
///
/// 同一套光学补正（汉字铺满字面、拉丁只有三分之二高，拉丁那一档要抬两级），
/// 但整体比面板别处再大一档 —— 这一页的字是拿来读的，不是拿来扫的，客户
/// 连着说过两次「太小了，看不清」：
///
///   · 收件箱原来那三档（10 / 9 / 8pt）是「三个字段塞一条 15pt 高的线」逼
///     出来的，正文只分到 120pt 宽。现在一行拆两行，宽度不再是稀缺品，字号
///     就该按「读得清」来定，而不是按「塞得下」。
///   · 全部字号只从这里出：列表、全文卡片、回复按钮走的都是同一把尺子，
///     改一处不会把另一处落下。
/// 短信页的字号尺子。
///
/// 这一页**不用点阵**（`DotFont`）。面板别处那些字是仪表读数 —— 点阵把
/// 「这是一台设备」讲清楚了；短信是信，客户要连着读十几行，用点阵读汉字
/// 是在跟他为难。2026-09-30 客户的原话：「短信这里用正式一点字体，不要
/// 这种像素字体」。所以整页走系统 UI 字体（SF Pro / 苹方），字号也跟着回到
/// 系统那套读数。
///
/// 顺带解决一个老问题：Doto 只有拉丁字形，汉字要落回苹方 —— 同一行里数字
/// 是点阵、汉字是实心，本来就是将就。
enum SMSFont {
    /// 点开的全文卡片：发件人、正文。
    static let body: CGFloat = 13.5
    /// 收件箱列表的每一行（发件人 + 正文预览）。
    static let row: CGFloat = 12.5
    /// 时间、条数、存储这些跟着正文走的小字。
    static let meta: CGFloat = 10.5
}

/// 默认收起的日志抽屉。
///
/// 窗口最下面那截小字（模块诊断 + 运行记录）原来是直接摊开的：9pt 的灰字
/// 挤在浅灰底上，糊成一片。客户要的只是「有没有报错」，不是逐行读 —— 所以
/// 它收成一行标题，点开才铺出来，展开态放在黑屏上，用荧光绿，小字也清楚。
///
/// 收起来的另一面是窗口短了一截：设置窗口的下半部分原本是个 120pt 的黑洞，
/// 现在它不占位置，除非你确实要看。
struct LogDrawer<Content: View>: View {
    var title: String
    var hint: String = ""
    @Binding var expanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title).label(10).foregroundStyle(Theme.ink)
                    if !hint.isEmpty {
                        Text(hint).label(9).foregroundStyle(Theme.inkNote)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "收起" : "点开查看")

            if expanded {
                Screen(radius: 8) { content }
                    .padding(.top, 6)
            }
        }
    }
}

/// 通话中的一条实时电平。
///
/// 客户说「听不到」的时候，肉眼能分辨的就只有两件事：电平在动（通路是通的，
/// 问题在对面或者音量），或者电平一条线不动（通路没接上）。所以这一条不是
/// 装饰 —— 它是这一版里唯一能现场证明「声音真的在走」的东西。
///
/// 画成 20 格的横条而不是指针：点阵屏上格子的边界比指针的位置好读，而且
/// 一格一格亮起来的过程本身就说明它在动。
struct LevelBar: View {
    var caption: String
    /// 0…1 的峰值。模块那两个端点都是 8 kHz 单声道，说话时的峰值通常在
    /// 0.1～0.6 之间，所以下面乘了 1.6 —— 不然正常说话只亮到第三格。
    var level: Float

    private var filled: Int {
        min(Self.cells, max(0, Int((Double(level) * 1.6 * Double(Self.cells)).rounded())))
    }
    private static let cells = 20

    var body: some View {
        HStack(spacing: 6) {
            Text(caption).label(9).foregroundStyle(Theme.inkNote)
                .frame(width: 96, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(0..<Self.cells, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(index < filled ? Theme.phosphorInk : Theme.chromeEdge.opacity(0.55))
                        .frame(height: 7)
                }
            }
            // `max(0, …)`：静音时峰值算出来可能是 `-1e-7` 这种浮点噪声，`%.2f`
            // 照样把符号印出来 —— 空电平上挂一个「-0.00」，客户会以为电平是负的
            // 或者坏了（2026-09-25 截图复核时在通话窗口里看到）。
            Text(String(format: "%.2f", max(0, level)))
                .label(9).foregroundStyle(filled > 0 ? Theme.phosphorInk : Theme.inkNote)
                .frame(width: 30, alignment: .trailing)
        }
    }
}
