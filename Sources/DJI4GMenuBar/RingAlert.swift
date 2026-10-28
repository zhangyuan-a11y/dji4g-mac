import AppKit
import SwiftUI
import DJI4GCore

/// 来电时自己跳出来的那张卡片。
///
/// 菜单栏图标会变、面板里会写「来电响铃」，可这两样都得客户先看一眼菜单栏；
/// 通知中心那条是尽力而为的：系统里关掉通知、开着专注模式、或者第一次弹窗被
/// 顺手点掉，客户面前的电话就一声不响 —— 2026-09-24 的实测正是这样，号码只在
/// 手动点开的面板里出现。这张卡片不经过任何授权，也不等客户先找：浮在全屏
/// 之上，带一段循环铃声，号码下面就放着「接听」。
@MainActor
final class RingAlert {
    static let shared = RingAlert()

    /// 卡片那扇窗的名字。
    ///
    /// 点菜单栏图标时要收掉「菜单栏下拉」那扇窗（见 `PanelDismiss`），手上
    /// 只有两条判据：浮层、够宽。这张卡片两条都占（`.floating`、300 点宽）
    /// —— 来电正响铃的时候客户去点图标，那一下就会顺手把来电卡片一起收了，
    /// 那是最不能出的错。所以给它挂个名字，好让那边点名躲开。
    static let windowIdentifier = "dji4g.ring-card"

    /// 卡片该不该出现。
    ///
    /// 只有需要客户做决定的两路状态出现：正在响的来电，和通话中插进来的第二
    /// 路。已经接通的通话不弹 —— 那时候客户手里有事做，挡住屏幕只会添乱。
    static func wantsCard(_ state: CallState) -> Bool {
        switch state {
        case .ringing, .waiting: return true
        default: return false
        }
    }

    private var panel: NSPanel?
    private var sound: NSSound?
    /// 卡片上此刻画着的标题。轮询每两秒重发一次同样的来电状态，比对一下就不会
    /// 每两秒重建一次窗口 —— 重建会把客户正要点的那颗按钮从光标下面挪走。
    private var cardKey = ""
    /// 这一通来电的铃声是不是被用户手动静音了。只对这一通有效，下一通独立
    /// 来电会重新按正常行为响铃。
    private var ringSilenced = false
    private(set) var isShowing = false

    private init() {}

    /// 状态每来一次就调一次，进不进候选由 `wantsCard` 决定。
    ///
    /// `enabled` 是自检和截图那条路用的：那两条路会造出来电，却必须保持没有
    /// 窗口，否则自检跑到一半会有一张卡片跳到屏幕上抢走焦点。
    func update(_ call: CallInfo,
                enabled: Bool,
                answer: @escaping () -> Void,
                reject: @escaping () -> Void) {
        guard enabled else { return }
        guard Self.wantsCard(call.state) else {
            dismiss()
            return
        }
        // `RING` 和 `+CLIP` 是两行：卡片先弹出来让客户听见响、看见有人打进来，
        // 号码到了再在原地补上。等号码才弹，快的时候也一样，慢的时候可能整通
        // 电话都没有卡片。
        let title = call.state == .waiting ? "第二路来电" : "来电响铃"
        // 号码是后到的（`RING` 在前、`+CLIP` 在后），所以判重里带上号码：同一通
        // 电话的第二次事件要能把「未知号码」换成真号码，而不是被当成重复丢掉。
        let key = "\(title)|\(call.number)"
        guard !isShowing || cardKey != key else { return }
        present(call, title: title, key: key, answer: answer, reject: reject)
    }

    /// 挂断、接听、对方放弃 —— 只要不再需要决定，卡片就收走，铃声同时停。
    func dismiss() {
        guard isShowing || panel != nil else { return }
        isShowing = false
        cardKey = ""
        ringSilenced = false
        stopRinging()
        panel?.orderOut(nil)
    }

    /// 只关掉这一通的铃声，不拒接、不清掉卡片；接听/拒接按钮照旧可用。
    func silenceRingtone() {
        ringSilenced = true
        stopRinging()
    }

    // MARK: - Window

    private func present(_ call: CallInfo,
                         title: String,
                         key: String,
                         answer: @escaping () -> Void,
                         reject: @escaping () -> Void) {
        let firstShow = !isShowing
        cardKey = key
        let host = NSHostingView(rootView: RingCard(
            number: call.number.isEmpty ? "未知号码" : call.number,
            title: title,
            ringSilenced: ringSilenced,
            answer: answer,
            reject: reject,
            silenceRinging: { [weak self] in self?.silenceRingtone() }))
        host.layout()
        let panel = self.panel ?? makePanel()
        panel.setContentSize(host.fittingSize)
        panel.contentView = host
        self.panel = panel
        guard firstShow else { return }
        place(panel)
        panel.orderFrontRegardless()
        // 菜单栏 App 平时不抢前台。这一下是为了让卡片真的浮在客户正在用的那个
        // 窗口上面，视频会议全屏也一样。
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        startRinging()
        isShowing = true
    }

    private func makePanel() -> NSPanel {
        let panel = RingPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered,
                              defer: false)
        panel.level = .floating
        panel.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        // 跟着客户走：切 Space、全屏看视频，来电都要能盖上来。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 18,
                                     y: area.maxY - size.height - 18))
    }

    // MARK: - Ring tone

    private func startRinging() {
        guard sound == nil else { return }
        let url = URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")
        let tone = FileManager.default.fileExists(atPath: url.path)
            ? NSSound(contentsOf: url, byReference: true)
            : NSSound(named: "Ping")
        guard let tone else {
            // 铃声是锦上添花，卡片才是那条一定要走通的路。
            NSSound.beep()
            return
        }
        tone.loops = true
        tone.volume = 0.7
        tone.play()
        sound = tone
    }

    private func stopRinging() {
        sound?.stop()
        sound = nil
    }
}

/// 无边框面板默认当不了 key window，也就收不到键盘。
private final class RingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 卡片本体。长得像面板是有意的：客户已经认识这块屏，来电时不该再学一个新界面。
struct RingCard: View {
    var number: String
    var title: String
    var ringSilenced: Bool
    var answer: () -> Void
    var reject: () -> Void
    var silenceRinging: () -> Void
    @State private var silenced = false

    init(number: String, title: String, ringSilenced: Bool,
         answer: @escaping () -> Void, reject: @escaping () -> Void,
         silenceRinging: @escaping () -> Void) {
        self.number = number
        self.title = title
        self.ringSilenced = ringSilenced
        self.answer = answer
        self.reject = reject
        self.silenceRinging = silenceRinging
        _silenced = State(initialValue: ringSilenced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "phone.arrow.down.left")
                    .font(.system(size: 10, weight: .bold))
                Text(title).label(10)
                Spacer()
                Text("DJI 4G").label(9).foregroundStyle(Theme.phosphorDim)
            }
            .foregroundStyle(Theme.phosphor)

            Text(number)
                .label(24)
                .foregroundStyle(Theme.phosphor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            HStack(spacing: 8) {
                CardButton(title: "接听", glyph: "phone.fill",
                           tint: Theme.phosphor, action: answer)
                CardButton(title: "拒接", glyph: "phone.down.fill",
                           tint: Theme.alert, action: reject)
            }
            CardButton(title: silenced ? "已静音" : "静音铃声",
                       glyph: silenced ? "bell.slash.fill" : "bell.slash",
                       tint: Theme.ink,
                       action: {
                           silenced = true
                           silenceRinging()
                       })
        }
        .padding(14)
        .frame(width: 288)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.screen)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.phosphor.opacity(0.55), lineWidth: 1.4)
                )
                .shadow(color: .black.opacity(0.30), radius: 12, y: 6)
        )
        // 阴影要地方画，贴着边会被窗口裁掉。
        .padding(8)
    }
}

private struct CardButton: View {
    var title: String
    var glyph: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: glyph).font(.system(size: 10, weight: .semibold))
                Text(title).label(11)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(Color.white.opacity(0.08))
                    .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }
}
