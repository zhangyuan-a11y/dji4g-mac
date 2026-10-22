import AVFoundation
import AppKit

/// 麦克风授权。
///
/// 2026-09-30 查出来的「接通以后几十秒没有声音」，根因就在这里：
///
///     01:04:58.677  通话状态：拨号中 → 通话中 10000
///     01:05:30      系统里的麦克风授权被点下（TCC 记录的 last_modified）
///     01:05:32.123  通话语音已接通（语音通路已重挂）
///
/// 那 33 秒全花在等系统那个授权框上。病根不是慢，是**问得太晚**：这个 App
/// 平时没有窗口（`LSUIElement`），授权框是在第一通电话接通那一刻由 CoreAudio
/// 触发的，弹在客户正在打的电话背后，没人知道要点它，于是一路干等。客户那边
/// 看到的就是「接通了没有声音」，挂断之后一切正常 —— 最难查的那一类。
///
/// 所以这一问要提前到**装完第一次打开**：那时客户正看着屏幕，框就在眼前。
/// 授权一次就永久有效，之后每通电话都是秒接。
@MainActor
enum MicPermission {
    enum State {
        case granted
        case denied
        case undetermined

        init(_ status: AVAuthorizationStatus) {
            switch status {
            case .authorized: self = .granted
            case .denied, .restricted: self = .denied
            default: self = .undetermined
            }
        }
    }

    static var state: State {
        State(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// 出图 / 自检那一趟不碰 TCC。
    ///
    /// `--render --hardware` 这类自检用的是真 `AppModel`，会在出图的机器上
    /// 追一次授权 —— 那个框没人点，整趟图就卡在那里。这些进程没有客户，
    /// 也不打电话，放它们过去。正常的 App 进程一个旗标都没有，照常问。
    private static var isHeadlessRun: Bool {
        let headless: Set<String> = [
            "--render", "--sim-check", "--ring-check", "--panel-window-check",
            "--call-audio-check", "--sim", "--sim-nosim",
        ]
        return CommandLine.arguments.contains { headless.contains($0) }
    }

    /// 没授权过就问一次。系统自己只会弹一次框，重复调用是廉价的空转。
    ///
    /// 弹之前先把 App 放出来：授权框是系统画的，但它跟着发起方的激活状态走，
    /// 一个藏在后台的菜单栏 App 弹的框会被别人的窗口盖住 —— 那正是这次事故。
    static func requestIfNeeded(completion: ((State) -> Void)? = nil) {
        let current = state
        guard !isHeadlessRun, current == .undetermined else {
            completion?(current)
            return
        }
        AppActivation.activate()
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                completion?(granted ? .granted : .denied)
            }
        }
    }

    /// 客户自己动手去开：直接跳到「隐私与安全性 → 麦克风」那一页。
    ///
    /// 已经被拒绝过一次的话系统不会再弹框（这是 TCC 的规矩，改不了），
    /// 唯一的路就是他自己进系统设置把开关打开 —— 所以界面上得有一条能
    /// 直接把他送到那里的路，否则「没声音」就没有出口。
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        if let url { NSWorkspace.shared.open(url) }
    }
}
