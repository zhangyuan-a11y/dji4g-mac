import AppKit
import Foundation

/// 只让一份在跑。
///
/// 2026-09-25 实测：这个 App 能被双击起两份，两份各画一个菜单栏图标。
///
/// 2026-09-26 客户截图里这两个图标都是「4G」（`MenuBarLabel.parts` 只在
/// `model.isConnected` 时画「4G」），说明**两份都连上了模块**，不是一份好
/// 一份坏。这比「一份是坏的」更值得堵：两份都在轮询同一个 AT 口、都能收发
/// 短信和拨电话、都能动数据开关，互相不知道对面在做什么 —— 客户真在通话时
/// 另一份去查一次短信，会出什么事没人验过。
///
/// 客户看到的则是另一回事：两个一模一样的图标并排站着，他不知道该点哪个。
///
/// 两头一起堵：
///   1. `Info.plist` 里的 `LSMultipleInstancesProhibited`：从 Finder 双击时
///      系统不再起第二份，直接变成对已在跑那一份的「重新打开」；
///   2. 这条运行时的兜底：有人绕过 Finder 时（`open -n`、直接跑二进制、
///      LaunchAgent 和 Finder 各起一份）第二份自己退出，并且**请第一份把面板
///      窗口铺出来**。
///
/// 2026-09-26 补一道**进程锁**，因为上面第 2 条只按 bundle id 找同类，两种
/// 情况它认不出来：
///   · 桌面上的测试版 bundle id 是 `local.dji4g.menubar.probe`，装进
///     /Applications 的那份是 `local.dji4g.menubar` —— 按 id 互不相识；
///   · 直接跑 `.build/release/DJI4GMenuBar` 时**连 bundle id 都没有**，
///     退回按可执行文件路径比，和 App 里那份也对不上。
/// 两种都会在菜单栏并排画两个一模一样的 4G 图标，客户分不出该点哪个。
/// 锁的路径写死、和 id 与路径都无关，所以这两条路一并堵上。
///
/// 为什么第二份要顺手叫第一份开窗口：客户双击 App 的那个动作，本意就是
/// 「我要用一下」。他双击完屏幕上一动不动的话，和现在这个「点不开」的 bug
/// 是同一个观感 —— 那就等于把一个毛病换成了另一个。
enum SingleInstance {
    /// 第二份退出之前发的消息，第一份收到就把面板铺成一个真正的窗口。
    static let showPanel = Notification.Name("local.dji4g.menubar.showPanel")

    /// 已经在跑的那一份（不含自己）。
    ///
    /// 正常按 bundle id 找。直接跑裸二进制时没有 bundle id（`swift run`、
    /// 或者有人点开了 `.build` 里的产物），退回按可执行文件路径比。
    static func otherInstance() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let identity = Bundle.main.bundleIdentifier {
            if let found = NSRunningApplication.runningApplications(withBundleIdentifier: identity)
                .first(where: { $0.processIdentifier != me }) {
                return found
            }
            return nil
        }
        guard let mine = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != me
                && $0.executableURL?.resolvingSymlinksInPath() == mine
        }
    }

    // MARK: - 进程锁

    /// 锁文件。路径刻意写死，不掺 bundle id —— 掺了就退回成「只认自己这一份」。
    ///
    /// 放 `~/Library/Application Support/` 而不是 `/tmp`：`/tmp` 会被系统清，
    /// 清了不影响正确性（下一次启动重建），但放在 Application Support 里
    /// 和 App 的其它状态在同一处，排查时好找。
    private static let lockURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DJI4G/instance.lock")
    }()

    /// 拿到锁之后**必须一直开着**：`flock` 是跟着这个描述符走的，描述符一关
    /// 锁就没了，第二份立刻能挤进来。所以存成 static，随进程活到底。
    private static var lockDescriptor: Int32 = -1

    /// 拿到返回 true（这一份是唯一一份）；false 表示已经有别的实例握着。
    ///
    /// 用 `flock` 而不是「建一个文件，存在就说明有人在跑」：进程无论怎么死
    /// （正常退、崩溃、被 kill -9、断电）内核都会把锁收走，不会留下一个需要
    /// 人工删的僵尸锁文件把客户挡在门外。
    static func acquireProcessLock() -> Bool {
        let url = lockURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        // 打不开锁文件（磁盘满、家里目录权限被人改过）**不能**把 App 挡在门外：
        // 退回「按 bundle id 找同类」那条老路。宁可漏拦，不能让客户双击没反应。
        guard descriptor >= 0 else { return true }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        lockDescriptor = descriptor
        return true
    }

    /// 有别的实例在跑就把它叫起来，然后自己收摊。返回 true 表示这一份该退了。
    ///
    /// 2026-09-26 起，「有没有别的实例」先问进程锁 —— 它跨 bundle id、跨路径
    /// 都认。bundle id 那条退成兜底，管锁没覆盖到的边角（比如锁文件打不开时）。
    @discardableResult
    static func yieldToRunningInstance() -> Bool {
        let haveLock = acquireProcessLock()
        if haveLock, otherInstance() == nil { return false }
        let who = otherInstance().map { "pid=\($0.processIdentifier)" }
            ?? "另一份（bundle id 和路径都对不上，靠进程锁认出来的）"
        AppLog.note("已经有一份在跑了（\(who)）：这一份退出，并请它把面板窗口铺出来")
        DistributedNotificationCenter.default().post(name: showPanel, object: nil, userInfo: nil)
        // `post` 是异地的：立刻 `exit` 有概率把还没送出去的那条消息一起带走，
        // 客户看到的就是「双击了没反应」。半秒够本机这条 socket 走完一个来回，
        // 也短到双击的人察觉不出来。
        Thread.sleep(forTimeInterval: 0.5)
        exit(0)
    }
}

/// 面板窗口的开关。
///
/// `PanelView` 平时是 `MenuBarExtra` 的下拉内容，点开才存在。客户那台机器上
/// 面板弹不出来时，他需要一个**不经过菜单栏**也能把面板看到的办法 —— 双击
/// App 图标。窗口本身由 `DJI4GApp` 里那条 `Window` 场景提供，这里只发一个
/// 「该开了」的信号，因为 `openWindow` 只在视图里拿得到，`AppDelegate` 里没有。
final class PanelWindowRequest: ObservableObject {
    static let shared = PanelWindowRequest()

    /// 每响一次加一。视图那边 `onReceive` 它。
    @Published private(set) var ticket = 0
    private var listening = false

    private init() {}

    /// 从启动时挂上，一直听着「另一份让我开窗口」这条消息。
    func startListening() {
        guard !listening else { return }
        listening = true
        DistributedNotificationCenter.default().addObserver(
            forName: SingleInstance.showPanel, object: nil, queue: .main
        ) { _ in
            PanelWindowRequest.shared.request(reason: "又双击了一下 App 图标")
        }
    }

    func request(reason: String) {
        AppLog.log("打开独立面板窗口（\(reason)）")
        ticket &+= 1
    }
}
