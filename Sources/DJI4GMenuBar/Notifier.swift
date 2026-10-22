import AppKit
import Foundation
import UserNotifications

/// Delivers incoming calls and SMS to Notification Center.
///
/// A menu bar app spends most of its life with the panel closed, so a ring or a
/// message that only appears inside the panel is one the user never sees. Being
/// reachable is the whole point of the module, so both are posted here.
///
/// Everything is best-effort: the app stays fully usable when notifications are
/// denied, and the panel remains the source of truth either way.
final class Notifier {
    static let shared = Notifier()

    /// `UNUserNotificationCenter.current()` raises an Objective-C exception when
    /// the process has no bundle, which is exactly the `--render` screenshot
    /// path that runs the menu bar binary straight out of `.build/`. The check
    /// has to happen before the framework is touched, not after.
    private let isAvailable: Bool
    private let lock = NSLock()
    private var isAuthorised = false

    /// 授权结果写成一句人话给客户看。
    ///
    /// 「来电没弹提示」在客户眼里是坏掉，在这台机器上其实是系统里没允许通知
    /// （2026-09-24 的 ncprefs 里这个 App 的授权位就不完整）。答案必须出现在
    /// 客户看得见的地方，而不是只躺在系统设置里。
    private(set) var authorizationNote: String?
    /// 授权结果回来时通知一次，`AppModel` 拿它写活动列表。
    var onAuthorizationChange: ((String) -> Void)?

    /// 授权到底给没给。`nil` = 还没问出结果。
    ///
    /// 上面那句话是给客户读的，这个是给代码判断用的：面板要拿它决定
    /// 「来电弹不出来」那行提示显不显示。用 `authorizationNote` 的前缀去
    /// 反推意味着文案一改就悄悄失效 —— 那种 bug 不会报错，只会让提示再也不出现。
    private(set) var authorizationGranted: Bool?

    /// 把那句「到 系统设置 › 通知 › DJI 4G 打开」变成能点的东西。
    ///
    /// 让客户自己在一层层系统设置里找 App 名字，是这句话最容易被放弃的一步。
    /// 先试新版通知面板的扩展地址，老系统上退回去开旧面板 id。
    static func openNotificationSettings() {
        let candidates = ["x-apple.systempreferences:com.apple.Notifications-Settings.extension",
                          "x-apple.systempreferences:com.apple.preference.notifications"]
        for text in candidates {
            guard let url = URL(string: text) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }

    private init() {
        isAvailable = Bundle.main.bundleIdentifier != nil
    }

    /// Asks once, at launch. The reply arrives on a background queue and is only
    /// ever read by `post`, so a queued ring cannot race the authorisation.
    func prepare() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                guard let self else { return }
                self.lock.lock()
                self.isAuthorised = granted
                self.lock.unlock()
                let note = granted
                    ? "系统通知已允许，来电会弹提示"
                    : "系统通知没允许：来电照弹 App 浮层，但没有系统横幅；"
                        + "到 系统设置 › 通知 › DJI 4G 打开"
                self.lock.lock()
                self.authorizationNote = note
                self.authorizationGranted = granted
                self.lock.unlock()
                DispatchQueue.main.async { self.onAuthorizationChange?(note) }
            }
    }

    /// Test seam. The headless self-check has no bundle and therefore no
    /// Notification Center, so the wording of an announcement is otherwise
    /// unobservable — which is how 「来电 · 未知号码」 for a call whose number
    /// was on screen got shipped in the first place. Recorded before the
    /// availability guards so it means "what the app decided to say", which is
    /// the part that can be wrong.
    private(set) var lastPosted: (title: String, body: String)?

    /// `identifier` is unique per event rather than per kind: Notification
    /// Center replaces a delivered notification that repeats an identifier, so
    /// reusing "sms" would make every message but the last silently vanish.
    func post(identifier: String = UUID().uuidString, title: String, body: String) {
        lock.lock()
        lastPosted = (title, body)
        lock.unlock()
        guard isAvailable else { return }
        lock.lock()
        let authorised = isAuthorised
        lock.unlock()
        guard authorised else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
