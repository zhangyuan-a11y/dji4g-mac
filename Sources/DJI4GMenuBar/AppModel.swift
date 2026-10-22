import Foundation
import CoreGraphics
import SwiftUI
import DJI4GCore

/// 这块模块插在哪台设备上。
///
/// 客户只需要认一件事，而它底下其实是两个位：USB 网卡走哪套协议（Mac 和
/// iPhone 都只认 ECM），以及模块声卡开不开（开着，Mac 上打电话两个方向才
/// 有声音；插 iPhone / iPad 时它会顶掉手机外放，所以那里必须关）。
///
/// 这两件事以前在设置页里是两行、四个取值，客户得自己明白「两个开关其实是
/// 一回事」。现在只剩两档，一档就是一台设备。
enum HostMode: String, CaseIterable {
    /// 插电脑：声卡开着。
    case mac
    /// 插手机、平板：声卡关掉，手机自己的喇叭不受影响。
    case mobile

    var label: String {
        switch self {
        case .mac: return "Mac 版"
        case .mobile: return "移动版"
        }
    }

    var help: String {
        switch self {
        case .mac: return "插电脑用：打电话两个方向都有声音。"
        case .mobile: return "插手机、平板用：不顶掉手机自己的喇叭和麦克风。"
        }
    }

    var wantsAudio: Bool { self == .mac }
}

/// Bridges `ModemController` — which talks to the module on its own threads —
/// into something SwiftUI can observe, and owns the attach/detach lifecycle so
/// the panel works whether the module is plugged in before or after launch.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var transport = "未连接"
    @Published private(set) var identity = ModuleIdentity()
    @Published private(set) var sim = SIMStatus()
    @Published private(set) var network = NetworkStatus()
    @Published private(set) var signal = SignalStatus()
    @Published private(set) var data = DataStatus()
    @Published private(set) var call = CallInfo()
    @Published private(set) var messages: [SMSMessage] = []
    /// 通话记录。模块不给历史（`AT+CLCC` 只说「此刻」，一代固件上问不出过去），
    /// 所以这一份是 App 自己攒的，见 `CallHistory`。
    ///
    /// 只在真客户这条路上记：自检、截图、`--sim` 演示也会造出来电，那些不能
    /// 进客户的历史 —— 判据是 `announcesAlerts`。
    @Published private(set) var callRecords: [CallRecord] = []
    @Published private(set) var voice = VoiceStatus()
    /// 通话语音那几个前置条件的体检结果（`ModuleVoiceSetup`）。
    ///
    /// 单独一格，不和 `voice` 合并：`voice` 说的是「系统默认输入输出现在
    /// 指向谁」，是一张声卡的路由；这里说的是「通话的语音到底通不通」，
    /// 是模块里的驱动、校准和 PCM 桥。两件事的修法完全不同，界面也得分开说。
    @Published private(set) var voiceSetup = ModuleVoiceSetup.Status()
    /// 通话语音正在被自动修复。
    ///
    /// 模块一断电（拔线、换 USB 口、`AT+CFUN` 重启）就丢掉 insmod 进去的
    /// 厂商驱动和 PCM 桥 —— 那是内存里的东西，`/data/local/tmp` 里的 .ko
    /// 文件还在，加载状态没了。客户面前的表现是「昨天还能通话，今天插上
    /// 就没声音」。手动按钮藏在通话窗口里，客户不会为了一个还没坏的症状
    /// 提前去点它；所以模块一回来就自己补一遍，这里放个可见的进度。
    @Published private(set) var voiceRepairing = false
    /// 自动修复做到哪一步了，给设置页那一行当副标题（`inspect()` 太长）。
    @Published private(set) var voiceRepairStep: String?
    /// 通话音频桥在不在跑。通话窗口上那两行电平看的就是它。
    @Published private(set) var callVoiceLive = false
    /// 通话中的实时电平：`up` 是麦克风送进模块的音量，`down` 是对方的声音。
    @Published private(set) var callLevels = CallAudioBridge.Levels()
    /// 麦克风没授权。
    ///
    /// 2026-09-30 那通「接通 33 秒才出声」的电话，根因就是这个开关没打开
    /// （见 `MicPermission`）。授权之前 CoreAudio 起输入会卡在系统那个框上，
    /// 一卡就是几十秒；而框弹在这个没有窗口的 App 背后，客户看不见。
    ///
    /// 现在这一问提前到装完第一次打开，界面上还留一条「去授权」的路 ——
    /// 万一被拒过一次（系统不会再弹），客户至少知道去哪儿打开。
    @Published private(set) var micDenied = false
    /// 还没问过 —— 系统那个框还一次都没弹。和 `micDenied` 分开放，
    /// 是因为出路不同：没问过的点一下就能弹框，被拒过的只能进系统设置。
    @Published private(set) var micUnasked = false
    @Published private(set) var activity: [String] = []

    /// 最近一条 USSD 答复，给 AT 控制台那一行读。
    ///
    /// 单独存一份而不是塞进 AT 回显里：查话费的结果不是「发送」那一步回来的
    /// （模块先回 OK，网络那句话随后才到），混在回显里会被下一条命令冲掉。
    @Published private(set) var ussdResult: String = ""
    @Published private(set) var attachedIdentity: USBModuleIdentity?

    /// 系统里没允许通知。
    ///
    /// 「来电没弹提示」在客户眼里等于坏掉，而这台机器上（macOS 15）通知权限
    /// 就是没开的 —— 2026-09-25 的日志里每次启动都写着这一行。答案原来只进
    /// 活动列表，而活动列表按客户自己的要求是收起的：唯一能解释「电话为什么
    /// 没弹」的那句话，正好被折叠藏住了。面板顶上那行提示读的就是这个位。
    @Published private(set) var notificationsBlocked = false

    /// 4G 数据开关的位置 —— 面板中间那颗胶囊显示的就是它。
    ///
    /// 它从来不是 `data.isConnected`：关掉数据只是停掉 macOS 的网络服务和
    /// PDP，ECM 网卡和它的 DHCP 租约还挂在机器上，`isConnected` 会继续为真，
    /// 胶囊于是永远写着 `4G ON`，看着是标签不是开关 —— 2026-09-26 客户的
    /// 原话：「是不是要加一个数据的开关，不是只有一个关机图标」。也不跟
    /// `wantsDataLink` 合并：那个是「等 macOS 把服务建出来」的欠账标记，
    /// `ensureHostService` 一办完就清掉，开关不能跟着它闪。
    @Published private(set) var dataWanted = false
    /// 这一次运行里客户自己按过数据开关没有。
    ///
    /// 按过之后开关的位置由客户说了算，`data` 事件不许再动它：那事件是轮询
    /// 拍的快照，关掉数据的那一下它可能还揣着「服务是开的」的旧值，拿它同步
    /// 会把开关又推回 `ON`。没按过则相反 —— App 重启时机器的网卡和网络服务
    /// 可能本来就是开的（系统里的状态不随 App 退出消失），得让开关自己回到
    /// 「开」那一边。
    private var dataSwitchTouched = false

    /// 客人最后一次亲手拨这根开关的时刻。
    ///
    /// 拨完的两三秒里系统还没落地，而巡检那一路每两秒就看得见一次链路 ——
    /// 不设这道闸，刚按下去的那一下会被下一拍用旧事实原地推翻。过了这道闸
    /// 才允许「链路事实」说话，见 `syncDataWanted`。
    private var dataSwitchTouchedAt: Date?
    /// 按下数据开关时 AT 会话正忙，这一笔先记在这里，等手上那一步结束再执行。
    ///
    /// 开关不该被别的工作挡回来：面板顶上那颗刷新按钮、连上模块时的握手，
    /// 都会占住会话，而客户按开关的那一秒没法挑。被挡回来时那条红字
    /// 「上一步操作还没结束」对客户没有任何意义 —— 他只是想上网。
    private var pendingDataSwitch: Bool?
    /// 上一次说过的「4G 还在等什么」。见 `noteDataWaitOnce`。
    private var dataWaitNote: String?
    /// 被会话挡回去的那一下通话动作，等手上那一步结束再补。见 `callAction`。
    ///
    /// 和数据开关同一个道理，但更急：铃响只有半分钟，客人按了「接听」那一下
    /// 必须算数 —— 他不会再按第二次。
    private enum CallIntent { case answer, reject, hangup }
    private var pendingCallIntent: CallIntent?

    /// 通话音频桥。CoreAudio 的回调跑在音频线程上，所以这个对象不能是
    /// actor-isolated 的；起停都走 `callAudioQueue` 这一条串行队列，
    /// 「接通」和「挂断」不会互相插队。
    nonisolated let callBridge = CallAudioBridge()
    /// 一键安装「通话语音」那条通路（解锁 ADB → 驱动 → 校准 → PCM 桥）。只读的
    /// `inspect()` 不动模块，随时可以调。
    nonisolated let voiceProvision: ModuleVoiceSetup

    /// 模块正在重启 / 重新枚举的窗口。
    ///
    /// 一键启用、切 usbnet、开模块声卡都会让模块重启。重启期间 USB 上会出现
    /// 一个「看得见、打不开」的模块：IOKit 已经枚举到它，AT 接口还没起来，
    /// 三秒一次的重连必然失败。失败写成报错，就成了客户自己点出来的红字，
    /// 而那句「换个 USB 口试试」照着做也没有用。
    @Published private(set) var awaitingReconnect = false
    @Published private(set) var trafficSamples: [Double] = Array(repeating: 0, count: 48)
    @Published private(set) var todayBytes: UInt64 = 0
    @Published var lastError: String?
    @Published var isWorking = false

    /// Remaining-data ring needs a plan size; there is no AT command for it.
    @Published var quotaGB: Double {
        didSet { UserDefaults.standard.set(quotaGB, forKey: AppModel.quotaKey) }
    }
    @Published var autoApplyAPN: Bool {
        didSet { UserDefaults.standard.set(autoApplyAPN, forKey: AppModel.autoAPNKey) }
    }
    /// 客户选的那一档。存在这台电脑上：模块拔下来插到手机上时，这个 App 不在
    /// 场，所以「上次选的是哪一档」只能记在电脑这一边。
    @Published var hostModeChoice: HostMode {
        didSet { UserDefaults.standard.set(hostModeChoice.rawValue, forKey: AppModel.hostModeKey) }
    }
    /// Mirrors the LaunchAgent in `~/Library/LaunchAgents`. Without it the menu
    /// bar is simply empty after a reboot, and every call in that window is a
    /// missed one — with nothing on screen to explain why.
    @Published private(set) var startAtLogin = false

    /// `ModemController` owns its own locking and runs the AT session on its own
    /// threads, so it is deliberately not actor-isolated: the UI reads state on
    /// the main thread while commands are issued from a background queue.
    nonisolated let controller: ModemController
    /// 通话记录的读写都在这一层，界面只读 `callRecords` 那份快照。
    ///
    /// 两个 `init` 各给各的：真模块那一份读写
    /// `~/Library/Application Support/DJI4G/calllog.json`，模拟器那一份只活在
    /// 内存里（`persists: false`）。出图 / 自检 / 演示都走模拟器，要是也落盘，
    /// 客户点开「通话记录」看到的就是我们自己出图留下的行 —— 2026-09-30 实测
    /// 那一份里 28 行有 24 行是模拟器的号码。
    private let callHistory: CallHistory

    /// Set only on the screenshot path and the `--sim` launch path, where the
    /// panel is driven by `SimulatedATTransport` instead of the USB module.
    let simulator: SimulatedATTransport?
    /// True only for `--sim`. The setup window keys its 「模拟器」 block off
    /// this rather than off `simulator`, so the offscreen renderer — which is
    /// also a simulator but must produce the customer's screenshots — keeps
    /// drawing the real window.
    let isInteractiveSim: Bool
    private static let quotaKey = "DJI4G.quotaGB"
    private static let hostModeKey = "DJI4G.hostMode"
    private static let autoAPNKey = "DJI4G.autoApplyAPN"
    /// 「模块里现在这个 APN 是给哪张卡写的」。记 ICCID。
    ///
    /// 2026-09-26 加：模块里只要**有** APN，自动配 APN 那条路从此就一个字都不
    /// 碰 —— 这条规矩本来是为了保住「客户手选的那一家」，但客人把电信卡换成
    /// 移动卡以后，那张新卡就一直用着 CTNET，连不上网，而面板上什么都不会说。
    /// 记下 APN 的主人以后，「同一张卡上不动、换了卡才改写」才分得出来。
    ///
    /// 记 ICCID 而不是 IMEI：IMEI 是模块自己的号，换卡它不变，拿它判不出换卡。
    /// 不是 `private`：`--sim-check` 跑在真 App 进程里，用的是这台机器**真
    /// 那一份** UserDefaults，演完换卡得把键还原回去（同 `routeGraceSeconds`）。
    static let apnOwnerSIMKey = "DJI4G.apnOwnerSIM"
    /// 「有人在这台机器上按过运营商按钮，卡还没插」。见 `rememberAPNOwner`。
    static let apnManualKey = "DJI4G.apnManualPick"
    private static let dayKeyKey = "DJI4G.dayKey"
    /// 「今日 / 本月」现在是**累加**出来的，所以要落盘 —— 当天 / 当月的已用量
    /// 加一次就把结果写回去，重启以后接着加。旧的 `dayBaseKey` 只留给升级迁移
    /// 那一次读（见 `sampleTraffic`），不再写。
    private static let dayTotalKey = "DJI4G.dayTotal"
    private static let monthKeyKey = "DJI4G.monthKey"
    private static let monthTotalKey = "DJI4G.monthTotal"
    /// 接口计数器上一次的读数。有它才分得清「计数器归零了」和「真的没走流量」。
    private static let lastTotalKey = "DJI4G.lastTotal"
    /// How long a 「来电」 announcement waits for `+CLIP` before it settles for
    /// 「未知号码」. Long enough to cover the number arriving on the next poll,
    /// short enough that nobody notices the notification is a beat late.
    private static let ringNoticeGrace: TimeInterval = 1.2
    private static let dayBaseKey = "DJI4G.dayBaseline"
    /// True between "user asked for 4G" and "macOS is routing over the module".
    private var wantsDataLink = false
    /// 正有一个 `networksetup` 进程在后台开那条网络服务。
    ///
    /// 开服务这一句要拉进程，真机实测 3–4 秒才回来 —— 日志里那次「主线程卡住：
    /// 4 秒没有响应（卡住前的最后一个动作：刷新状态）」就是它，跑在主线程上
    /// 等于模块一连上就把面板冻住几秒。现在它跑在后台，而巡检每两秒就会叫一次
    /// `ensureHostService()`：没有这个闸，那 3 秒里会叠出两三个进程去抢同一个
    /// 网络服务。
    private var hostServiceInFlight = false
    /// 「模块这头出不了网」是从什么时候开始观察到的。
    ///
    /// 观察到不等于立刻动手：刚插卡、刚上电那几十秒本来就出不了网，一看到
    /// 就抢路由只会让默认路由在两块网卡之间来回跳。够 `routeGraceSeconds`
    /// 才认账，见 `guardDataRoute()`。
    private var dataLinkTroubleSince: Date?
    /// 这一次「默认路由还给 Wi-Fi」是 App 自己做的（不是客户关的）。
    ///
    /// 只有它会触发自动交回：客户要是自己按的 4G OFF，链路再通也不该自己
    /// 打开。见 `guardDataRoute()` 的第二段。
    private var routeRolledBackForSafety = false
    /// 上一次为这次故障排「停用模块网络服务」是什么时候，以及排过几次。
    ///
    /// `networksetup` 是异步的，排队期间每 2 秒一次的巡检会反复看到同一个
    /// 故障；没有这两条会把同一件事排很多遍。排满 `routeRollbackMaxTries`
    /// 次还没落地（多半是权限被拒），就把手工命令写进红字，不再刷。
    private var routeRollbackLastTry: Date?
    private var routeRollbackTries = 0
    /// 这台机器上，模块这条路**真的跑起来过**（默认路由压在模块那块网卡上）。
    ///
    /// 只给「服务被这条路之外的东西关掉之后自动收回」定界：没跑起来过就不替
    /// 客人做主。少了它，一台不让 App 改网络服务的机器（受管机器、权限被拒）
    /// 会在第一次按 4G 之后每三秒重排一个 `networksetup` 进程，红字刷满活动
    /// 列表 —— 而那条路上根本没有东西可收。
    private var hostLinkWasUp = false
    /// 上一次替他「把被关掉的服务收回来」是什么时候。
    ///
    /// 一个字段管两件事：`nil` 表示这一段「服务被关掉了」还没做过声（那句说明
    /// 只说一遍），有时间表示多久之前试过一次 —— 两次之间必须隔开，否则每
    /// 两三秒就拉一个 `networksetup` 进程、顺带一条走 AT 口的完整刷新。默认路由
    /// 回到模块上就清回 `nil`，下一次被关掉时那句话值得再说一遍。
    private var hostRestoreLastTry: Date?
    /// 观察窗与重试节拍。
    ///
    /// 8 秒。2026-09-26 真机事故那次是 25 秒 —— 客人的感受不是「App 在观察」，
    /// 是「我整台电脑没网了，还不知道为什么」。而这条判据看的三种情况
    /// （模块没连上 / 卡座里没卡 / 模块没注册）都是明确的状态，不是抖动：
    /// 真要抖也是模块那边先抖，注册回来之后 `guardDataRoute()` 会自己把路由
    /// 交回去，客人不必再按一次 4G。所以这里宁快不宁慢。
    ///
    /// 真机上从「没注册」到「注册上」通常 5–15 秒，8 秒会多还一次路由给
    /// Wi-Fi，代价是面板上多闪一行字；反过来 25 秒是实打实的断网。
    static let routeGraceSeconds: TimeInterval = 8
    /// 客人拨过开关之后，链路事实要等这么久才允许说话。系统落地那条网络服务
    /// 要几秒（`networksetup` 一跳 3–4 秒），闸比它长一点就够。
    private static let switchSettleSeconds: TimeInterval = 5
    private static let routeRetrySeconds: TimeInterval = 15
    /// 自动把被关掉的服务收回来，两次之间至少隔这么久。
    ///
    /// 不是为了让客人等，是为了不让「收了也收不回来」的机器（不让 App 改网络
    /// 服务的、受管机器）每两三秒被拉一个 `networksetup` 进程 + 一条完整刷新。
    /// 一分钟一次既能把临时性的失败自己等过去，也不会把日志刷满。
    private static let hostRestoreRetrySeconds: TimeInterval = 60
    private static let routeRollbackMaxTries = 3
    /// 「模块的网卡被系统漏掉」——观察到动手之间的宽限，以及两次之间的节拍。
    ///
    /// 正常插拔时，网卡节点出现和它拿到名字之间只隔不到一秒，15 秒纯粹是
    /// 给模块上电那一串接口慢慢出来的时间：宁可多等一会儿，也不能把一次
    /// 正常的插入当成故障去重启一遍模块。
    ///
    /// 90 秒的节拍跟 `hostRestoreRetrySeconds` 一个道理，只是因为代价更大：
    /// 重启一次模块要断网二十秒上下，试得密对客户没有任何好处。
    private static let strandedGraceSeconds: TimeInterval = 15
    private static let strandedRetrySeconds: TimeInterval = 90
    /// 试这么多次还救不回来就停手。剩下的交给客人 —— 拔一次再插一次永远
    /// 管用，而 App 这边再试下去只是把同一件事做第三遍。
    private static let strandedMaxReboots = 2
    /// 「网卡被系统漏掉」是从什么时候开始观察到的。
    private var strandedSince: Date?
    /// 上一次为这条故障重启模块是什么时候，一共试过几次。
    private var strandedLastReboot: Date?
    private var strandedRebootTries = 0
    /// 这一条已经试到头了，不再动手（拔插之后清回）。
    private var strandedGaveUp = false
    /// 「这台电脑现在真的能出网吗」最近一次实测的结果。
    ///
    /// 三条路各自管一件事：模块状态管「模块这头准备好没有」，`netProbe` 管
    /// 「准备好的这条路通不通」，`routeRolledBackForSafety` 管「路由现在在
    /// 谁手上」。模块状态全绿而实测不通，就是卡欠费 / APN 选错 / 上游断了的
    /// 那一类 —— 只有真发包才看得出来。见 `NetProbe`。
    private var netProbeReachable: Bool?
    private var netProbeCheckedAt: Date?
    private var netProbeInFlight = false
    /// 连着多少次实测出不了网。抖一下就抢路由会让默认路由在两块网卡之间
    /// 来回甩，所以只有连输 `probeFailuresToTrouble` 次才认账。
    private var netProbeFailures = 0
    /// 实测驱动的自动交回要等到的时刻。
    ///
    /// 停用服务以后网卡就没有 IPv4 了，**实测这条路自己就断了**，而模块那边
    /// 还会一直说自己好的 —— 照着「链路恢复就交回」办，就成了「关→开→关」
    /// 的循环。所以这一类的自动交回要退避，而且越退越久。
    private var routeRollbackNotBefore: Date?
    private var probeRollbackCount = 0
    /// 实测的节奏与门槛。3 秒一次、连输 2 次 ≈ 6–10 秒，再叠上那 8 秒观察窗，
    /// 一条真通的链路不会因为一次卡顿被换掉（三个目标现在是**同时**发的，
    /// 一次卡顿要同时打掉三个目标的概率很低），而一条「看着好其实不通」的
    /// 链路二十秒内就会被认出来。见 `NetProbe`。
    ///
    /// 2026-09-26 从 6 秒收到 3 秒：这条路径上的每一秒都是客人实打实的断网，
    /// 而实测本身已经并发化（最坏 3 秒出结果），所以整体节奏还是六秒上下 ——
    /// 只是那 3 秒的网络等待不再串行了。
    private static let probeInterval: TimeInterval = 3
    private static let probeFailuresToTrouble = 2
    /// Edge detector for call-state changes. `refreshCalls()` re-emits the same
    /// state on every poll, so anything that must happen once per call — the
    /// ring notification, the audio handover — is compared against this rather
    /// than run on every event.
    private var lastCallState: CallState = .idle
    /// Pending 「来电」 announcement. `RING` and `+CLIP:` are separate lines, so
    /// the caller's number is not known at the moment the ring starts; see
    /// `announceRing()`.
    private var ringAnnouncement: Timer?
    /// 模块报过至少一次卡的状态。
    ///
    /// 用来把「开机时卡就在」和「客户中途把卡推进去」分开：前者 `refreshAll`
    /// 本来就会连收件箱一起读，后者需要有人补那一下。
    private var sawSIMReport = false
    /// 「自动配 APN」这一台机器试过没有。一次会话只试一次：卡插上以后模块
    /// 才报得出运营商，而客户手选的那一家永远优先 —— 反复写只会跟手动选择
    /// 打架，失败时还会把同样的红字刷满活动列表。
    private var didAutoApplyAPN = false
    /// 一个连接只自动摆一次。切换那一档要重启模块，反复摆等于反复重启。
    private var didRestoreHostMode = false
    /// 注册上来之后那次补写排上了没有。`.network` 事件一次刷新里可能来好几
    /// 条（`+CREG?`/`+CEREG?`/URC 各一条），不去重就会排出好几条一模一样的
    /// `run`，客户在活动列表里看到三行「配 APN」。
    private var apnWriteQueued = false
    private var attachTimer: Timer?
    private var trafficTimer: Timer?
    /// 通话中读电平的定时器。桥只在通话里跑，所以这个定时器也只在那时候活。
    private var callLevelTimer: Timer?
    /// 电平日志的节拍。`DJI4G_VOICE_DEBUG=1` 时每 8 拍（2 秒）往活动列表
    /// 和 app.log 写一行上下行电平 —— 远程排查「听不到对方」时就靠它。
    private var callLevelTicks = 0
    /// 通话进入「通话中」的时刻。「接通了没有声音」要拿这之后的数据判，
    /// 响铃那一段不算（见 `CallAudioWatchdog.stallGrace`）。
    private var callActiveSince: Date?
    /// 这一通已经为「两只耳朵都没声音」重接过一次没有。
    /// 每种原因**每通只修一次** —— 修不好说明不是这条路能修的，反复拆装
    /// 只会把一通好电话拆坏。
    private var callSilentRetryDone = false
    /// 这一通的自动重接次数（`dead` 那一档用的，比 silence 宽一档）。
    private var callRecoveryAttempts = 0
    /// 有重接正排在队列上。这一条是必须的：判据每四分之一秒跑一次，而
    /// 拆装是异步的 —— 没有它，同一个「断了」会在半秒内把两次机会一次用完。
    private var callRecoveryInFlight = false
    /// 这一通起桥失败后自动再试了几次。
    private var callStartAttempts = 0
    /// 通话状态轮询连续失败了几拍。见 `notePollHealth`。
    private var pollFailures = 0
    /// 轮询成功的节拍，只给 `DJI4G_VOICE_DEBUG=1` 的心跳用。
    private var pollTicks = 0
    /// 桥的起停队列。见 `callBridge` 上面那段。
    private static let callAudioQueue = DispatchQueue(label: "com.dji4g.call-audio")
    /// 一通电话里最多自动重接几次。每接一次都要重新打开四个 AudioUnit，
    /// 两次够覆盖「模块刚换完设备号、下一拍才回来」这一档；再多就是在客户的
    /// 通话中间反复折腾了。
    private static let callRecoveryLimit = 2
    /// 起桥失败后自动再试的次数。模块在通话开始时会重配一次 USB，那一下正好
    /// 落在起桥的两秒里的话，端点会短暂找不到 —— 隔两秒再看它就在了。
    private static let callStartAttemptsLimit = 3
    /// 所有 CoreAudio 设备枚举 / 切换都排在这条串行队列上。
    ///
    /// `refreshStatus()` 要枚举全部音频设备并逐个取属性，而通话开始 / 结束这
    /// 一刻正好是模块的 USB 声卡被重新配置的时候，HAL 会把这些 `AudioObject*`
    /// 调用挡住好几秒。事件是 `DispatchQueue.main.async { apply(...) }` 送上来的，
    /// 所以在主线程上读它 = 每来一个电话就冻一次界面：铃声卡片画不出来、通知
    /// 压着不发。2026-09-25 本机两次「主线程卡住：4 秒没有响应」都落在来电那几秒。
    ///
    /// 串行还顺手保证 `activate()` / `deactivate()` 不会互相踩它们记着的
    /// `savedInput` / `savedOutput`。
    private static let voiceDeviceQueue = DispatchQueue(label: "com.dji4g.voice-device")
    /// 通话语音的体检（`ModuleVoiceSetup.inspect()`）要起 `adb` 子进程、还要抢
    /// 一次 AT 会话 —— 两样都不该在主线程上等。三个调用点（开面板、开设置页、
    /// 来电起桥）各自的时机恰好是 adb 最慢的时候：USB 刚插上、来电时 USB 正在
    /// 重配。单独一条队列，体检再慢也挤不到 CoreAudio 那条。
    private static let voiceProbeQueue = DispatchQueue(label: "com.dji4g.voice-probe")
    /// 来电的第二条通道。
    ///
    /// 模块只在 `RING` 那条 URC 上告诉你有电话进来，而 URC 会因为任何一次时序
    /// 错位丢掉（模块刚重启、串口正忙、上一次通话的状态没清干净）。客户面前
    /// 「没有来电」和「来电被漏掉」长得一模一样，所以除了 URC 再补一条轮询：
    /// 空闲时它读到的永远是「没有通话」，代价是一条 AT 命令；真的有人打进来时
    /// 它就是那条救命的通道。
    private var callTimer: Timer?
    private var isPollingCall = false
    /// 来电要不要弹那张浮在最上面的卡片。
    ///
    /// 真机启动和 `--sim` 交互演示都弹；`--render` 截图和 `--sim-check` 自检
    /// 不弹 —— 那两条路会造出来电，而它们必须保持在后台，不能有窗口跳出来
    /// 抢焦点（截图里也不该混进一张只属于真实来电的卡片）。
    private(set) var announcesAlerts = true
    /// 「本月」的累加值。真机路径上是它，不是接口计数器（见 `monthBytes`）。
    private var monthAccumulated: UInt64 = 0
    /// 上一拍是不是还在后台读计数。两秒一拍，读一次要几十毫秒；上一次没回来
    /// 就跳过这一拍，不排队。队列排起来只会让数字越算越晚，不会让它们更准。
    private var isRefreshingCounters = false
    /// 日期键的格式器。只从主线程用（`init` 和两秒一拍的采样），DateFormatter
    /// 不是线程安全的，所以这里刻意不共享给后台队列。
    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    /// Set when a read-back is asked for while a write owns the session.
    ///
    /// Reads are repeatable, so the right answer for them is 「等这一步做完再
    /// 读一次」 rather than the flat refusal an action gets. Every caller of a
    /// read arrives during somebody else's write sooner or later: the connect
    /// handshake applies the carrier APN and then reads the link back, the
    /// refresh button is clickable while the module reboots, and the demo
    /// harness reads twice on purpose. Refusing those was wrong twice over —
    /// it painted a red line the user had not caused, and it left the panel
    /// showing numbers nobody had re-read.
    private var readPending = false

    /// `awaitingReconnect` 背后的截止时间，以及「这条等待只写一次日志」的
    /// 闸门：三秒一次的失败如果每回都记一笔，十几行一样的字会把客户真正要
    /// 看的东西挤出活动列表。
    private var reconnectDeadline: Date?
    private var loggedReconnectWait = false
    /// 掉线复核正在跑，免得定时器叠出两个并发的 IOKit 扫描。
    private var isRecheckingAttachment = false
    /// 连着的时候 IOKit 一次没看见模块，不急着判断「拔了」：USB 重新枚举、
    /// 系统忙的时候都可能空一拍，连空两拍（约六秒）才断开。
    private var missedAttachScans = 0
    /// 自动修复的闸门与冷却。
    ///
    /// `isRepairingVoice` 挡的是定时器叠拍：`install()` 全程要几十秒，而
    /// 那一拍一拍是三十秒一次，不挡就会同时跑两份 `insmod` 和两条 PCM 桥。
    /// `voiceRepairNotBefore` 挡的是失败重试的风暴：`inspect()` 每次都要起
    /// `adb devices` 加一条 `adb shell`，失败时三十秒一次地重来只是白烧
    /// CPU，还会把模块的 dmesg 刷满。失败退避五分钟，缺 ADB 那种退一分钟
    /// —— 后者多半只是模块还在枚举，等一会儿就好了。
    private var isRepairingVoice = false
    private var voiceRepairNotBefore: Date?
    /// 自动修复的定时器。拿着引用只是为了将来能停它，和另外三条一个待遇。
    private var voiceRepairTimer: Timer?
    /// 上一次**实测**语音通路是什么时候。
    ///
    /// `voiceSetup.ready` 是一张会过期的照片：桥是个后台进程、`audio_enable`
    /// 是 sysfs 里的一个值，两样都能在 App 没看见的情况下没掉（模块自己重启、
    /// USB 被系统挂起）。只信开机时那一次体检，客户会碰上「上次还好好的，
    /// 这次没声音，界面还写着已就绪」。所以就算已知是好的，五分钟也复核一次。
    ///
    /// 五分钟而不是十分钟：复核只是两下 `adb`，成本按毫秒算，而它兜住的
    /// 是「客户正要打电话」。2026-09-26 实测：把 `audio_enable` 写 0、校准
    /// 抹掉，App 自己在下一拍就把两个位补回来了。
    private var voiceSetupVerifiedAt: Date?
    /// 「还轮不到我」连着数了几次。见 `runVoiceAutoRepair` 里那段退避。
    private var voiceAdbWaitAttempts = 0
    /// 每次插上只往活动列表写一条「在等什么」。反复写会把列表刷满，而客户
    /// 从这条里读不出新东西；客服看日志要的也只是这一次为什么在等。
    private var voiceBailLogged = false

    /// 出图专用：`seedVoiceSetup()` 立起来的钉子。钉着的时候任何真机探测都
    /// 不许改写那一格 —— 它是图片的一部分，不是当前这一刻的硬件事实。
    private var voiceSetupPinned = false

    /// 出图时把麦克风授权那一行钉成「没授权」。
    ///
    /// 和 `voiceSetupPinned` 同一个理由：`CallWindow.onAppear` 会真去读一遍
    /// TCC，而读出来的是**出图这台机器**的答案（多半是已授权），种下去的
    /// 状态会被它当场刷掉 —— 图上就什么都看不见了。
    private var micStatePinned = false

    /// 出图专用：`seedIncomingCall()` 立起来的钉子，理由同上一颗。
    ///
    /// 通话那一格每两秒被 `refreshCalls()` 重报一次，而真机上并没有人在打
    /// 电话 —— 不钉住的话，摆好的「响铃」会在下一次轮询里被改回「空闲」，
    /// 导出的封面图又是空的（2026-09-27 实际踩到）。
    private var callPinned = false

    init() {
        let stored = UserDefaults.standard.double(forKey: AppModel.quotaKey)
        let controller = ModemController()
        self.controller = controller
        callHistory = CallHistory()
        self.voiceProvision = ModuleVoiceSetup(session: controller.session)
        simulator = nil
        quotaGB = stored > 0 ? stored : 0
        autoApplyAPN = UserDefaults.standard.object(forKey: AppModel.autoAPNKey) as? Bool ?? true
        hostModeChoice = HostMode(rawValue: UserDefaults.standard
            .string(forKey: AppModel.hostModeKey) ?? "") ?? .mac
        startAtLogin = LoginItem.status().installed
        isInteractiveSim = false
        wireCallbacks()
        Notifier.shared.prepare()

        // 装完第一次打开就问麦克风，别等第一通电话（那次会白等几十秒，
        // 见 `MicPermission` 的注释）。放在几秒之后：先让菜单栏图标和面板
        // 站稳，系统那个框才压在最前面。已经授权 / 已经拒绝的不会重复弹。
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            // 和下面那几条定时器同一个写法：`asyncAfter` 收 `@Sendable` 闭包，
            // 而这具身体碰的全是主线程状态，得回主 actor 里再动。
            Task { @MainActor in
                self?.askForMicrophoneIfNeeded()
                // 已经授权过的那台机器上面这一句什么都不做，状态位还得有人摆。
                self?.refreshMicrophoneState()
            }
        }
        restoreUsage()
        // 通知没被允许时「来电不弹提示」在客户眼里就是坏了。把系统设置里的
        // 真实情况写进活动列表，客服一句话就能说清该怎么办。
        Notifier.shared.onAuthorizationChange = { [weak self] note in
            self?.note(note)
            self?.notificationsBlocked = Notifier.shared.authorizationGranted == false
        }
        scanForModule()
        attachTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.expireAwaitReconnectIfNeeded()
                self?.scanForModule()
                // 2026-09-26 交付当天第二起真机事故，就出在这盏灯缺的这一行上。
                //
                // 模块拔插回来时，「4G 又能出网了，默认路由交回模块」那句话是在
                // USB 刚枚举完、`en59` 还没被 macOS 发布出来的那一瞬说的，于是
                // `ensureHostService()` 卡在 `hasInterface` 上原地返回。而它以前
                // 只在**完整刷新**里被叫一次 —— 完整刷新是打开面板 / 手动刷新 /
                // 切模式才有的，客人不开面板就永远等不到第二次。结果是那笔「还欠
                // 着一条链路」的账一直挂着：服务停着，macOS 不肯给停用的服务拉起
                // 网卡，`en59` 就一直 `inactive`，两边互相等死。现场对得上 ——
                // 17:02:31 说完那句话以后日志一片安静，到 17:05 服务还停着。
                //
                // 这盏灯每三秒亮一次就够了：`wantsDataLink` 为假时它第一行就返回，
                // 一次进程都不拉；为真时它盯着接口出现，出现即补上。
                self?.ensureHostService()
                // 模块不在时也要跑：路由保命那一条不靠轮询数据，靠的是
                // 「服务还开着但模块出不了网」，见 `guardDataRoute()`。
                self?.guardDataRoute()
                // 2026-09-27 的第四类故障，跟上面两条都不是一回事：模块枚举
                // 好了，**系统那一半没做完** —— 网卡挂在 IOKit 里，却没被起
                // 名字（插模块的时候屏幕锁着）。这一条`ensureHostService()`
                // 永远救不了：它看到的是「网卡还没出现」，会一直等下去。
                self?.recoverStrandedInterface()
            }
        }
        trafficTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCountersThenSample() }
        }
        callTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollCallState() }
        }
        // 语音体检比别的慢一拍，因为它要起子进程：三十秒一次够了。
        // 真跑起来的时候一分钟都用不上 —— 这条定时器的价值在「插回来以后
        // 自己好」，而不是「快」。
        voiceRepairTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkVoicePathIfNeeded() }
        }
    }

    /// Demo / screenshot path. Every screen in the app is driven from the
    /// simulator, so the panel can be rendered and inspected on a machine with
    /// no module attached, and nothing here touches IOKit or the network.
    /// `planGB` 只在截图路径上有值。空卡座那一版传 0，画的才是客户第一次
    /// 打开面板时看到的东西：还没填套餐，主屏显示信号而不是流量环。
    init(simulator: SimulatedATTransport, planGB: Double = 300.4,
         interactive: Bool = false) {
        self.simulator = simulator
        let controller = ModemController(session: ATSession(factory: { simulator as ATTransport }))
        self.controller = controller
        // 模拟器不碰客户那份通话记录，见 `callHistory` 的说明。
        callHistory = CallHistory(persists: false)
        self.voiceProvision = ModuleVoiceSetup(session: controller.session)
        quotaGB = planGB
        autoApplyAPN = false
        // 这一档只在真模块上按客户上次的选择自动回位
        // （`restoreHostModeIfNeeded`）。出图和 `--sim` 走的都是内存里的模拟件，
        // 别在那条路上凭空往活动列表里写一条「按上次的选择」。
        hostModeChoice = .mac
        didRestoreHostMode = true
        // Pinned instead of read from the real `~/Library/LaunchAgents`: the
        // screenshots have to come out identical on every machine. On means
        // what a customer actually sees, because the installer turns it on.
        startAtLogin = true
        isInteractiveSim = interactive
        // 截图与自检都从这条路进来；要弹卡片的那条（`--sim` 演示）随后会在
        // `beginInteractiveDemo` 里把它打开。
        announcesAlerts = false
        wireCallbacks()
    }

    // MARK: - Command line

    /// Picks the live or the simulated backend at launch.
    ///
    /// `--sim` and `--sim-nosim` run the **whole app** — panel, call window,
    /// setup window — against `SimulatedATTransport`, which is how the
    /// interface gets clicked through on a bench with no module attached. The
    /// spelling is deliberately identical to `dji4gctl --sim`, so there is one
    /// set of arguments to remember for both.
    ///
    /// Nothing here reaches hardware: no IOKit scan runs, no AT port is
    /// opened, and the host half of the data link is *pinned* rather than read
    /// (see `DataService.overrideHostState`). That last part is why a
    /// simulated run cannot disturb this Mac's real network settings.
    ///
    /// `arguments` and `announce` are injectable so the headless check in
    /// `RenderHarness.checkSimulator` can drive this exact selection logic
    /// without touching Notification Center.
    static func launch(arguments: [String] = CommandLine.arguments,
                       announce: Bool = true) -> AppModel {
        let emptySlot = arguments.contains("--sim-nosim")
        guard emptySlot || arguments.contains("--sim") else { return AppModel() }
        let model = AppModel(simulator: SimulatedATTransport(scenario: emptySlot ? .noSIM : .ready),
                             planGB: emptySlot ? 0 : 300.4,
                             interactive: true)
        model.beginInteractiveDemo(emptySlot: emptySlot, announce: announce)
        return model
    }

    /// Opening state for the interactive simulator.
    ///
    /// The inbox is seeded, and the cards and the USB audio device are pinned,
    /// so that the first click on each tab lands on something. A demo that
    /// answers "and what does this look like?" with a blank field answers
    /// nothing.
    private func beginInteractiveDemo(emptySlot: Bool, announce: Bool) {
        // Stated before the session opens on purpose. The handshake's first
        // `refreshData()` runs on a background thread, and if it landed first it
        // would write an empty interface over the pinned one — the panel would
        // greet the user with 「未绑定服务」 until the next poll caught up.
        // Pinning first makes the order irrelevant. Neither call reaches
        // hardware: both only set state that the refresh is then told to leave
        // alone.
        if !emptySlot {
            seedHostLink(interface: "en17", ipv4: "10.42.7.19", service: "Baiwang", enabled: true)
            seedModuleAudio(name: "USB Audio Device")
        } else {
            // 空卡座这一版也要钉住，而且钉的是「空」。不钉的话 refreshStatus()
            // 会去读**这台 Mac 的真实网卡** —— 在插着模块的机器上（做交付的那台
            // 就是）面板会显示 192.168.225.x，空卡座的演示看起来像「没插卡却已经
            // 联网了」。模拟运行本来就不该碰宿主的网络事实，这一条和上面那条是
            // 同一个理由的两半。
            seedHostLink(interface: "", ipv4: "", service: "", enabled: false)
        }

        do {
            try startSimulator()
        } catch {
            FileHandle.standardError.write(Data("模拟器启动失败：\(error)\n".utf8))
            exit(1)
        }
        // `startSimulator` opens at the renderer's cadence, which is ten times
        // a second — right for a one-shot screenshot, wasteful for a window
        // somebody is reading. Drop to the interval the live app polls at.
        controller.startPolling(interval: 1.0)

        guard let simulator, !emptySlot else { return }
        announcesAlerts = announce
        if announce { Notifier.shared.prepare() }
        simulator.sentBytes = 700_000_000
        simulator.receivedBytes = 172_000_000_000
        _ = simulator.injectIncomingSMS(text: "您本月剩余流量 127.7GB，回复 CXLL 查询详情。", from: "10086")
        _ = simulator.injectIncomingSMS(text: "验证码 861324，5 分钟内有效，请勿转告他人。", from: "106903001234")
        refreshAll()
    }

    // MARK: - Simulator-only actions

    /// Reachable only from the 「模拟器」 block in the setup window, which is
    /// drawn only when `isInteractiveSim` is true. These are the ring / unread
    /// / call-waiting paths that a bench without a module cannot otherwise
    /// reach — and that a bench without a *card* cannot reach either.
    func simulateIncomingSMS() {
        guard let simulator else { return }
        _ = simulator.injectIncomingSMS(text: "这是一条模拟短信，用来走一遍收信流程。", from: "10086")
        note("模拟：收到 10086 的短信")
    }

    func simulateIncomingCall() {
        guard let simulator else { return }
        simulator.simulateIncomingCall(from: "+8613800138000")
        note("模拟：+8613800138000 来电")
    }

    func simulateRemoteHangup() {
        guard let simulator else { return }
        simulator.simulateRemoteHangup()
        note("模拟：对方挂断")
    }

    /// Attach the event bridge once the owned objects exist; both initialisers
    /// route through here so the live and simulated paths cannot drift.
    private func wireCallbacks() {
        controller.onEvent = { [weak self] event in
            DispatchQueue.main.async { self?.apply(event) }
        }
        controller.onTransportLost = { [weak self] in
            DispatchQueue.main.async {
                // 客户视频里 `4G` 变斜杠天线的那一下就是这里。记下来，
                // 才能和「菜单面板有没有打开」对上时间。
                AppLog.log("模块断开：传输层丢了")
                self?.note("模块已断开")
                self?.isConnected = false
                self?.transport = "未连接"
            }
        }
    }

    // MARK: - Simulator harness

    /// The live path learns that a module exists from `scanForModule`; the
    /// simulator path has no attach event, so it opens the session itself.
    func startSimulator() throws {
        try controller.connect()
        isConnected = true
        controller.startPolling(interval: 0.1)
        afterConnect()
    }

    /// Real traffic samples come from interface counters, which do not move
    /// while the panel is rendered offscreen; the harness paints them in.
    func seedTraffic(traffic: [Double], today: UInt64) {
        trafficSamples = traffic
        todayBytes = today
    }

    /// 面板上那个两秒一次的节拍：先在后台补一次接口计数，回到主线程再采样。
    ///
    /// 顺序不能反 —— `sampleTraffic()` 读的是 `data` 上缓存的数字，先采样后刷新
    /// 等于拿上一拍的读数算这一拍的增量。
    ///
    /// 补计数走 `refreshHostCounters()`：**一条 AT 都不发**，所以通话期间照跑。
    /// 通话时 AT 口归语音链路，在别人的电话里插一条命令，代价可能是一通被掐掉
    /// 的电话。这也是它不能直接调 `refreshData()` 的原因（那条会读 USB 组态，
    /// 还会拉 `networksetup`）。
    /// 数据开关的位置跟着**事实**走。
    ///
    /// 这根开关只写「客人想不想要」，链路真不真通是另一回事，于是面板上一直
    /// 有一个空子：从别处动过那条网络服务（系统设置里点了停用、在终端里开的、
    /// macOS 自己在重新枚举之后恢复的），App 这边没人知道 —— 开关就停在上一次
    /// 的状态上。2026-09-30 客户现场反馈的正是这一条：面板开着、流量明明在走，
    /// 开关读出来却是「关」，点一下 App 才对。
    ///
    /// 判据用的是这一拍**刚读到的**事实，不是缓存：`fresh` 来自
    /// `refreshCountersOnly`，它每次都会重新问一遍网卡和地址；路由表那一问
    /// （`NetProbe`）本来就是当场算的 —— 这正是 `data.serviceEnabled` 那个
    /// 缓存值靠不住的地方，它只在完整刷新里更新。
    ///
    /// 只在「链路自己通着而开关是关的」这一个方向补齐，反向不做：网卡掉线 /
    /// 模块被拔出来的时候 `isRoutable` 也会变假，照着把开关摆到关，客人下次
    /// 插上模块就得再按一次。那个方向的关，只有客人自己按、或者 `guardDataRoute`
    /// 判断这条链路真出不了网时才写。
    private func syncDataWanted(_ fresh: DataStatus) {
        // 客人刚刚亲手拨过：这两三秒里系统还在落地，等下一拍再说。
        if let at = dataSwitchTouchedAt, Date().timeIntervalSince(at) < Self.switchSettleSeconds { return }
        // 他按的 OFF 还欠着没落地，或者正排队 —— 让位，别和客人抢。
        if let pending = pendingDataSwitch, !pending { return }
        // 刚从「出不了网」里把路由还回 Wi-Fi，正等链路自己好起来 ——
        // 那一段有自己的节奏（`routeRollbackNotBefore`），这里插一脚只会打架。
        if routeRolledBackForSafety { return }
        // 实测刚说过这条链路出不了网：开关先别摆到「开」，等它真好了再说。
        // 这个值只会在默认路由押在模块上的时候更新（见 `startNetProbeIfNeeded`），
        // 路由交回来的时候会被清成 nil —— 所以一个 `false` 指的一定是这条 4G。
        if netProbeReachable == false { return }
        guard !dataWanted else { return }

        let live = fresh.isRoutable
            || fresh.pdpActive
            || NetProbe.defaultRouteIsOn(interface: fresh.interfaceName)
        guard live else { return }

        let wasOff = dataSwitchTouched     // 客人之前按过，开关停在 OFF 上
        dataWanted = true
        dataSwitchTouched = true
        note(wasOff ? "4G 已经在通了，数据开关跟上" : "4G 已经在通了")
    }

    private func refreshCountersThenSample() {
        guard isConnected, !isRefreshingCounters else { return }
        isRefreshingCounters = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let fresh = self.controller.refreshHostCounters()
            Task { @MainActor in
                // 直接落值，不等 `onEvent` 那条异步回调：这一拍的采样必须排在新
                // 读数之后，而两条主线程任务谁先到不该由运气决定。
                self.data = fresh
                // 还没人按过开关，而链路是活的 —— 就把开关摆到「开」。这一段和
                // `onEvent` 里那条是同一件事，多这么一处是因为那条只在**完整
                // 刷新**里跑，而完整刷新只发生在模块刚连上 / 客人打开面板 / 手动
                // 刷新这几个时刻。链路从别的路径起来的时候（macOS 自己恢复了那条
                // 服务、在终端里开的、模块重新枚举之后）面板多半是关着的，那条路
                // 永远等不到 —— 2026-09-27 真机实测：服务从外面打开、默认路由已经
                // 压在模块上，App 这边 `dataWanted` 还是假，收回逻辑整段被闸掉。
                // 两秒一次的这条一直在走，补在这里。
                //
                // 判据里的路由表是主角：这款模块在 ECM 模式下 `AT+QIACT?` 不报
                // 活跃（真机实测 pdp/routable 双双为假，而路由明明压在它身上），
                // 只认 AT 那两问就会漏掉整整一类「链路已经通了」的情形。
                if !self.dataSwitchTouched,
                   fresh.isRoutable || fresh.pdpActive
                    || NetProbe.defaultRouteIsOn(interface: fresh.interfaceName) {
                    self.dataWanted = true
                }
                self.isRefreshingCounters = false
                self.syncDataWanted(fresh)
                self.sampleTraffic()
                // 两秒一次的巡检顺手保一次默认路由：客人拔卡换卡的时候面板
                // 多半是关着的，没有人按刷新，这是唯一还在走的周期路径。
                self.guardDataRoute()
            }
        }
    }

    /// 上一次运行留在盘上的用量。
    ///
    /// 跨天 / 跨月的清零交给第一拍 `sampleTraffic` 去做 —— 只有那时候才知道
    /// 接口计数器的当前读数，也只有那时候才能把增量锚点一起挪对。
    private func restoreUsage() {
        let defaults = UserDefaults.standard
        let today = Self.dayKeyFormatter.string(from: Date())
        if defaults.string(forKey: AppModel.dayKeyKey) == today {
            todayBytes = UInt64(defaults.double(forKey: AppModel.dayTotalKey))
        }
        if defaults.string(forKey: AppModel.monthKeyKey) == String(today.prefix(7)) {
            monthAccumulated = UInt64(defaults.double(forKey: AppModel.monthTotalKey))
        }
    }

    /// 「本月」那一格和流量环共用的数字。
    ///
    /// 真机路径上它是累加值，能跨重启、跨拔插、跨换 USB 口 —— 接口计数器恰好
    /// 会在这三件事上归零（见 `sampleTraffic`）。截图 / 自检路径上没有累加这回
    /// 事，用量由 `seedTraffic` 写死，这里直接报接口计数器，画出来才和交付的
    /// 那一版一致。
    var monthBytes: UInt64 {
        simulator == nil ? monthAccumulated : data.bytesIn + data.bytesOut
    }

    /// 读一拍的流量增量，并把「今日 / 本月」往前推。
    ///
    /// 以前这两个数字是从「当前读数 − 基线」现算的，基线只在跨天那一刻落一次。
    /// 那个算法有一个会伤到客户的坏法：接口计数器在重启、拔插、换 USB 口之后
    /// 归零，减法一算，已用流量整段消失，余量环回到 100%，客户照着它用就会超
    /// 套餐。累加制把看不见的那一段留在盘上。
    private func sampleTraffic() {
        // 演示和截图路径的用量是夹具写死的（`seedTraffic`），不能被这里改写。
        guard simulator == nil, isConnected else { return }
        let defaults = UserDefaults.standard
        let total = data.bytesIn + data.bytesOut
        let today = Self.dayKeyFormatter.string(from: Date())
        let month = String(today.prefix(7))

        // ---- 跨月 / 跨天 ----
        //
        // `storedXxx == nil` 那两个分支是给「第一次跑带累加制的版本」的那台机器
        // 用的：老版本没有累加制，「今日」的定义是「当前读数 − 当天首读」，
        // 「本月」直接就是接口计数器。第一次不能归零 —— 客户看到用量凭空清零，
        // 那一下在他眼里就是「流量卡被重置了」，之后他会照着错的余量用。
        let storedMonth = defaults.string(forKey: AppModel.monthKeyKey)
        if storedMonth != month {
            monthAccumulated = storedMonth == nil ? total : 0
            defaults.set(month, forKey: AppModel.monthKeyKey)
        }

        let storedDay = defaults.string(forKey: AppModel.dayKeyKey)
        let oldBaseline = UInt64(defaults.double(forKey: AppModel.dayBaseKey))
        if storedDay != today {
            if storedDay == nil {
                todayBytes = total >= oldBaseline ? total - oldBaseline : 0
            } else {
                todayBytes = 0
                // 增量锚点跟着挪：App 关着的那段时间模块还在走，不重新锚，这一
                // 整段会被算进新的一天。
                defaults.set(Double(total), forKey: AppModel.lastTotalKey)
            }
            defaults.set(today, forKey: AppModel.dayKeyKey)
        } else if defaults.object(forKey: AppModel.dayTotalKey) == nil {
            todayBytes = total >= oldBaseline ? total - oldBaseline : 0
        }

        // ---- 这一拍的增量 ----
        // 计数器只增不减。变小就是接口重建了（重启、拔插、换 USB 口），当前读数
        // 本身才是「重建之后走过的量」，整段都算增量 —— 按减法处理的话，重建
        // 之前的用量会被当成负增量丢掉。
        let previous = (defaults.object(forKey: AppModel.lastTotalKey) as? Double)
            .map(UInt64.init)
        let delta: UInt64 = previous.map { total >= $0 ? total - $0 : total } ?? 0
        defaults.set(Double(total), forKey: AppModel.lastTotalKey)

        // 真实流量来自 `NET_RT_IFLIST2` 的计数器，所以这里是实打实的增量而不是
        // 估算。流量环和这条曲线读的是同一个数。
        trafficSamples.append(Double(delta))
        if trafficSamples.count > 48 { trafficSamples.removeFirst(trafficSamples.count - 48) }

        todayBytes += delta
        monthAccumulated += delta
        defaults.set(Double(todayBytes), forKey: AppModel.dayTotalKey)
        defaults.set(Double(monthAccumulated), forKey: AppModel.monthTotalKey)
    }

    // MARK: - Attach / detach

    /// 夹具专用：让「设备在不在」这个问题由夹具回答，而不是 IOKit。
    ///
    /// `--nomodule` 要画的是「客户还没插模块」那一版文案，可开发机上模块是常年
    /// 插着的 —— 2026-09-26 复查时就是这样：那张图里画出来的是一个连着的模块，
    /// 它要审的那段文案一个字都没出现。换到没插模块的机器上跑又变成另一种不可
    /// 复现（受限环境里 IOKit 会被直接拒掉，画出来的是「连接失败」）。
    ///
    /// 所以在**构造模型之前**写一次，之后只读；生产路径永远不设它，默认就是
    /// 真扫描。写成 `nonisolated(unsafe)` 是因为它要在后台队列上被读 —— 前提
    /// 正是「先写、后读、不再改」，谁要改成可变的，这里先得重新想清楚。
    nonisolated(unsafe) static var scanOverride: (@Sendable () -> [USBModuleIdentity])?

    /// Runs the enumeration on a background queue: `attachedIdentities()` walks
    /// IOKit and must never block the main thread while the module enumerates.
    func scanForModule() {
        guard !isConnected else {
            // 连上的时候也要看一眼模块还在不在。客户拔掉模块以后，面板会一直
            // 停在最后一组数字上，菜单栏也还挂着信号条 —— 线都拔了还显示 4G，
            // 比显示「没连上」更像坏了。
            verifyStillAttached()
            return
        }
        let scan = Self.scanOverride ?? { USBATTransport.attachedIdentities() }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = scan()
            DispatchQueue.main.async {
                guard let self, !self.isConnected else { return }
                self.attachedIdentity = found.first
                if let found = found.first {
                    self.connect(using: found)
                } else if self.transport == "未连接" {
                    self.attachedIdentity = nil
                }
            }
        }
    }

    /// 连着的时候复核模块还在不在，走了就断开。
    ///
    /// 轮询里的失败是被 `try?` 吞掉的（一条命令读不到不该把整轮读数打断），
    /// 所以「模块被拔了」在 App 里本来没有任何人会发现。设备在不在只能问
    /// IOKit，而 IOKit 要在后台队列上问。
    private func verifyStillAttached() {
        // 模拟器背后没有硬件，查了就会把演示用的模块当成「被拔掉」。
        guard !isInteractiveSim, !isRecheckingAttachment else { return }
        isRecheckingAttachment = true
        let scan = Self.scanOverride ?? { USBATTransport.attachedIdentities() }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRecheckingAttachment = false
                guard self.isConnected else { return }
                guard found.isEmpty else { self.missedAttachScans = 0; return }
                self.missedAttachScans += 1
                guard self.missedAttachScans >= 2 else { return }
                self.missedAttachScans = 0
                // 客人把模块拔了：自愈那一段从头再来。下次插上多半带着新的
                // 插拔时机（也许又是在锁屏），该给的两次机会一次都不能少。
                self.resetStrandedRecovery()
                self.note("模块已拔出。插回来会自动重连")
                self.disconnect()
            }
        }
    }

    /// 让模块重启的那几步，收尾走同一条路：先记下「等它回来」，再断开。
    ///
    /// `run` 的 body 跑在后台队列上，`isConnected` / `activity` 这些
    /// `@Published` 只能在主线程改，所以这里整段回到主线程再做。
    private func awaitModuleReboot(seconds: TimeInterval = 45, note text: String) {
        DispatchQueue.main.async {
            self.beginAwaitReconnect(seconds: seconds)
            self.note(text)
            self.disconnect()
        }
    }

    /// 打开「等模块重启回来」的窗口。四十五秒是留给重启加重新枚举的：
    /// 一代模块 `AT+CFUN=1,1` 之后通常十几秒回来，慢的时候二十几秒。
    func beginAwaitReconnect(seconds: TimeInterval = 45) {
        reconnectDeadline = Date().addingTimeInterval(seconds)
        loggedReconnectWait = false
        awaitingReconnect = true
    }

    /// 连上了，或者窗口到点了，都走这里。
    func clearAwaitReconnect() {
        awaitingReconnect = false
        reconnectDeadline = nil
    }

    /// 窗口到点还没回来就收起那句话。真出了问题的时候，三秒一次的重连失败
    /// 必须重新变回红字 —— 否则客户守着「模块重启中」永远等不到一句能照着
    /// 做的话。
    private func expireAwaitReconnectIfNeeded() {
        guard awaitingReconnect else { return }
        if isConnected { clearAwaitReconnect(); return }
        if let deadline = reconnectDeadline, Date() >= deadline { clearAwaitReconnect() }
    }

    private func connect(using identity: USBModuleIdentity) {
        guard !isWorking else { return }
        isWorking = true
        note("发现 \(identity.label)（\(identity.hex)）")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.controller.connect()
                DispatchQueue.main.async {
                    AppLog.log("模块已连接（\(identity.label)）")
                    self.isConnected = true
                    self.isWorking = false
                    // 模块回来了，重启窗口到此结束：那句等待里没有报错，
                    // 窗口关掉也不该留下一句。
                    self.clearAwaitReconnect()
                    self.missedAttachScans = 0
                    self.controller.startPolling(interval: 1.0)
                    self.afterConnect()
                }
            } catch {
                // 接口被别人抓着的时候，传输层只会说「可能没有 USB 访问权限」，
                // 客户照着这句话永远修不好。这里换成能照着做的下一步。
                let message = Self.connectFailure(error, identity: identity)
                DispatchQueue.main.async {
                    AppLog.log("连接失败：\(message)")
                    self.isWorking = false
                    // 刚刚亲手让模块重启的那几秒里连不上，是计划内的事。
                    // 写成报错，客户会以为是自己弄坏的；而且这时候他照
                    // 「换个 USB 口试试」去做，也没有任何用。
                    if self.awaitingReconnect {
                        if !self.loggedReconnectWait {
                            self.loggedReconnectWait = true
                            self.note("模块重启中：等它重新挂上 USB，连上以后会自己继续读数")
                        }
                    } else {
                        self.lastError = message
                        self.note(message)
                    }
                }
            }
        }
    }

    /// `连接失败：<原因>`，几种客户真会遇到的情况换成能照着做的说法。
    nonisolated static func connectFailure(_ error: Error, identity: USBModuleIdentity) -> String {
        connectFailure(error, inventory: USBInventory.read(identity))
    }

    /// 同上，只是把「现场快照」交进来。
    ///
    /// 分出来这一层是为了能验：真机上想验一句报错，得先把模块插成一个特定的
    /// 占用样子（而且最要紧的那种——AT 口被另一个自己抓着——还必须真的再开
    /// 一个进程去抢）。这里让自检直接摆出那份快照，报错文案就变成可以钉住的
    /// 东西，而不是「下次遇到再说」。
    nonisolated static func connectFailure(_ error: Error, inventory: USBInventory?) -> String {
        guard let atError = error as? ATTransportError,
              case .noATInterface(let detail) = atError else {
            return "连接失败：\(error)"
        }
        if let inventory {
            // 只有「AT 接口自己」和「整台设备」的占用者才算数。
            //
            // 这里以前读的是 `inventory.holders.first`，而 `holders` 是设备级
            // 占用者加上**所有**接口的占用者。模块插在 Mac 上时，USB 网卡那两口
            // 归 AppleUSBECMControl / AppleUSBECMData、声卡归 AppleUSBAudioDevice
            // —— 于是这一句几乎永远把苹果自己的驱动当成嫌疑人，让客户去退一个
            // 根本不存在的程序。2026-09-25 在 `--nomodule` 的截图里抓到：AT 口
            // 明明是空的，报错却写着「模块正被 AppleUSBECHControl 占用」。
            // 注意不能写成 `atInterface?.owner ?? deviceOwner`：AT 接口在的
            // 时候 `??` 只看它那一格，署名是空的就直接算「没人占」，设备级
            // 那位占用者会被整个跳过。自检里那份「整台模块被 cusbat 抓走」
            // 的快照就是这么红的。
            let atOwner = inventory.atInterface?.owner ?? ""
            let holder = atOwner.isEmpty ? inventory.deviceOwner : atOwner
            if !holder.isEmpty {
                return "连接失败：模块正被 \(holder) 占用。先退出那个程序，再点这里重试。"
            }
            // 到了这里 AT 接口在 IORegistry 里没人署名，可它还是打不开 —— 这
            // 正是最常见的那一种，值得单独说一句。原因：本 App（和 dji4gctl）
            // 抢 AT 口走的是 `USBInterfaceOpen`，它**不写** `UsbExclusiveOwner`
            // 这个属性，所以「菜单栏上已经有一个 DJI4G 正抓着 AT 口」在
            // IORegistry 里完全看不见，只表现为打开失败。
            //
            // 传输层那句（「拔掉数据线等 5 秒再插回，仍不行就把程序退出重开」）
            // 本身是对的，只是不提这一种；而客户点的第二下多半就是这么来的：
            // 菜单栏已经有一个图标，他又点了一次。
            if inventory.atInterface != nil {
                return "连接失败：AT 口打不开，多半是已经有另一个 DJI4G 占着它。"
                    + "菜单栏上如果已经有一个 DJI4G 图标，先退出那一个，再点这里重试；"
                    + "只有一个图标的话，拔掉数据线等 5 秒再插回；"
                    + "还不行就把 App 退出重开。"
            }
        }
        // 设备枚举得到、接口描述读不到，意思是「这个进程没被放进 USB 名单」，
        // 不是线或口的问题。传输层那句把原因说对了，但没给下一步，客户照着
        // 它只能去拔插线 —— 而那正好是没用的动作。
        if detail.contains("USB 接口描述") || detail.contains("USB 访问权限") {
            return "连接失败：拿不到模块的 USB 权限。"
                + "关掉这个窗口，在「访达 → 应用程序」里双击 DJI4G.app 重开；"
                + "从终端或脚本里启动的会这样。"
        }
        return "连接失败：\(error)"
    }

    private func afterConnect() {
        // 这里**不**直接写 APN。此刻的 `network` 是上一轮留下的缓存，而模块
        // 刚上电那几秒 `+QNWINFO` 报的可能是上一次驻留的运营商 —— 2026-09-26
        // 真机实测：卡座空着，它照样回 `"FDD LTE","46011"`（中国电信）。照缓存
        // 写下去模块里就多一个 CTNET，而「客户手选的优先」会让自动那条路从此
        // 不再碰它：客人插一张移动卡，永远连不上，还得靠人按按钮。
        // 统一交给下面的 `refreshAll` —— 那里读的是这一秒的新值，而且要等
        // 模块真的在网（见 `writeCarrierAPNIfPossible`）。
        refreshAll()
        // 刚插上就查一遍。三十秒那条定时器够慢，客户插上线到打电话之间
        // 往往没有三十秒。
        checkVoicePathIfNeeded()
    }

    func disconnect() {
        controller.disconnect()
        isConnected = false
        transport = "未连接"
        attachedIdentity = nil
        messages = []
        // The module may be leaving mid-call, taking its audio function with it.
        // Handing the devices back explicitly beats waiting for CoreAudio to
        // notice the device is gone — and it covers the case where the customer
        // pressed 「切到模块」 by hand, which nothing else would undo.
        if voice.isRouted {
            // 同样是 CoreAudio 枚举，同样在主线程上 —— 走同一条队列。
            Self.voiceDeviceQueue.async { [weak self] in
                guard let self else { return }
                _ = self.controller.voice.deactivate()
                let status = self.controller.voice.refreshStatus()
                DispatchQueue.main.async { self.voice = status }
            }
        }
        call = CallInfo()
        lastCallState = .idle
        didAutoApplyAPN = false
        didRestoreHostMode = false
        // 体检结果跟着模块走：模块一走，那五个位一个都不能再信。留着的
        // 话，`checkVoicePathIfNeeded()` 会拿一条「上次是好的」的旧结论
        // 把插回来该做的修复整个跳掉 —— 正是这次要修的那个场景。
        if !voiceSetupPinned {
            voiceSetup = ModuleVoiceSetup.Status()
            voiceSetupVerifiedAt = nil
        }
        voiceRepairNotBefore = nil
        // 退避也要跟着模块一起走：下一次插上是一个全新的现场，头几次
        // 「还轮不到我」得按快的来（见 `runVoiceAutoRepair`）。
        voiceAdbWaitAttempts = 0
        voiceBailLogged = false
    }

    // MARK: - Events

    private func apply(_ event: ModemEvent) {
        switch event {
        case .transport(let text):
            transport = text
            note(text)
        case .transportLost(let text):
            AppLog.log("模块断开：\(text)")
            isConnected = false
            transport = "未连接"
            note("连接丢失：\(text)")
        case .identity(let value):
            identity = value
            // 面板只展示看得懂的字段；模块自己那句原始识别串留在日志里。
            // 客户机器上读不到型号时，远程看图猜不如直接看这一行。
            if !value.rawATI.isEmpty { AppLog.log("模块识别串：\(value.rawATI)") }
        case .sim(let value):
            // 客户把卡推进去的那一下，面板应该自己活过来。轮询线程只认卡
            // （几秒一轮），不读收件箱 —— 短信存在模块里，卡一认到往往已经
            // 有好几条历史短信。不在这里补读一次，客户看到的会是「SIM 就绪
            // ＋空收件箱」，直到他自己按一下刷新；那看起来像卡没认全。
            //
            // 开机时卡就在的那条路不走这里：`refreshAll` 本来就会读。
            let cardJustAppeared = sawSIMReport && value.ready && !sim.ready
            sim = value
            sawSIMReport = true
            if cardJustAppeared {
                note("检测到 SIM 卡，读一遍模块里的短信")
                // 顺手读一次网络：刚插上卡时模块还说不清是哪一家，而自动
                // 配 APN 等的就是这个答案。不补这一下，客户得自己点一次
                // AUTO 才能联网。
                // 传的是开关本身：这一轮试没试过（`didAutoApplyAPN`）由
                // `writeCarrierAPNIfPossible` 自己在里面看，因为换过卡的时候
                // 它要让路 —— 那个判据在那儿，别在门外先把它掐了。
                let autoAPN = autoApplyAPN
                run("读取短信") {
                    _ = try self.controller.refreshMessages()
                    _ = try self.controller.refreshNetwork()
                    self.writeCarrierAPNIfPossible(autoAPN)
                }
            }
        case .network(let value):
            network = value
            // 模块刚注册上来的这一拍，是自动配 APN 唯一还空着的窗口：插卡 /
            // 上电那一秒 `refreshAll` 看到的还是「没在网」，那时写不得（见
            // `writeCarrierAPNIfPossible`）。注册状态的变化由模块的 `+CEREG`
            // 自己送上来，正好接在这儿 —— 没有这一下，客户会停在「卡就绪、
            // APN 空着、上不了网」那一格上，而且他做什么都不会变。
            // 「模块里有 APN」不再是拦路的理由：换了卡的时候那个值正是要改
            // 的东西（见 `moduleAPNIsForeign`）。空着、或者主人换了，
            // 都值得把补写排上；排上之后写不写由 `writeCarrierAPNIfPossible`
            // 自己定。
            if value.dataRegistered, autoApplyAPN, controller.sim.ready,
               controller.data.status.apn.isEmpty || moduleAPNIsForeign {
                queueAPNWriteAfterRegistration()
            }
        case .signal(let value): signal = value
        case .messages(let value): messages = value
        case .incomingSMS(let value):
            let isNew = !messages.contains(where: {
                $0.storageIndex == value.storageIndex && $0.text == value.text
            })
            if isNew {
                messages.insert(value, at: 0)
                Notifier.shared.post(title: "新短信 · \(value.sender)", body: value.text)
            }
            note("新短信 \(value.sender.maskedAsPhoneNumber)")
        case .call(let value):
            guard !callPinned else { return }
            let previous = lastCallState
            lastCallState = value.state
            call = value
            // 活动列表里留一份通话流水。真机上「来电」只有 URC 那一条线，
            // 日志里一行都没有的时候，「模块没上报」和「上报了没人记」长得
            // 一模一样，排查只能靠猜。只在状态真的翻页时写 —— `refreshCalls()`
            // 每两秒把同一个状态重报一次，跟着写会把活动列表刷满。
            if value.state != previous {
                // 号码脱敏之后再进日志：报告是要发给别人的。
                let who = value.number.isEmpty ? "" : " · \(value.number.maskedAsPhoneNumber)"
                note("通话状态：\(previous.label) → \(value.state.label)\(who)")
                // 通话记录跟着同一条边界走：状态翻页才结算，`refreshCalls()`
                // 每两秒重报一次同一状态不会记出重复的行。
                if announcesAlerts {
                    // 结算出来的那一条顺手写进日志。客户说「通话记录不对」的
                    // 时候，报告里有没有这一行，能分清「没记」和「记错了」。
                    if let record = callHistory.observe(value) {
                        note("通话记录 +1：\(record.detailLabel())")
                    }
                    callRecords = callHistory.records
                }
            }
            if value.state == .ringing, previous != .ringing {
                announceRing()
            }
            // The number landed after the ring did, so the announcement that was
            // waiting on it can go out now.
            if value.state == .ringing, ringAnnouncement != nil, !value.number.isEmpty {
                deliverRingNotice()
            }
            if value.state != .ringing {
                cancelRingNotice()
            }
            if value.state == .waiting, previous != .waiting {
                // `+CCWA` carries the number on its own line, so this one has
                // nothing to wait for.
                let who = value.number.isEmpty ? "未知号码" : value.number
                Notifier.shared.post(title: "新来电 · \(who)",
                                     body: "有人在等你，接听会保持当前通话")
            }
            surfaceRing()
            followCallAudio(previous: previous)
        case .data(let value):
            data = value
            // 还没人按过开关：链路是通的，就把开关摆到「开」。App 重启后
            // 这一下是唯一能让面板和系统对上的地方。路由表那一问是主力 ——
            // 这款模块在 ECM 模式下 AT 那头不报 PDP 活跃，见
            // `refreshCountersThenSample` 里的同一段。
            if !dataSwitchTouched,
               value.isRoutable || value.pdpActive
                || NetProbe.defaultRouteIsOn(interface: value.interfaceName) {
                dataWanted = true
            }
            restoreHostModeIfNeeded()
        case .note(let text): note(text)
        case .ussd(let reply):
            // 空正文只在会话结束时出现（`+CUSD: 2`），这时候没什么可抄给
            // 客户的，写一句「结束了」就够。
            let text = reply.text.isEmpty ? "会话已结束" : reply.text
            ussdResult = text
            note("USSD：\(text)")
        }
    }

    // MARK: - 麦克风

    /// 没授权就问一次；已经问过的不再打扰（系统也只认第一次）。
    ///
    /// `announceGranted` 只管一件事：**授权成功**那句要不要写进活动列表。
    /// 开机那一次要写（客户刚点完框，得有一句回执）；通话前那次不写，
    /// 否则每通电话都多一条一模一样的「麦克风已授权」。
    /// 「没授权」是例外，两种情形都写 —— 那是真的要客户动手。
    func askForMicrophoneIfNeeded(announceGranted: Bool = true) {
        MicPermission.requestIfNeeded { [weak self] state in
            guard let self else { return }
            self.applyMicrophoneState(state, announceGranted: announceGranted)
        }
    }

    /// 只读一遍，不弹框。面板和通话窗口每次露面都刷一次，好让「去授权」
    /// 那一条在客户刚进系统设置把开关打开之后就自己消失。
    func refreshMicrophoneState() {
        applyMicrophoneState(MicPermission.state, announceGranted: false)
    }

    private func applyMicrophoneState(_ state: MicPermission.State, announceGranted: Bool) {
        guard !micStatePinned else { return }
        let denied = state == .denied
        // 这一条记在「刚变成没授权」那一下，不是每次刷新。
        // 面板和通话窗每次露面都会只读刷一遍，写在这儿就是几十条一样的。
        let becameDenied = micDenied != denied
        if becameDenied { micDenied = denied }
        let unasked = state == .undetermined
        if micUnasked != unasked { micUnasked = unasked }
        switch state {
        case .granted:
            if announceGranted { note("麦克风已授权，打电话时两个方向都有声音") }
        case .denied:
            if becameDenied {
                note("麦克风还没打开：现在打电话，对方听不到您说话。"
                     + "面板顶上点「去打开」，把开关打开就好")
            }
        case .undetermined:
            break
        }
    }

    /// 通话窗口那颗「去授权」。系统只肯弹一次框，被拒之后只剩这条路。
    func openMicrophoneSettings() {
        MicPermission.openSettings()
    }

    /// 麦克风这一格要不要占版面。授权是常态，常态不占地方。
    ///
    /// 2026-09-30：客户那边「接通以后半天没声音」，就是这一格缺着 ——
    /// 系统框弹过一次没人看见，之后既不报错也不再来，直到他哪次自己点开
    /// 系统设置。所以没授权（还没问过 / 被拒过）都算要占版面。
    var micNeedsAttention: Bool { micDenied || micUnasked }

    /// 界面上唯一那颗麦克风按钮的入口。
    ///
    /// 没问过的：再问一次，系统框这回会弹在客户眼前；
    /// 被拒过的：系统不再弹框（TCC 的规矩），只能把他送到系统设置那一页。
    func handleMicrophoneAction() {
        switch MicPermission.state {
        case .undetermined: askForMicrophoneIfNeeded(announceGranted: false)
        case .denied: MicPermission.openSettings()
        case .granted: break
        }
    }

    private func note(_ text: String) {
        // Most callers are already on the main thread (events, buttons), but
        // every `run` body executes on a background queue and several of them
        // note something mid-flight. Mutating an @Published from there is the
        // kind of race that shows up as a crash months later, so hop back.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.note(text) }
            return
        }
        activity.insert(text, at: 0)
        if activity.count > 60 { activity.removeLast(activity.count - 60) }
        // 活动列表和日志文件本来是两回事：`note` 只进前者，于是客户发回来的
        // app.log 里只剩「连接 / 断开 / 面板打开」那几行，来电、拨号、装语音这些
        // 真正要查的事一行都没有 —— 远程排查全凭猜。这里镜像一份进文件：面板上
        // 看得见的那句，日志里同样看得见。
        AppLog.log(text)
    }

    // MARK: - Actions

    func refreshAll() {
        // 模块还在重启的窗口里，AT 口还没有回来：这时候读它只会得到一条红色
        // 报错，而这条报错对客户没有任何意义 —— 连上以后 `afterConnect` 会
        // 自己读一遍，所以这里安静地让路。
        if awaitingReconnect && !isConnected { return }
        // A read that arrives during a write waits for it instead of being
        // refused; see `readPending`. `ensureHostService` below still runs now,
        // because the pending link is the Mac's half of the job and does not
        // wait on the AT session.
        guard !isWorking else {
            readPending = true
            ensureHostService()
            return
        }
        // 模块压根不在场上（还没插上、或者 AT 口被别的程序占着）：这一趟读
        // 同样只会得到一条「通道已关闭」。上面那条已经有理由，这一条以前
        // 没有 —— 于是只要模块没插，面板底下就常年挂着一条红字，而顶上
        // 明明写着「模块未连接 · 插到 Mac 的 USB 口」。客户读到的第二句
        // 既不是他造成的，也没有下一步可做，只是让一扇等模块的窗口看起来
        // 像坏了。宿主机那一半照旧跑：它不需要模块在场。
        guard isConnected else {
            ensureHostService()
            guardDataRoute()
            return
        }
        let autoAPN = autoApplyAPN
        run("刷新状态") {
            _ = try self.controller.refreshSIM()
            _ = try self.controller.refreshNetwork()
            _ = try self.controller.refreshSignal()
            _ = self.controller.refreshData()
            _ = try self.controller.refreshCalls()
            if self.sim.ready { _ = try self.controller.refreshMessages() }
            self.refreshVoice()
            self.writeCarrierAPNIfPossible(autoAPN)
        }
        // Outside `run` so a pending link still completes when the modem half
        // of the refresh failed for an unrelated reason.
        ensureHostService()
        guardDataRoute()
    }

    /// `carrier` nil lets the module say who the card belongs to. The operator
    /// buttons in 模块设置 pass one, because a card that has not registered yet
    /// (or is not in the slot yet) cannot be detected — and that is exactly when
    /// someone is trying to make 4G work.
    func applyCarrierAPN(force: Bool = true, carrier: Carrier? = nil) {
        let label: String
        if let carrier {
            label = "设置\(carrier.name)上网参数"
        } else {
            label = force ? "配置运营商" : "自动配置运营商"
        }
        run(label) {
            let apn = try self.controller.applyCarrierAPN(force: force, carrier: carrier)
            // 客户自己选的这一下就把主人的名字写上：这才叫「他选的」。不写
            // 的话，下一次自动路只看得到「模块里有个不是这张卡的 APN」，会
            // 把他刚按下去的那一家当场改掉。卡还没插进来时记成占位的那一笔。
            self.rememberAPNOwner(manual: true)
            self.note(carrier.map { "接入点 = \(apn)（\($0.name)）" } ?? "接入点 = \(apn)")
            _ = self.controller.refreshData()
        }
    }

    /// 卡插上、模块报出运营商之后，自动把 APN 写进模块 —— 客户不用自己点
    /// AUTO，打开 4G 就能联网。
    ///
    /// 四条自我约束：客户关掉了这个开关就不动；卡不在、或者模块还没在网就
    /// 不动；模块里本来就有 APN 就不动（客户手选的那一家永远优先）；一次
    /// 会话只试一次，失败留给按钮和体检报告去说，这里不反复刷同样的错。
    ///
    /// 第二条是 2026-09-26 补的：卡在卡座里 ≠ 模块认得这张卡。刚插卡 / 刚上
    /// 电的那几秒，`+QNWINFO` 报的仍是上一次驻留的运营商（真机上把卡拔了它
    /// 也照样回 `46011` 中国电信）。照它写进 CTNET，模块里就有 APN 了，而第
    /// 三条会让这条自动路从此再不碰它 —— 客人插一张移动卡就永远连不上，只
    /// 能靠人按按钮。所以这里**不置** `didAutoApplyAPN`：没在网就等下一轮刷新
    /// 重来，注册上空口一开就写。
    ///
    /// 现在这张卡的编号。ICCID 读不到就退回 IMSI，两个都读不到就交白卷 ——
    /// 交白卷时下面的判据一律当作「认不出来」，宁可不动模块里的值，也不要
    /// 在证据不足的时候替客户改。
    private var currentSIMKey: String {
        let iccid = controller.sim.iccid.trimmingCharacters(in: .whitespacesAndNewlines)
        if !iccid.isEmpty { return iccid }
        return controller.sim.imsi.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 模块里那个 APN 是不是**别的卡**的 —— 是就该改写。
    ///
    /// 三种「是」：记着主人而主人不是这张卡（客人换了卡）；没记过主人、也没
    /// 人在这台机器上手选过，而模块里那个值和现在认到的运营商对不上（上一手
    /// 留下的）；以及第一种在换回来时的对称情况。
    ///
    /// 三种「不是」：主人就是这张卡（客户自己的选择，一个字不动）；有人在这
    /// 台机器上按过运营商按钮（等他插卡，别抢）；运营商认不出来（没证据，不
    /// 改）。
    ///
    /// 中间那条是交付当天补的安全网：客人拿到的模块里可能躺着上一张卡的
    /// APN，而他这台电脑从没跑过这个程序、什么都不记得。少了这一条，那条路
    /// 会一路「不敢改」下去 —— 客人插上卡打不开任何网页，面板上还一个字都
    /// 不说。这正是这台开发机上发生过的现场（模块里留着 CTNET，插一张移动
    /// 卡进去，从此上不了网）。
    private var moduleAPNIsForeign: Bool {
        let moduleAPN = controller.data.status.apn
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !moduleAPN.isEmpty else { return false }
        let current = currentSIMKey
        guard !current.isEmpty else { return false }

        let owner = (UserDefaults.standard.string(forKey: AppModel.apnOwnerSIMKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !owner.isEmpty { return owner != current }
        // 有人在卡还没插进来的时候先按了运营商按钮：那个选择是给下一张卡的，
        // 不能当成「上一手留下的」。
        if UserDefaults.standard.bool(forKey: AppModel.apnManualKey) { return false }

        let carrier = controller.network.carrier
        guard !carrier.apn.isEmpty else { return false }
        return moduleAPN.caseInsensitiveCompare(carrier.apn) != .orderedSame
    }

    /// 把「模块里这个 APN 是给哪张卡写的」记下来。
    ///
    /// 读不出卡号的时候不记主人（记一个空串会让下一次判据拿空串去比，凭空多
    /// 出一次改写），但**手选**那一笔要记成占位的「有人选过」—— 客户可以先
    /// 按运营商按钮再插卡，那个顺序不该让他按下去的选择被自动路改掉。
    private func rememberAPNOwner(manual: Bool = false) {
        let current = currentSIMKey
        guard !current.isEmpty else {
            if manual { UserDefaults.standard.set(true, forKey: AppModel.apnManualKey) }
            return
        }
        UserDefaults.standard.set(current, forKey: AppModel.apnOwnerSIMKey)
        UserDefaults.standard.removeObject(forKey: AppModel.apnManualKey)
    }

    /// 只能在别的 `run` 的 body 里调用：那时候 AT 会话正好归它用。另起一次
    /// `run` 会被「上一步操作还没结束」挡回来，客户看到的就是一条看不懂的
    /// 红字。
    ///
    /// 2026-09-26 第二改：以前这里是「模块里有 APN 就永远不碰」。那一条把
    /// **换卡**也一起挡住了 —— 客人把电信卡拔出来插一张移动卡，模块里还是
    /// CTNET，那张新卡从此连不上网，面板上还不说话。现在的规矩按卡分：
    /// 同一个 ICCID 上照旧一个字都不动（客户手选的那一家保得住），主人换了
    /// 才改写，写完把新主人记上。主人一记上，`moduleAPNIsForeign`
    /// 自己就变回 false，所以这条路不会反复写。
    private func writeCarrierAPNIfPossible(_ enabled: Bool) {
        guard enabled else { return }
        guard controller.sim.ready else { return }
        guard controller.network.dataRegistered else { return }
        let swapped = moduleAPNIsForeign
        if !controller.data.status.apn.isEmpty, !swapped {
            // 就是这张卡自己的（或者来路不明）：留着，这一轮不再试。
            rememberAPNOwner()
            didAutoApplyAPN = true
            return
        }
        // 没换卡的时候，这一轮试过就不再试（失败留给按钮和体检报告去说）。
        guard swapped || !didAutoApplyAPN else { return }
        let carrier = controller.network.carrier
        guard !carrier.apn.isEmpty else { return }
        didAutoApplyAPN = true
        if swapped {
            note("换了张卡，接入点改成 \(carrier.apn)（\(carrier.name)）")
        }
        do {
            _ = try controller.applyCarrierAPN(force: false)
            rememberAPNOwner()
            // 面板上「接入点 待写入」那一行要当场跟着变。不回读这一下，
            // 客户插上卡看到的第一眼仍是旧的空值，会以为没配上。
            _ = controller.refreshData()
        } catch {
            note("自动配置没成功：\(error)")
        }
    }

    /// 模块注册上来之后补写一次 APN。
    ///
    /// 为什么需要它：`refreshAll` 只在连上模块、插卡那一秒、和客户按 QUERY
    /// 时跑，而模块注册是几秒之后才发生的事 —— 那一刻没有人会回头再问一次。
    /// 真机上的触发点是 `+CEREG: 0,1` 这条 URC，正是这里接的那一下。
    ///
    /// 隔一拍（1.5 秒）再起 `run`：`.network` 常常是在刷新那条 `run` 的 body
    /// 里发出来的，当场再起一条会被「上一步操作还没结束」挡回去 —— 而那条
    /// 被挡下的正是注册后的第一次机会。
    private func queueAPNWriteAfterRegistration() {
        guard !apnWriteQueued else { return }
        apnWriteQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.apnWriteQueued = false
            guard self.autoApplyAPN, self.controller.sim.ready else { return }
            let autoAPN = self.autoApplyAPN
            self.run("配置接入点") {
                _ = self.controller.refreshData()
                self.writeCarrierAPNIfPossible(autoAPN)
            }
        }
    }

    /// The bundle to register with launchd, derived from the running binary.
    /// Nil for a bare `.build/…` executable, which is what keeps a development
    /// run from pointing the login item at a scratch directory.
    private var loginItemApp: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        return LoginItem.appBundle(containing: executable)
    }

    /// Re-reads the LaunchAgent, so a change the user makes in System Settings
    /// shows up here instead of the panel quietly disagreeing with the system.
    func refreshStartAtLogin() {
        guard simulator == nil else { return }
        startAtLogin = LoginItem.status().installed
    }

    /// Deliberately not routed through `run()`: that helper reports failures in
    /// the activity list, and this one is a checkbox the user is watching. It
    /// has to snap back to the real state when the write fails, or the panel
    /// would promise a safety net that is not there and the next reboot would
    /// silently drop every call.
    func setStartAtLogin(_ on: Bool) {
        guard simulator == nil else {
            startAtLogin = on
            return
        }
        guard let app = loginItemApp else {
            startAtLogin = LoginItem.status().installed
            lastError = "找不到 App 本体，改不了开机自启。"
            note("开机自启：找不到 App 本体")
            return
        }
        do {
            if on { try LoginItem.install(app: app) } else { try LoginItem.remove() }
            startAtLogin = LoginItem.status().installed
            note(startAtLogin ? "开机自启：已开启，重启后自动运行" : "开机自启：已关闭")
        } catch {
            startAtLogin = LoginItem.status().installed
            lastError = "开机自启设置失败：\(error.localizedDescription)"
            note("开机自启设置失败：\(error.localizedDescription)")
        }
    }

    /// The 4G pill. Three things have to line up before traffic actually moves,
    /// and they live in three different places, so all of them happen here:
    ///
    ///   1. the module has to be in ECM mode      (modem, AT+QCFG="usbnet")
    ///   2. a PDP context has to be up            (modem, AT+QIACT)
    ///   3. macOS has to route over the interface (host, networksetup)
    ///
    /// Step 3 is the one that surprises people: with the service off, the panel
    /// shows a healthy interface and a real IP while every packet still leaves
    /// over Wi-Fi. Switching the service on is what changes that, and it is
    /// also what hands the default route back to Wi-Fi when 4G is switched off.
    func setDataEnabled(_ enabled: Bool) {
        // 模块不在（还没插上、正在重启、或者 AT 口被别的程序占着）：开关动
        // 不了。这里不能再往下走 —— 底下第一句 `setUSBnetMode` 会失败在
        // 「通道已关闭」上，客户看到一句既不是他造成的、也修不了的红字。
        // 面板那头这颗药丸这时候本来就是灰的，正常人按不到这里；这条是给
        // 排队那一路留的底：排在后面的那一按落地时，模块可能已经不在了。
        guard isConnected else {
            note("模块没连上，4G 数据开关现在动不了")
            return
        }
        // 开关先跟着手指走，不等活儿干完：切 ECM 会让模块重启，这一趟要好
        // 几秒，等它回来才翻标签，客户会以为没点上，再点一次只会得到「上一步
        // 操作还没结束」。失败再翻回原位 —— 最常见的失败是卡座空着，
        // `AT+QIACT` 直接报错，那一版必须回到 `4G OFF`。
        let accepted = run(enabled ? "开启 4G 数据" : "关闭 4G 数据",
                           completion: { [weak self] ok in
                               guard !ok, let self else { return }
                               // 没成，开关退回**链路事实**，不是退回按之前那个
                               // 值：中间这些毫秒里它可能已经变了（客人在系统
                               // 设置里动过、模块重新枚举过），退回旧值等于拿
                               // 一个刚被否掉的事实再盖一次，开关就此和系统分家。
                               _ = self.controller.refreshData()
                               let fresh = self.controller.data.status
                               self.data = fresh
                               self.dataWanted = fresh.isRoutable || fresh.pdpActive
                                   || NetProbe.defaultRouteIsOn(interface: fresh.interfaceName)
                               if self.dataWanted { self.ensureHostService() }
                           }) {
            if enabled {
                // A PDP context cannot come up without an APN, and the module
                // ships with none. This is best effort: a card that is not in
                // the slot yet must still leave the rest of the switch working.
                // 没在网时同样别写：`+QNWINFO` 那几秒报的可能是上一次驻留的
                // 运营商，写错一次就再也改不回来（同 `writeCarrierAPNIfPossible`）。
                // 「换了卡」和「没写过」一样要放行：模块里留着上一张卡的
                // APN 的时候，这个开关按下去就是客人唯一的自救动作。
                let needsAPN = self.controller.data.status.apn.isEmpty
                    || self.moduleAPNIsForeign
                if needsAPN, self.controller.network.dataRegistered {
                    if (try? self.controller.applyCarrierAPN(force: false)) != nil {
                        self.rememberAPNOwner()
                        self.note("上网参数已按运营商设好")
                    }
                }
                // Switching to ECM reboots the module, so this is also the
                // moment the interface disappears. Everything below is asked
                // for now and retried by the poll until macOS has caught up.
                //
                // 这一条不是每块模块都有（华为就没有）。没有的时候网卡怎么
                // 出来由固件决定，改了反而错；直接往下走，「能不能上网」交给
                // 接口那条实测去判，而不是先在这里报一个客户修不了的错。
                if self.controller.data.canSwitchUSBnetMode {
                    _ = try self.controller.data.setUSBnetMode(.ecm)
                }
                _ = try self.controller.data.activatePDP()
                self.wantsDataLink = true
                _ = self.controller.refreshData()
                self.ensureHostService()
            } else {
                self.wantsDataLink = false
                // Hand the default route back to Wi-Fi *before* tearing the PDP
                // context down; the other order briefly leaves the machine with
                // no working route at all.
                if let service = try? self.controller.data.setHostService(enabled: false) {
                    self.note("已停用「\(service.name)」，默认路由回到 Wi-Fi")
                }
                try self.controller.data.deactivatePDP()
            }
            _ = self.controller.refreshData()
        }
        // 没被接下（AT 会话正忙）：记下这一笔，等手上那一步结束再补，同时
        // 把开关的位置立刻交给手指 —— 客户按下去就指望它动，红字留给真正
        // 的失败原因。真失败时 completion 会把它翻回来。
        guard accepted else {
            // `run` 那条「上一步操作还没结束」是为按钮写的：它挡下的是没被
            // 收下的活。这一按我们收下了，只是排在后面，不能让面板为一件
            // 正在做的事报红。
            lastError = nil
            pendingDataSwitch = enabled
            dataSwitchTouched = true
            dataSwitchTouchedAt = Date()
            dataWanted = enabled
            note(enabled ? "4G 数据排在上一步后面开启" : "4G 数据排在上一步后面关闭")
            return
        }
        dataSwitchTouched = true
        dataSwitchTouchedAt = Date()
        dataWanted = enabled
    }

    /// Finishes turning 4G on once macOS is ready for it.
    ///
    /// Enabling ECM makes the module re-enumerate, and macOS then needs a
    /// moment to attach the driver, create the interface and create a network
    /// service for it. At the instant the user presses 4G there is nothing to
    /// switch on yet, so the request is remembered and this runs again from
    /// every refresh until it lands. Without that, the first press would always
    /// fail and the user would have to press a second time several seconds
    /// later — for a step they cannot see the state of.
    /// 那笔「还欠着一条链路」的账，现在能不能还上？
    ///
    /// 三个条件缺一不可，而且**缺了哪一个都不许把账销掉** —— 这正是
    /// 2026-09-26 那次真机事故的教训：模块拔插回来，「4G 又能出网了」是在
    /// `en59` 还没被 macOS 发布出来的那一瞬说的，`ensureHostService()` 原地
    /// 返回，而它当时只在完整刷新里被叫一次，于是这笔账一直挂着没人再问。
    /// 停用的网络服务让 macOS 不肯拉起网卡，网卡不出现又让这一句永远返回 ——
    /// 两边互相等到天荒地老，客人看到的只是「4G 开着，但没网」。
    ///
    /// - `wantsDataLink`：客人确实想要这条链路。为假时（客人自己按了 4G OFF、
    ///   或者保命逻辑刚把路由还给 Wi-Fi）接口再出现也不许自己打开。
    /// - `hasInterface`：macOS 已经把网卡发布出来。没有网卡就没有服务可开，
    ///   等下一拍 —— 账留着。
    /// - `serviceEnabled == false`：没开才去开。这一条同时是限流阀：为假就
    ///   立刻返回，一次 `networksetup` 进程都不会拉。
    ///
    /// 抽成纯函数，是为了自检能直接喂那几组输入 —— 包括真机上翻过车的
    /// 「接口还没出现」那一组，见 `Render.swift`。
    static func pendingLinkCanLand(wantsDataLink: Bool,
                                   hasInterface: Bool,
                                   serviceEnabled: Bool) -> Bool {
        wantsDataLink && hasInterface && !serviceEnabled
    }

    ///
    /// - `force`：跳过「服务开着没有」那道缓存闸。只给 `guardDataRoute()` 里那条
    ///   自动收回用 —— 它的起因就是这份缓存旧了（外面把服务关掉，App 还记着
    ///   开着），不跳过的话那一跳会被挡在门口，什么都没发生。`setHostService`
    ///   本身是幂等的：服务真开着时多跑一条 `networksetup` 只是白跑一跳，而
    ///   调用方自带一分钟的重试节拍，不靠这里限流。
    private func ensureHostService(force: Bool = false) {
        guard Self.pendingLinkCanLand(wantsDataLink: wantsDataLink,
                                      hasInterface: data.hasInterface,
                                      serviceEnabled: force ? false : data.serviceEnabled) else { return }
        // Interface is here but macOS has not published the service yet; the
        // next refresh will have it.
        guard !data.serviceName.isEmpty else { return }
        // 模块这头还没在网（没插卡 / 还没注册）时**不许**
        // 打开 macOS 那条网络服务：打开它就把整台 Mac 的默认路由压到模块上，
        // 而 en59 是 ECM，模块的 DHCP 永远给得出 IP 和网关 —— 包却出不去。
        // Wi-Fi 明明连着，客人却整机断网。等模块真在网了，下一次刷新自然会
        // 走到这里。2026-09-26 真机事故的另一半，见 `guardDataRoute()`。
        //
        // 等的时候要出声：这一段每两三秒就被调一次，一句话不说的话，客户按了
        // 开关、胶囊停在「空心绿环」那一格转，界面上没有任何东西告诉他还在
        // 等什么 —— 看起来就是按不动。原因只在换的时候说一遍，不刷屏。
        if let waitReason = Self.dataLinkTrouble(connected: isConnected,
                                                 simReady: sim.ready,
                                                 registered: network.dataRegistered) {
            noteDataWaitOnce(waitReason)
            return
        }
        dataWaitNote = nil

        // 2026-09-27：这一句要拉一个 `networksetup` 进程，真机实测 3–4 秒才
        // 回来。它以前就在主线程上原地等 —— 客户看到的是「模块刚连上，面板
        // 卡住几秒」，日志里那条「主线程卡住：4 秒没有响应」记的就是它。
        // 现在进程放后台，回到主线程只剩三件瞬时的事。
        guard !hostServiceInFlight else { return }
        hostServiceInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // 只把「服务叫什么名」带回主线程：`Result` 里的错误类型跨队列
            // 传是个没必要的麻烦，空名就是失败。
            let serviceName = try? self.controller.data.setHostService(enabled: true).name
            // 接着把这份链路状态读回面板。`data` 在 AppModel 这边是一份拷贝，
            // 而开服务这一下改的是 `DataService` 里的原件 —— 不读回来的话，
            // 面板会一直停在「4G 开着但没网」，直到下一次完整刷新（最长三十秒）。
            // 这一步也必须留在后台：`refreshStatus()` 里那次 `networksetup`
            // 正是我们要躲开的东西。
            let fresh = self.controller.data.refreshStatus()
            DispatchQueue.main.async {
                self.hostServiceInFlight = false
                self.data = fresh
                guard let serviceName else {
                    self.wantsDataLink = false
                    self.note("无法自动启用网络服务，请在终端执行：\n"
                              + HostNetwork.manualCommand(self.data.serviceName, true))
                    return
                }
                self.wantsDataLink = false
                // 刚把整台电脑的默认路由交出去，立刻验一次：这条链路要是不通，
                // 客人此刻已经没网了，早一秒看见就早一秒还回去。把上一次的结果
                // 清掉，让那两秒一次的巡检马上排一次实测，而不是再等一个 6 秒。
                // 见 `guardDataRoute()` 与 `NetProbe`。2026-09-26 补。
                self.netProbeCheckedAt = nil
                self.netProbeFailures = 0
                self.note("已启用 macOS 网络服务「\(serviceName)」，流量现在走模块")
                // 这 3 秒里客人可能刚按了 4G OFF，而这一下是后落地的。开关的
                // 位置归他，不归这个迟到的进程 —— 把服务关回去。
                if !self.dataWanted { self.undoLateHostServiceEnable() }
            }
        }
    }

    /// 迟到的「开服务」落地时，客人其实已经按下了 4G OFF —— 安静地关回去。
    ///
    /// 不走 `run`：客人那一次关闭本身就在 `run` 里跑着，而 `run` 一次只收一件
    /// 事，从这儿再叫一次只会被它当成「上一步还没结束」拒掉，界面上白白多出
    /// 一条红字。这里补的只是 `networksetup` 那一下 —— 状态和那句话都由客人
    /// 那一步自己负责写，这一下不抢。
    private func undoLateHostServiceEnable() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = try? self?.controller.data.setHostService(enabled: false)
        }
    }

    /// 按了 4G 却在等模块 —— 原因只说一遍。
    ///
    /// 见 `ensureHostService()` 里那一段：那两秒一次的巡检会让同一句话反复
    /// 到嘴边，而客户真正需要的是「知道在等什么」，不是「知道得有多频繁」。
    private func noteDataWaitOnce(_ reason: String) {
        guard dataWaitNote != reason else { return }
        dataWaitNote = reason
        note("4G 先等一等：\(reason)")
    }

    /// 模块这头还能不能把包送出去？返回一句人话原因，nil = 没问题。
    ///
    /// 纯函数：自检直接喂几组输入就能验，不用等观察窗，也不用真的动
    /// `networksetup`。
    static func dataLinkTrouble(connected: Bool, simReady: Bool,
                                registered: Bool) -> String? {
        if !connected { return "模块没连上" }
        if !simReady { return "卡座里没有可用的卡" }
        if !registered { return "模块还没注册上网络" }
        // 这里只回答「模块这头准备好没有」，不回答「这条路通不通」——
        // 后者交给 `NetProbe` 实测（见 `guardDataRoute()`）。
        //
        // 2026-09-26 真机实测把 PDP 那条判据删掉了，两个原因：
        //   · `AT+QIACT?` 读回来是空的，而 en59 上的流量一直在跑。PDP 是否
        //     报活和这条路能不能出网，在真机上不是一回事，拿它当判据会把
        //     一条好好的链路判死。
        //   · 上下文是「主机把网卡拉起来」之后模块才激活的，而打开网卡又要
        //     先过这个判据 —— 先有鸡还是先有蛋。按 4G 会永远停在「等一等」，
        //     掉线之后也不会自己交回路由。
        // 卡欠费 / APN 选错 / 上游断这类「模块说好、包出不去」的故障，
        // 由实测在二十秒内认出来并交回路由。
        return nil
    }

    /// 巡检：模块这头出不了网的时候，把 macOS 的默认路由还给 Wi-Fi。
    ///
    /// 为什么非有这一段不可（2026-09-26 真机事故）：4G 胶囊做的事是把
    /// macOS 里模块那条网络服务打开，而打开之后整台 Mac 的默认路由就压在
    /// 模块上 —— en59 是 ECM，模块那边的 DHCP 永远给得出 IP 和网关，
    /// **不管这条链路后面有没有数据**。卡一拔，包全塞进死胡同：Wi-Fi 明明
    /// 连着，整机却上不了网；重启也不好，因为网络服务是开机就开着的。
    /// 当时插回卡网络才回来。客户那边一样会遇上（拔卡换卡、卡欠费、模块
    /// 掉网、注册被拒）。
    ///
    /// 所以它和 `ensureHostService()` 是一对：那边「能上网了就把路由交给
    /// 模块」，这边「上不了了就还给 Wi-Fi」。两条都只看模块的真实状态，
    /// 客户不需要知道 macOS 里还有这么一条服务。
    ///
    /// **总闸问的是路由表，不是缓存**（2026-09-26 交付当天补，真机实测）。
    /// 这里以前写的是 `data.serviceEnabled` —— 一个只有完整刷新才会更新的标记，
    /// 而完整刷新只在打开面板 / 手动刷新 / 切模式时才跑。结果：只要路由是从
    /// 别的路上到模块的（在终端里开的服务、macOS 在 USB 重新枚举之后自己恢复
    /// 的、App 刚重启还没刷过），这个标记还是 `false`，保命逻辑就以为「这条 4G
    /// 不关我的事」，**两眼一闭**。真机实测：从外部把服务打开再让模块掉网，
    /// 整台电脑断了**九十秒**，它一次都没动 —— 而同一个故障从面板那条路进来时
    /// 只花了八秒。八秒的观察窗没错，错的是「有没有人去看」。
    ///
    /// 「默认路由现在压在模块那块网卡上」才是真正要救的东西，而且路由表当场
    /// 就能回答，不拉进程、不发 AT、不会过期。`data.serviceEnabled` 留着当兜底：
    /// 接口名还没读到的时候（App 刚起来、模块刚插上），至少还认得出刚打开的服务。
    private func guardDataRoute() {
        // 路由表现在压在谁身上。这一问是免费的（进程都不拉），而且**永远新鲜** ——
        // 这是它和 `data.serviceEnabled` 的区别：那个缓存值最长能旧到下一次完整
        // 刷新（面板不开就一直不刷）。2026-09-27 真机实测：从外面把服务关掉，
        // 缓存还写着「开着」，下面那条自动收回于是瞎了三十秒。
        let routeOnModule = NetProbe.defaultRouteIsOn(interface: data.interfaceName)
        let holdsDefaultRoute = Self.holdsDefaultRoute(interfaceName: data.interfaceName,
                                                       serviceEnabled: data.serviceEnabled)
        // 这条路真跑起来过，才有「被关掉之后收回来」这回事；路由回到模块上，
        // 上一次替他收过的那笔账就结了。两条都只写内存，不进日志。
        if holdsDefaultRoute { hostLinkWasUp = true }
        if routeOnModule { hostRestoreLastTry = nil }
        startNetProbeIfNeeded(routeOnModule: holdsDefaultRoute)
        // 告诉轮询线程：现在要把「模块还在不在网」问勤一点。
        //
        // 2026-09-26 交付当天实测：模块一掉网，客人的整台电脑就没网，而当时
        // 从掉网到默认路由交回 Wi-Fi 花了三十一秒 —— 其中二十四秒都花在
        // 「多久才看见」上，因为看注册状态那条路是三十秒一次的整体刷新，
        // 而它正好被「模块断电后重装通话语音」（二十多秒）堵住。观察窗那八秒
        // 本身是对的，错的是看见得太晚。现在单开一条只问注册的便宜路，
        // 并且只在这两个窗口问快档：默认路由押在模块上，或者刚把路由撤回来
        // 正等着还给模块。别的时候 Wi-Fi 走得好好的，问它没意义。
        controller.watchingRegistration = holdsDefaultRoute || routeRolledBackForSafety

        let moduleTrouble = Self.dataLinkTrouble(connected: isConnected,
                                                 simReady: sim.ready,
                                                 registered: network.dataRegistered)
        // 模块说自己好，不等于这条路真能把包送出去：卡欠费、APN 选错、运营商
        // 那边没放行，模块都会一直报「已注册、PDP 也活着」，而客户的整台
        // 电脑已经没有网了。只有真发一个包才知道，见 `NetProbe`。
        let probeTrouble = Self.probeTrouble(
            routeOnModule: holdsDefaultRoute,
            failures: netProbeFailures,
            hasOtherUplink: NetProbe.hasOtherUplink(excluding: data.interfaceName)
        ) ? "这条 4G 链路实测出不了网" : nil
        let trouble = moduleTrouble ?? probeTrouble

        // 这一段：路由已经还给 Wi-Fi 了，等链路恢复就自己交回去 ——
        // 客人拔卡再插卡不用再按一次 4G。
        if routeRolledBackForSafety {
            if holdsDefaultRoute {
                // 那次停用没落地（权限被拒 / 没排上）：过一会儿再试，
                // 不能让客人卡在断网里等一个不会来的重试。
                retryRouteRollback(trouble: trouble)
                return
            }
            guard trouble == nil, sim.ready, network.dataRegistered else { return }
            // 实测驱动的交回要等冷却，见 `routeRollbackNotBefore`。
            if let notBefore = routeRollbackNotBefore, Date() < notBefore { return }
            routeRollbackNotBefore = nil
            routeRolledBackForSafety = false
            routeRollbackTries = 0
            routeRollbackLastTry = nil
            dataWanted = true
            dataSwitchTouched = true
            wantsDataLink = true
            note("4G 又能出网了，默认路由交回模块")
            ensureHostService()
            return
        }

        // 客人要这条链路，模块这头也正常，可 macOS 那条网络服务是关着的 ——
        // 它是被**这条路之外**的东西关掉的：系统设置里手动关掉、别的工具关掉、
        // 模块重新枚举之后 macOS 没把状态带过来。不主动收回来的话，客人看到的
        // 就是「4G 开着，却一直走 Wi-Fi」，而面板上没有一个字能解释。
        //
        // 2026-09-27 真机实测：从外面把服务关掉，三十秒过去 App 一动不动，
        // 默认路由留在 Wi-Fi 上。三个前提见 `shouldRestoreHostLink`。
        if Self.shouldRestoreHostLink(dataWanted: dataWanted,
                                      linkWasUp: hostLinkWasUp,
                                      trouble: trouble,
                                      hasInterface: data.hasInterface,
                                      routeOnModule: routeOnModule) {
            // 节拍：这一段每两三秒被叫一次，而底下那一跳要拉进程、还要读一遍
            // 模块。「收了也收不回来」的机器不能靠这个循环刷屏，见常量。
            if let last = hostRestoreLastTry,
               Date().timeIntervalSince(last) < Self.hostRestoreRetrySeconds { return }
            // 这一段的第一跳才说话：后面每一跳都在做同一件事，说第二遍只是把
            // 上面那句挤走。
            if hostRestoreLastTry == nil {
                // 屏幕黑着就只写日志、不进活动列表。macOS 夜里为了维护会反复
                // 暗唤醒（`pmset -g log` 里那一串 DarkWake 是 USB 和网络触发
                // 的），每唤醒一次 USB 就重新枚举一遍模块，这条服务跟着被关
                // 一次 —— 2026-09-30 那一夜九次。客人早上打开面板看到的是一屏
                // 「网络服务被关掉了」，像坏了一样，其实一次都没影响他用。
                if Self.displayIsAsleep() {
                    AppLog.log("4G 那条网络服务被关掉了，正在自动开回来（屏幕黑着，不打扰）")
                } else {
                    note("4G 那条网络服务被关掉了，正在自动开回来")
                }
            }
            hostRestoreLastTry = Date()
            // `force`：App 手里那个「服务开着没有」是旧读数（这一段的起因就是
            // 它旧），别让它把这一跳挡在门口。见 `ensureHostService`。
            wantsDataLink = true
            dataLinkTroubleSince = nil
            ensureHostService(force: true)
            return
        }

        // 默认路由不在模块手上，出不了网也跟路由无关，Wi-Fi 该走还走。
        guard let trouble, holdsDefaultRoute else {
            dataLinkTroubleSince = nil
            return
        }
        guard let since = dataLinkTroubleSince else {
            dataLinkTroubleSince = Date()
            return
        }
        guard Date().timeIntervalSince(since) >= Self.routeGraceSeconds else { return }

        dataLinkTroubleSince = nil
        routeRolledBackForSafety = true
        routeRollbackTries = 1
        routeRollbackLastTry = Date()
        if probeTrouble != nil {
            // 实测不通这一类会来回摆：服务一关，网卡就没有 IPv4 了，实测自己
            // 就断了，而模块那边一直说自己好的 —— 不设冷却就是「关→开→关」
            // 的死循环。每多一次退避翻倍，见 `probeCooldown`。
            probeRollbackCount += 1
            routeRollbackNotBefore = Date().addingTimeInterval(Self.probeCooldown(probeRollbackCount))
        } else {
            // 模块状态那一类是真变了（拔卡 / 掉网 / 没注册），链路一通就该
            // 立刻交回去，冷却没有意义。
            probeRollbackCount = 0
            routeRollbackNotBefore = nil
        }
        netProbeFailures = 0
        netProbeReachable = nil
        note("4G 出不了网（\(trouble)），先把默认路由还给 Wi-Fi，免得整台电脑跟着上不了网")
        setHostService(false)
    }

    /// 屏幕是不是黑着。
    ///
    /// 只给「自愈」那几条用。它们的成因在系统那一侧（睡眠 / 暗唤醒 / USB
    /// 重新枚举），客户人不在、也没受影响，唯一的结果是下次打开面板看到一屏
    /// 吓人的记录。屏幕亮着时照旧说出来 —— 那时候是真有人在动。
    private static func displayIsAsleep() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// 「4G 开着，但 macOS 那条网络服务是关着的」—— 该不该自己收回来。
    ///
    /// 抽成纯函数给自检喂：这五个输入每一个都能单独把动作挡下来，而挡错的
    /// 代价是不对称的：该收回时不收回，客人看到的是「4G 开着、却一直走 Wi-Fi」，
    /// 面板上没有一个字能解释；不该收回时收了，就是把一台好好的机器从 Wi-Fi
    /// 上拽下来，或者替按了 4G OFF 的客人做主。
    ///
    /// - `dataWanted`：客人那根开关的位置。为假（他自己按的 OFF）就不许动。
    /// - `linkWasUp`：这条链路在这台机器上真跑起来过。没跑起来过就没什么可
    ///   收回的，而动手只会在一台改不了网络服务的机器上反复重排进程。
    /// - `trouble`：模块这头出不出得了网。还没在网时开服务，等于把整台 Mac 的
    ///   默认路由交给一条出不去包的链路（见 `ensureHostService()`）。
    /// - `hasInterface`：macOS 已经把网卡发布出来。没有网卡就没有服务可开。
    /// - `routeOnModule`：默认路由还压在模块上就什么都不用做。它必须是**路由表
    ///   当场给的答案**，不是 `data.serviceEnabled` 那个缓存 —— 真机实测里正是
    ///   那个旧读数让这一段在服务被关掉之后还以为是好的。
    static func shouldRestoreHostLink(dataWanted: Bool,
                                      linkWasUp: Bool,
                                      trouble: String?,
                                      hasInterface: Bool,
                                      routeOnModule: Bool) -> Bool {
        dataWanted && linkWasUp && trouble == nil && hasInterface && !routeOnModule
    }

    // MARK: - 「模块的网卡被系统漏掉」的自愈

    /// 该不该为了这块没被命名的网卡重启一次模块。
    ///
    /// 抽成纯函数给自检喂，因为这里的每一个「不该」都对应客户能看见的一种
    /// 坏结果：多动一次就是白白断一次网，甚至把一通电话掐掉。
    ///
    /// - `wanted`：客人要这条链路。他自己按过 4G OFF 就什么都不做。
    /// - `connected`：模块在 AT 口上答得上话。没答上话是 `scanForModule()`
    ///   那一路的活，跟网卡没关系。
    /// - `stranded`：模块的网卡挂在系统里、没有名字 —— 这条故障的判据本身。
    /// - `consoleLocked`：屏幕锁着。**这时候动手一定是白动** —— 系统正是
    ///   因为锁屏才拒绝命名，重新枚举一次照样被拒绝（真机实测三次）。而且
    ///   客户人不在，白白断他二十秒网。
    /// - `callIdle`：通话中不碰。重启模块会把语音链路掐断。
    /// - `gaveUp`：已经试到头了。
    static func shouldRebootForStrandedInterface(wanted: Bool,
                                                 connected: Bool,
                                                 stranded: Bool,
                                                 consoleLocked: Bool,
                                                 callIdle: Bool,
                                                 gaveUp: Bool) -> Bool {
        wanted && connected && stranded && !consoleLocked && callIdle && !gaveUp
    }

    /// macOS 在屏幕锁着的时候会**拒绝**给新插上的网卡起名字。
    ///
    /// 2026-09-27 真机复现三次，每次都是新的 MAC 地址 —— 模块那边老老实实
    /// 重新枚举了，是系统这一头把接口丢下了。`configd` 的原话：
    ///
    ///     Console locked, network interface[matching] ignored:
    ///     path = .../Baiwang@14100000/IOUSBHostInterface@5/AppleUSBECMData/IOEthernetInterface
    ///
    /// 接口在 IOKit 里存在着（查得到，底下还挂着 `IONetworkStack`），就是
    /// 永远拿不到 `en59` 这个名字，**解锁之后系统也不会补做**。给客人看到的
    /// 就是「模块插着、灯亮着，可是没有网」，而且按多少次 4G 都没用：App 这边
    /// 看到的是「网卡还没出现」，它会一直等一个不会来的东西。
    ///
    /// 唯一的出路是让模块重新枚举一次。真机实测：屏幕醒着的时候发
    /// `AT+CFUN=1,1`，`en59` 消失十六秒之后自己回来；同样一条命令在锁定状态
    /// 下发出去，系统照样忽略。所以这里先看锁没锁 —— 锁着就只是记着，
    /// 等客人回来再动手。
    private func recoverStrandedInterface() {
        // 客人不想要这条链路。他按的 4G OFF，App 不许替他做主。
        guard dataWanted || wantsDataLink else {
            strandedSince = nil
            return
        }
        // 网卡好好地在，或者模块根本没插上：都没什么可救的，也不用去问
        // 屏幕锁没锁。这一条同时是限流阀 —— 绝大多数时候这里就返回了。
        guard !data.hasInterface, isConnected else {
            strandedSince = nil
            return
        }
        // 模块正在重启、手上还有别的活：等下一拍。
        guard !awaitingReconnect, !isWorking else { return }

        guard Self.shouldRebootForStrandedInterface(
            wanted: true,
            connected: true,
            stranded: data.interfaceStranded,
            consoleLocked: controller.data.consoleLocked,
            callIdle: call.state == .idle,
            gaveUp: strandedGaveUp) else {
            // 网卡其实好好的（`interfaceStranded` 为假）——把观察窗清掉。
            if !data.interfaceStranded { strandedSince = nil }
            return
        }

        // 观察窗：先看到、再动手。正常插拔时网卡几毫秒内就拿到名字，真的站到
        // 这一格意味着它已经等了 15 秒还没有。
        guard let since = strandedSince else {
            strandedSince = Date()
            return
        }
        guard Date().timeIntervalSince(since) >= Self.strandedGraceSeconds else { return }

        // 节拍：重启一次模块要断网二十秒，试得密对客人没有任何好处。
        if let last = strandedLastReboot,
           Date().timeIntervalSince(last) < Self.strandedRetrySeconds { return }

        guard strandedRebootTries < Self.strandedMaxReboots else {
            // 两次都没救回来，不再动手。拔一次再插一次永远管用。
            strandedGaveUp = true
            note("4G 网络没能自己接上，请把模块拔掉再插一次")
            return
        }
        strandedRebootTries += 1
        strandedLastReboot = Date()
        strandedSince = nil
        note("正在重新连接 4G 网络")
        restartModuleForStrandedInterface()
    }

    /// `AT+CFUN=1,1` —— 让模块重新枚举一次，把没有名字的那块网卡重做一遍。
    ///
    /// 走的是和切换 USB 那一档完全相同的收尾：先记下「等它回来」，再断开。
    /// 模块重启时 AT 口会消失十几秒，重连交给三秒一次的 `scanForModule()`。
    private func restartModuleForStrandedInterface() {
        guard isConnected else { return }
        beginAwaitReconnect(seconds: 45)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            _ = try? self.controller.session.send("AT+CFUN=1,1", timeout: 3)
            DispatchQueue.main.async {
                self.note("模块重启中")
                self.disconnect()
            }
        }
    }

    /// 模块拔掉了，这一段观察从头再来。
    private func resetStrandedRecovery() {
        strandedSince = nil
        strandedLastReboot = nil
        strandedRebootTries = 0
        strandedGaveUp = false
    }

    /// 实测不通要不要当成故障。
    ///
    /// 保命逻辑的总闸：这台电脑的默认路由现在是不是压在模块那块网卡上？
    ///
    /// 抽成纯函数是为了让自检能直接喂那组在真机上翻过车的输入 ——
    /// **路由在模块上，但 App 自己记的还是「服务没开」**。2026-09-26 交付当天
    /// 正是这一组让保命逻辑瞎了九十秒。
    ///
    /// `serviceEnabled` 是兜底，不是判据：接口名还没读到时候（App 刚起来、
    /// 模块刚插上、USB 刚重新枚举）路由表认不出这块网卡叫什么，至少还认得出
    /// App 自己刚打开的那条服务。
    static func holdsDefaultRoute(interfaceName: String, serviceEnabled: Bool) -> Bool {
        NetProbe.defaultRouteIsOn(interface: interfaceName) || serviceEnabled
    }

    /// 三条都满足才算：默认路由押在模块上（否则测出来的通不通跟 4G 没有关系）、
    /// 连着输够 `probeFailuresToTrouble` 次（链路抖一下不算）、机器上还有别的路
    /// 可走（没有别的路时关掉只是把最后一根线也剪了）。
    /// 抽成纯函数，自检直接喂输入就能验。
    ///
    /// 第一个参数 2026-09-26 从 `serviceEnabled` 改名成 `routeOnModule`：判据本身
    /// 没变，变的是**谁来回答它** —— 见 `guardDataRoute()` 顶上那一段。
    static func probeTrouble(routeOnModule: Bool, failures: Int, hasOtherUplink: Bool) -> Bool {
        routeOnModule && hasOtherUplink && failures >= probeFailuresToTrouble
    }

    /// 实测驱动的自动交回退避：30 秒起步，每多一次翻倍，封顶 15 分钟。
    private static func probeCooldown(_ count: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(1, count) - 1)), 900)
    }

    /// 每 `probeInterval` 秒在后台实测一次「这台电脑现在真的能出网吗」。
    ///
    /// 只在默认路由押在模块上的时候测：不在的时候默认路由在 Wi-Fi 上，测出来
    /// 的「通」跟 4G 毫无关系，拿它下结论只会把判断带偏。
    ///
    /// 跑在后台队列上 —— 最坏要等三个目标各 3 秒，放主线程上就是一次十秒的
    /// 卡顿，而主线程每次卡顿都会被记进日志。
    private func startNetProbeIfNeeded(routeOnModule: Bool) {
        guard routeOnModule, !netProbeInFlight else { return }
        if let last = netProbeCheckedAt, Date().timeIntervalSince(last) < Self.probeInterval { return }
        netProbeInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let reachable = NetProbe.reachableInternet()
            Task { @MainActor in
                self.netProbeInFlight = false
                self.netProbeCheckedAt = Date()
                self.netProbeReachable = reachable
                self.netProbeFailures = reachable ? 0 : self.netProbeFailures + 1
            }
        }
    }

    /// 停用那一下没落地时补一次，排满次数就把手工命令交出去。
    private func retryRouteRollback(trouble: String?) {
        guard let last = routeRollbackLastTry,
              Date().timeIntervalSince(last) >= Self.routeRetrySeconds else { return }
        guard routeRollbackTries < Self.routeRollbackMaxTries else {
            // 再排也是同样的结果（多半是这台机器不让 App 改网络服务）。
            // 说清怎么办，然后别再刷屏。
            guard routeRollbackTries == Self.routeRollbackMaxTries, !data.serviceName.isEmpty else { return }
            routeRollbackTries += 1
            lastError = "模块这条网络服务停不掉（\(trouble ?? "链路不通")），"
                + "默认路由还压在模块上。请在终端执行：\n"
                + HostNetwork.manualCommand(data.serviceName, false)
            return
        }
        routeRollbackTries += 1
        routeRollbackLastTry = Date()
        note("模块那条网络服务还没停掉，再试一次")
        setHostService(false)
    }

    /// Screenshot / demo only. The module half of the link is simulated by
    /// `SimulatedATTransport`, but the network service is a fact about *this
    /// Mac* that no AT command can produce, so the harness states it directly.
    /// The live paths above never call this.
    func seedHostLink(interface: String, ipv4: String, service: String, enabled: Bool) {
        controller.data.overrideHostState(interface: interface, ipv4: ipv4,
                                          service: service, enabled: enabled)
        data = controller.data.status
    }

    /// Screenshot / demo only, the totals half of `seedHostLink`: the numbers
    /// printed under the ring are pinned to what the module reports, so the
    /// panel comes out the same whether or not a module is attached to the
    /// machine doing the rendering. Left unpinned, the poll reads whatever
    /// interface is up here and the screenshots quietly change.
    func seedModuleCounters() {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        if let counters = try? controller.data.moduleCounters() {
            received = counters.received
            sent = counters.sent
        }
        controller.data.overrideCounters(bytesIn: received, bytesOut: sent, source: .module)
        data = controller.data.status
    }

    /// Screenshot / demo only, the audio half of `seedHostLink`: the module's
    /// USB audio function is a fact about the USB tree that no AT command can
    /// produce, so the harness states it directly. The live paths never call it.
    func seedModuleAudio(name: String) {
        controller.voice.seedModuleDevice(name: name)
        voice = controller.voice.refreshStatus()
    }

    /// Screenshot / demo only, the opposite of `seedModuleAudio`: pin the state
    /// where the host sees no module sound card at all. That is what a Mac
    /// really reports after `usbcfg`'s audio flag is turned off for a phone,
    /// and it is the state the phone-audio screenshots describe. Without it the
    /// row reads whatever module happens to be plugged into the machine doing
    /// the rendering — on a dev Mac that is a live `已识别 AC Interface` sitting
    /// three lines under「声卡是关着的」.
    func seedNoModuleAudio() {
        controller.voice.seedNoModuleDevice()
        voice = controller.voice.refreshStatus()
    }

    /// Screenshot / demo only: pin the 通话语音 row to「已就绪」.
    ///
    /// 那一行的五个位是「这台机器上现在插着什么」的结论 —— 出图的机器上正好
    /// 插着模块、而模块又还没装过语音时，导出的图就会在一段「两个方向都有
    /// 声音」的文案旁边写着「未安装」。图是要给客户看的商品图，所以这里把
    /// 它钉成和其它种子事实一致的同一个模块：装好语音的那一个。
    func seedVoiceSetup() {
        voiceSetupPinned = true
        var status = ModuleVoiceSetup.Status()
        status.adbBinary = "/usr/local/bin/adb"
        status.moduleReachable = true
        status.adbUnlocked = true
        status.driversLoaded = true
        status.calibrated = true
        status.bridgeRunning = true
        status.audioEnabled = true
        status.soundCardPresent = true
        voiceSetup = status
        voiceSetupVerifiedAt = Date()
    }

    /// Screenshot only: 把面板摆成「来电响铃」那一屏。
    ///
    /// 那顶横幅只有真有一条来电时才画得出来，而真机档没有模拟器可点
    /// （`simulateIncomingCall()` 第一行就 `guard let simulator` 退掉了），
    /// 于是封面用的这一屏在真机上永远截不到，出货图只能退回模拟器那一版 ——
    /// 连模块型号都跟着变成模拟器的默认值 `EG25-G`。这里直接把通话状态摆成
    /// 响铃，号码沿用宣传图一直在用的那一个。
    func seedIncomingCall(number: String) {
        callPinned = true
        call = CallInfo(index: 1, direction: .incoming, state: .ringing, number: number)
    }

    /// 出图 / 演示专用：钉住通话记录那几行。
    ///
    /// 真机路径上这份列表是跟着通话状态自己攒出来的，而出图机上攒不出来 ——
    /// 一是不打电话（`announcesAlerts` 为假时压根不记），二是这台机器上那份
    /// 真客户的 `calllog.json` 会被读进来。所以摆一排样板记录进去。
    func seedCallHistory(_ records: [CallRecord]) {
        callHistory.seed(records)
        callRecords = callHistory.records
    }

    /// Screenshot / self-check only: pretend the system refused notifications.
    ///
    /// 真机上这个位只能由 `UNUserNotificationCenter` 的回调写，而无头路径
    /// （`--render` / `--sim-check`）的进程没有 bundle，那条回调永远不会来 ——
    /// 于是「没允许通知」那行提示的排版没有任何人能看一眼。它偏偏是客户会
    /// 看到的第一句话，值得有一张图。
    func seedNotificationsBlocked() {
        notificationsBlocked = true
    }

    /// Screenshot only: the 通话窗口 with the microphone refused.
    ///
    /// 麦克风那一行平时根本不出现（授权是常态），而它恰恰是 2026-09-30 那通
    /// 「接通 33 秒才出声」的电话唯一该被看到的一句话。没有一张图，下次再改
    /// 到这一块又是客户先看见。
    func seedMicrophoneDenied() {
        micStatePinned = true
        micDenied = true
        micUnasked = false
    }

    /// Screenshot only: 还一次都没问过的那一档。
    ///
    /// 客户第一次装完看到的就是这一档 —— 系统框还没弹，界面上那句得先把人
    /// 引到「去授权」上。和「被拒过」分开画，是因为两句文案不一样。
    func seedMicrophoneUnasked() {
        micStatePinned = true
        micDenied = false
        micUnasked = true
    }

    /// Toggles the module's macOS network service without touching the modem,
    /// for when the two halves have drifted apart.
    /// 只动 macOS 那半边：启用 / 停用模块的网络服务。
    ///
    /// 细节区那颗「开关」按的就是它，而面板中间的 4G 胶囊管的是同一件事的
    /// 另外两半（APN、PDP）。谁被按了，开关显示的位置都得跟着走 —— 不跟的话
    /// 两处会各说各的：胶囊说「4G OFF」，底下那行却写着「已启用」。
    func setHostService(_ enabled: Bool) {
        let accepted = run(enabled ? "启用模块网络服务" : "停用模块网络服务") {
            let service = try self.controller.data.setHostService(enabled: enabled)
            _ = self.controller.refreshData()
            self.note("\(service.name) → \(enabled ? "已启用" : "已停用")")
        }
        guard accepted else { return }
        dataSwitchTouched = true
        dataSwitchTouchedAt = Date()
        dataWanted = enabled
    }

    func setUSBnetMode(_ mode: USBnetMode) {
        run("切换 USB 网络模式") {
            _ = try self.controller.data.setUSBnetMode(mode, reboot: mode == .ecm)
            _ = self.controller.refreshData()
            if mode == .ecm {
                // 这一步会让模块重启。以前这里只写了一句「等 10 秒后会自动
                // 重连」，可 `scanForModule` 在连上时直接返回，那句话从来没有
                // 兑现过：面板停在切换前的数字上，直到客户重启 App。现在和另
                // 外两条重启路径一样，主动断开、等它回来。
                self.awaitModuleReboot(note: "模块要重启一下，等它回来会自动重连")
            }
        }
    }

    // MARK: - 按键音（通话中）

    /// 键盘上点过的位，排队等着发出去。
    private var dtmfPending: [String] = []
    /// 这一串点过的位，收尾时合成一条写进活动记录。
    private var dtmfBurst = ""
    /// 正在发一位（那一条 AT 命令在后台跑着）。
    private var dtmfSending = false

    /// 键盘上按下一位。
    ///
    /// 不走 `run`：它在上一步没结束时会把后一步顶回去（红字「上一步操作还
    /// 没结束」）—— 那条规矩是给「拨号 / 挂断」这种一步一个脚印的动作定的。
    /// 键盘是一位一位点着走的，连点两下比什么都常见，手一快就报错，读起来
    /// 像坏了。所以按键音自己排一条队：按顺序发，位与位之间由 `CallService`
    /// 留间隔，谁都不打断谁。
    func sendDTMFKey(_ digit: String) {
        guard call.state == .active else { return }
        // 只放行电话机上真有的那些键（`AT+VTS` 也只认这一组）。
        guard let key = digit.uppercased().first, "0123456789*#ABCD".contains(key) else { return }
        dtmfPending.append(String(key))
        drainDTMFQueue()
    }

    /// 把队首那一位发出去，发完接着下一位。
    ///
    /// 分工和 `run` 一样：状态（队列、这一串点过的位）全在主线程上过，只有
    /// 那条会阻塞的 AT 命令进后台。
    private func drainDTMFQueue() {
        guard !dtmfSending else { return }
        guard let digit = dtmfPending.first, call.state == .active else {
            // 空了，或者通话已经结束（剩下的位不再有意义：空闲态模块只会
            // 回 ERROR）—— 收尾，把这一串点过的位并成一条记录。
            dtmfPending.removeAll()
            flushDTMFBurst()
            return
        }
        dtmfPending.removeFirst()
        dtmfSending = true
        // `async` 收的是 `@Sendable` 闭包，而这一段要碰的 `CallService`
        // 不是 Sendable 的。包一层 `DispatchWorkItem` 语义完全一样，且不用
        // 逼它满足 Sendable —— 和 `setOnMain` 同一个理由。
        let calls = controller.calls
        DispatchQueue.global(qos: .userInitiated).async(execute: DispatchWorkItem { [weak self] in
            var failure: Error?
            do { try calls.sendDTMF(digit) } catch { failure = error }
            let finish = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.dtmfSending = false
                if let failure {
                    // 通话结束导致的失败不报红：通话窗已经翻篇，一句红字
                    // 只会留在那儿等下一次通话来背锅。
                    if self.call.state == .active {
                        self.lastError = "发送按键 \(digit)失败：\(failure)"
                        self.note("发送按键 \(digit)失败：\(failure)")
                    }
                    self.dtmfPending.removeAll()
                } else {
                    self.dtmfBurst += digit
                }
                self.drainDTMFQueue()
            }
            DispatchQueue.main.async(execute: finish)
        })
    }

    /// 一串点完（或断在中间）：并成一条写进活动记录。
    private func flushDTMFBurst() {
        guard !dtmfBurst.isEmpty else { return }
        note("发送按键 \(dtmfBurst)")
        dtmfBurst = ""
    }

    /// 模块现在实际在哪一档。
    ///
    /// 两样都读得到才算得出来：USB 网卡不是 ECM（模块还是出厂态），或者组态
    /// 还没读到，都答不出「现在是哪一档」—— 那时候正确答案是「不知道」，
    /// 不是猜一个。
    var hostModeNow: HostMode? {
        guard data.usbnetMode == .ecm, let audio = data.composition?.audio else { return nil }
        return audio ? .mac : .mobile
    }

    /// 切到指定的一档：USB 网卡走 ECM，声卡按这一档开或关。
    ///
    /// 两件事一起写、只重启一次 —— 客户按的是「换一档」，不是两个开关。
    /// 已经就是这一档时直接返回：切换要重启模块，能少重启一次是一次。
    func applyHostMode(_ mode: HostMode) {
        hostModeChoice = mode
        if data.usbnetMode == .ecm, data.composition?.audio == mode.wantsAudio {
            note("已经是\(mode.label)，不用改")
            return
        }
        run(mode.label) {
            if self.controller.data.status.usbnetMode != .ecm {
                let net = try self.controller.data.setUSBnetMode(.ecm, reboot: false)
                // 失败那半句不报模块自己那一串档位名（「Windows 电脑 / 特殊
                // 用途 MBIM」）：客户认的是设置页上那两个词，读到一串没见过的
                // 协议名只会以为要自己去挑。这里只说他能做的那件事。
                self.note(net == .ecm ? "网络模式：已设好" : "网络模式没设上，稍后再试一次")
            }
            let composition = mode.wantsAudio
                ? try self.controller.voice.enableAudioFunction(reboot: true)
                : try self.controller.voice.disableAudioFunction(reboot: true)
            guard composition.audio == mode.wantsAudio else {
                throw CoreAudioError.compositionRejected(composition.flagString)
            }
            self.note(mode.wantsAudio ? "声音功能：已打开" : "声音功能：已关闭")
            // 模块出厂时 APN 是空的，重启回来没有 APN 就上不了网。尽力而为：
            // 读不到运营商不该让「换一档」这件事整个失败。
            if (try? self.controller.applyCarrierAPN(force: false)) != nil {
                self.note("上网参数已按运营商设好")
            }
            self.awaitModuleReboot(note: "模块正在重启，回来自动重连")
        }
    }

    /// 插上模块以后，把它摆回客户上次选的那一档。
    ///
    /// 只能做到这一步：模块插在手机上时，这台电脑上没有任何东西看得到它，
    /// 也替不了手机改设置。所以「插手机」那一档要客户自己选一次；选过之后，
    /// 每次插回电脑都会自己回到那一档，不用每回拔插都重新想一遍。
    ///
    /// 两个读数都齐了、而且确实对不上才动，一个连接只动一次：切换要重启
    /// 模块，而刚插上那一秒读到的还可能是空值。
    private func restoreHostModeIfNeeded() {
        guard isConnected, !didRestoreHostMode else { return }
        guard let audio = data.composition?.audio, let net = data.usbnetMode else { return }
        // 刚插上那一拍正在读状态，这时候排写入会被「上一步操作还没结束」挡
        // 回来。等它读完再来一次。
        guard !isWorking else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.restoreHostModeIfNeeded()
            }
            return
        }
        didRestoreHostMode = true
        guard net != .ecm || audio != hostModeChoice.wantsAudio else { return }
        note("按上次的选择：\(hostModeChoice.label)")
        applyHostMode(hostModeChoice)
    }

    /// The whole point of the project: turn the factory composition (AT + NMEA
    /// + DIAG only) into one that also carries a network interface and a USB
    /// audio function, which is what calls and ECM data need.
    func enableFullFunction() {
        run("一键启用") {
            if self.controller.data.canSwitchUSBnetMode {
                let mode = try self.controller.data.setUSBnetMode(.ecm, reboot: false)
                self.note(mode == .ecm
                          ? "电脑连接方式：已设好"
                          : "电脑连接方式没设上，现在是 \(mode.label)")
            }
            // 声音功能同样是厂家私有的写法。改不了就跳过 —— 别的厂家要的是
            // 它自己那一套，硬发一条会被拒的命令只会让这一整个按钮失败。
            if self.controller.canConfigureAudio {
                let composition = try self.controller.voice.enableAudioFunction(reboot: true)
                self.note(composition.audio
                          ? "声音功能：已打开"
                          : "声音功能没能打开，模块没接受这个设置")
            }
            // The module ships with an empty APN, and a PDP context cannot come
            // up without one after the reboot. Best effort on purpose: not
            // being able to read the operator must not fail the one button that
            // turns the module into a phone.
            if (try? self.controller.applyCarrierAPN(force: false)) != nil {
                self.note("上网参数已按运营商设好")
            }
            // 上面两步一步都没写成的时候，模块不会重启 —— 那就别让客户等一件
            // 不会发生的事。
            if self.controller.canConfigureAudio || self.controller.data.canSwitchUSBnetMode {
                self.awaitModuleReboot(note: "模块正在重启，等它回来会自动重连")
            }
        }
    }

    func sendSMS(text: String, to number: String, completion: @escaping (Bool) -> Void) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !number.isEmpty else { completion(false); return }
        // 回调另一头是写信窗口的 @State（「已发送 / 发送失败」），而 `run` 的
        // body 跑在后台队列上 —— 统一在主线程回话。已经在主线程时（被挡下的
        // 那一路）不多跳一次，行为与从前一致。
        let reply: (Bool) -> Void = { [weak self] ok in
            self?.setOnMain { completion(ok) }
        }
        let started = run("发送短信给 \(number)") {
            guard self.sim.ready else {
                reply(false)
                throw SMSError.notReady(self.sim.unavailableReason)
            }
            let parts = try self.controller.sms.send(text: body, to: number)
            self.note("已发送 \(parts) 段")
            _ = try self.controller.refreshMessages()
            reply(true)
        }
        // A refused send has to come back as a failure too. The sheet reports
        // 「发送失败」 and stays open; leaving it on 「发送中…」 would say the
        // message might still go out, which is the one thing that is not true.
        if !started { reply(false) }
    }

    func deleteSMS(_ message: SMSMessage) {
        run("删除短信") {
            try self.controller.sms.delete(index: message.storageIndex)
            _ = try self.controller.refreshMessages()
        }
    }

    /// 清空收件箱。
    ///
    /// 短信存在**模块**里，不是卡里 —— 换一张卡进来，上一张卡（甚至上一位
    /// 机主）留下的短信照样在列表里躺着。转手出去的模块尤其明显：客户一插
    /// 上就看到一堆别人的验证码和营销短信，第一反应是「这机器被人用过」。
    /// 逐条删要删十下，所以给一个一次清干净的口子，走 `AT+CMGD=1,4`。
    func clearSMS() {
        run("清空收件箱") {
            try self.controller.sms.deleteAll()
            self.note("收件箱已清空")
            _ = try self.controller.refreshMessages()
        }
    }

    /// 清空通话记录。
    ///
    /// 和收件箱不一样：这一份是 App 自己攒在 `~/Library/Application Support/DJI4G/calllog.json`
    /// 里的（模块不给历史），所以不用碰模块、不用等 AT 会话，清完立刻见效。
    func clearCallHistory() {
        callHistory.clear()
        callRecords = []
        note("通话记录已清空")
    }

    func dial(_ number: String) {
        run("拨打 \(number)") {
            // Dialling without a card would come back as a bare `+CME ERROR`,
            // which reads like a fault. The panel already knows why.
            guard self.sim.ready else { throw CallError.noSIM(self.sim.unavailableReason) }
            try self.controller.calls.dial(number)
            // 拨号不再顺手把系统默认音频切到模块：语音由 `CallAudioBridge`
            // 直接绑设备走，和系统默认输入输出没有关系。把默认设备指过去
            // 只会让客户在没要求的时候丢掉电脑的声音（见 `AudioRouting`）。
            self.refreshVoice()
        }
    }

    func answer() {
        // A parked second caller is not ringing, so answering it is a different
        // request to the network (`AT+CHLD=2`) than picking up a normal ring.
        let waiting = call.state == .waiting
        callAction(waiting ? "接听新来电" : "接听", .answer) {
            // 标记放在真正发命令这一下，不放按钮上：排队等会话的那条路会
            // 重新走一遍这个闭包，放在按钮上会对着还没发生的事记一笔。
            if waiting { self.callHistory.markAnsweredWaiting() }
            _ = try self.controller.calls.answer()
        }
    }

    /// 通话按钮共用的那一跳：会话空着就立刻发，被别人占着就排队等下一次。
    ///
    /// 为什么不能像别的按钮那样「被挡回来就算了」：「上一步操作还没结束」对
    /// 客户是一句可以重试的话，对着一个正在响的电话却不是 —— 铃响只有半分钟，
    /// 客人按了「接听」，那一下必须算数，他不会按第二次。2026-09-28 自检里抓到
    /// 的就是这件事：夹具在忙的时候按接听，`run` 把这一跳整个挡回去，状态原地
    /// 不动，电话一直响到对方放弃。真机上挡得住它的活不少（打开面板时那次整体
    /// 刷新、自动配 APN、语音体检），它们扎堆的正是「模块刚连上、刚插卡」那
    /// 几秒 —— 也就是电话最可能撞进来的那几秒。
    ///
    /// 排队的是**意图**不是那一次调用：等到会话空出来的时候，对方可能已经挂
    /// 了，`flushPendingCallIntent()` 会先看一眼还算不算数再发。
    @discardableResult
    private func callAction(_ label: String, _ intent: CallIntent,
                            _ body: @escaping () throws -> Void) -> Bool {
        guard !run(label, body) else { return true }
        // `run` 那条红字是为按钮写的：它挡下的是没被收下的活。这一按我们收下
        // 了，只是排在后面，不能为一件正在排队的事写红字（数据开关同理，
        // 见 `setDataEnabled` 末尾）。
        lastError = nil
        pendingCallIntent = intent
        note("\(label)排在上一步后面执行")
        return false
    }

    /// 把排队等会话的那一下通话动作补上。
    ///
    /// 两个来源：每一步跑完的 `fulfillPendingRead()`，和两秒一拍的
    /// `pollCallState()`。后一条不能少 —— 挡下它的那一步万一自己失败了，
    /// `fulfillPendingRead()` 是不跑的（那条路只在成功时走，否则会擦掉刚写下
    /// 的红字），而电话那头不等。
    private func flushPendingCallIntent() {
        guard let intent = pendingCallIntent else { return }
        guard isConnected, !isWorking, !awaitingReconnect else { return }
        // 过期的意图不能再发：排队的这一会儿里对方可能已经挂了、客人自己
        // 挂断了，这时候补一条 `ATA` 只会换来一条 ERROR 红字和一次假动作。
        pendingCallIntent = nil
        switch intent {
        case .answer, .reject:
            guard call.state == .ringing || call.state == .waiting else { return }
        case .hangup:
            guard call.state.isBusy else { return }
        }
        switch intent {
        case .answer: answer()
        case .reject: reject()
        case .hangup: hangup()
        }
    }

    func hangup() {
        let waiting = call.state == .waiting
        callAction("挂断", .hangup) {
            // 响铃中的来电按挂断，在对面看就是被拒 —— 记录里写「已拒接」，
            // 写「没接到」和事实相反。「挂断全部」把第二路一起挂掉，同理。
            if waiting { self.callHistory.markRejectedWaiting() } else { self.callHistory.markHungUp() }
            try self.controller.calls.hangup()
            // 客户手动按过「切到模块」的话，挂断时把设备还回去 —— 这是唯一
            // 会主动撤销手动选择的地方，因为留在一个单向设备上的代价（电脑
            // 没声音了）比留着一个用不上的选择大得多。
            _ = self.controller.voice.deactivate()
            self.refreshVoice()
        }
    }

    func reject() {
        let waiting = call.state == .waiting
        callAction(waiting ? "拒接新来电" : "拒接", .reject) {
            if waiting { self.callHistory.markRejectedWaiting() } else { self.callHistory.markRejected() }
            try self.controller.calls.reject()
        }
    }

    /// 客户自己按的「切到模块」：把**系统默认**输入输出指到模块的 USB 声卡上。
    ///
    /// 不是通话语音的必经之路 —— 通话走 `CallAudioBridge`，直接绑设备，不动
    /// 默认设备。这个按钮留着只为一件事：客户想拿模块当普通 USB 声卡用
    /// （比如在系统设置里自己挑设备试音）。模块把 UAC 拆成两个单向设备，
    /// 所以指过去以后电脑自己的音乐和提示音会一起改道，挂断时自动还回来。
    func routeAudioToModule() {
        // 这一读留在主线程：按钮回调本来就在主线程，而 `voice` 是 @Published，
        // 从下面那个后台 body 里读它等于和主线程的写入抢同一个字段。
        let alreadyRouted = voice.isRouted
        run("切换模块声卡") {
            let status = alreadyRouted
                ? self.controller.voice.refreshStatus()
                : try self.controller.voice.activate()
            self.setOnMain { self.voice = status }
            if status.isRouted {
                self.note("已把系统默认音频切到模块；挂断时会自动还回去")
            }
        }
    }

    // MARK: - 让来电被看见

    /// 来电同时走两条路：系统通知（尽力而为，客户可能没允许通知），和一张
    /// 浮在最上面的卡片（不经过任何授权，铃声也自己响）。
    ///
    /// 只写通知这一条是不够的：2026-09-24 这台机器的实测里，电话打进来时
    /// 通知没有出现，号码只在客户手动点开的面板里，客户因此以为电话没通。
    private func surfaceRing() {
        RingAlert.shared.update(call,
                                enabled: announcesAlerts,
                                answer: { [weak self] in Task { @MainActor in self?.answer() } },
                                reject: { [weak self] in Task { @MainActor in self?.reject() } })
    }

    /// 两秒一次的 `AT+CLCC`，来电的第二条通道：URC 丢了也还有它。
    ///
    /// 读到的状态和 URC 走同一条 `apply(.call)`，所以来电、被接听、对方挂断
    /// 都会照常更新面板和卡片，不需要第二条状态机。
    private func pollCallState() {
        // 排队等会话的那一下通话动作也在这里看：电话那头不等，而两秒一拍的
        // 这条是无论前面成功还是失败都还在走的窗口。
        flushPendingCallIntent()
        // 会话正被别的命令占着时 `refreshCalls()` 会直接抛错 —— 那是正常排队，
        // 不是故障，安静跳过这一拍就好（写进活动列表就成了客户眼里的红字）。
        guard isConnected, !awaitingReconnect, !isWorking, !isPollingCall else { return }
        isPollingCall = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let failed = (try? self.controller.refreshCalls()) == nil
            Task { @MainActor in
                self.isPollingCall = false
                self.notePollHealth(failed: failed)
            }
        }
    }

    /// 轮询本身的健康度。
    ///
    /// 「模块没上报来电」和「上报了没人接住」在日志里本来长得一模一样，而这两种
    /// 坏法要查的地方完全不同 —— 客户说「电话打不进来」时，两手一摊没有痕迹。
    /// 单次失败是正常排队（会话被别的命令占着），只有连着失败才是真坏了，所以
    /// 按连续次数报，不按单次报。
    private func notePollHealth(failed: Bool) {
        if failed {
            pollFailures += 1
            // 两秒一拍，连着八拍是十六秒。正常的命令排队排不到这么久。
            if pollFailures == 8 {
                note("暂时读不到通话状态，这期间来电可能收不到（还在重试）")
            }
            return
        }
        pollFailures = 0
        guard ProcessInfo.processInfo.environment["DJI4G_VOICE_DEBUG"] == "1" else { return }
        pollTicks += 1
        guard pollTicks % 15 == 0 else { return }
        note("轮询正常 · 状态\(call.state.label)")
    }

    // MARK: - Ring announcement

    /// Holds the 「来电」 notification until the caller's number is known.
    ///
    /// The module reports a ring as two lines — `RING`, then `+CLIP: "number"` —
    /// and posting straight from the first one announces 「未知号码」 for a call
    /// whose number shows up in the panel microseconds later. Rather than guess
    /// which line a given network leads with, the announcement waits: it goes out
    /// the moment the number arrives, and goes out as 「未知号码」 if none ever
    /// does, because `+CLIP` is a subscription rather than a guarantee.
    ///
    /// The wait is short enough to be invisible next to a ring that lasts half a
    /// minute, which is the only thing this timing has to beat.
    private func announceRing() {
        guard ringAnnouncement == nil else { return }
        ringAnnouncement = Timer.scheduledTimer(withTimeInterval: Self.ringNoticeGrace,
                                                repeats: false) { [weak self] _ in
            Task { @MainActor in self?.deliverRingNotice() }
        }
    }

    private func cancelRingNotice() {
        ringAnnouncement?.invalidate()
        ringAnnouncement = nil
    }

    private func deliverRingNotice() {
        let ringing = call.state == .ringing
        let who = call.number.isEmpty ? "未知号码" : call.number
        cancelRingNotice()
        guard ringing else { return }
        Notifier.shared.post(title: "来电 · \(who)", body: "打开面板可以接听")
    }

    /// 通话状态一变就跑一次：接上通话语音，通话结束后再把它拆掉。
    ///
    /// 这里以前会在响铃时**自动**把系统默认麦克风和扬声器切到模块的 USB
    /// 声卡。那条路是错的 —— 模块把 UAC 拆成两个单向设备（`AC Interface`
    /// 只有输入、`AS Interface` 只有输出），指过去等于让客户的音乐和提示音
    /// 改道去一块既不播报也不录音的设备，而通话照样没声音。
    ///
    /// 真正的语音通路是 `CallAudioBridge`：它**直接绑设备**、全程不动系统
    /// 默认输入输出，只在通话期间活着。所以这里现在做三件事 ——
    /// 通话开始起桥、通话结束停桥、结束后把客户手动切过去的设备还回来。
    private func followCallAudio(previous: CallState) {
        let stateNow = call.state
        let wasBusy = previous.isBusy
        let becameBusy = stateNow.isBusy && !previous.isBusy
        let becameIdle = !stateNow.isBusy && previous.isBusy

        // 桥的起停不用等设备列表 —— 它们本来就排在 `callAudioQueue` 上。
        if becameBusy {
            // 新的一通，把所有自动重接的账清零：上一通的重试次数不能算到
            // 这一通头上，否则第二通就只剩一次机会了。
            callStartAttempts = 0
            callRecoveryAttempts = 0
            callSilentRetryDone = false
            callRecoveryInFlight = false
            callActiveSince = nil
            startCallAudioBridge()
        }
        if becameIdle { stopCallAudioBridge() }

        // 剩下的全是要问 CoreAudio 的，一律挪出主线程（见 `voiceDeviceQueue`）。
        // 这一路上被冻住的正是来电那几秒，而铃响只有半分钟：界面卡住就等于
        // 「电话打进来没反应」。
        Self.voiceDeviceQueue.async(execute: DispatchWorkItem { [weak self] in
            guard let self else { return }
            let status = self.controller.voice.refreshStatus()

            // 「刚才还在通话，这一拍不在了」才算通话结束。`refreshCalls()` 每两秒
            // 把同一个状态重报一次，如果跟着每一拍都还一遍，活动列表会被同一句话
            // 刷满；而这个动作本来也只在这个边界上有意义。
            var restored: VoiceStatus?
            if wasBusy,
               AudioRouting.action(current: stateNow, isRouted: status.isRouted) == .restore,
               // `deactivate()` 只在真的切过的时候才动设备（返回 false 表示
               // 客户 / 系统自己设的默认设备，不归这个 App 管）。
               self.controller.voice.deactivate() {
                restored = self.controller.voice.refreshStatus()
            }
            let final = restored ?? status

            DispatchQueue.main.async {
                // 读的这一会儿状态又翻了一页，手上这份就是过期的，丢掉 ——
                // 写进去只会让面板闪一下错的。轮询每两秒来一次，下一次事件
                // 会带着新的状态再走一遍。
                guard self.call.state == stateNow else { return }
                self.voice = final
                if restored != nil {
                    self.note("通话结束，音频已还给系统默认设备")
                }
            }
        })
    }

    // MARK: - 通话语音

    /// 「通话语音」那一格要写的词。
    ///
    /// 自动补装的那几十秒里 `voiceSetup.shortLabel` 还停在「缺驱动」上，
    /// 客户看着像点了没反应；进度写出来才说明它真的在动。
    var voiceStatusLabel: String {
        if callVoiceLive { return "通话中" }
        if voiceRepairing { return voiceRepairStep ?? "补装中" }
        return voiceSetup.shortLabel
    }

    /// 体检一遍通话语音的前置条件。只读，不动模块 —— 面板打开就能调。
    ///
    /// 体检本身要起 `adb` 子进程、还要抢一次 AT 会话，所以不走主线程：两个
    /// 调用方都是 SwiftUI 的 `.onAppear`（开面板、开设置页），同步做出来的
    /// 效果就是「点开面板先卡一下」，而 USB 刚插上时 adb 正是最慢的时候。
    func refreshVoiceSetup() {
        // 出图那一遍钉住的状态不能被一次真机探测覆盖（见 `seedVoiceSetup`）。
        guard !voiceSetupPinned else { return }
        // 包一层 `DispatchWorkItem` 是有意的：`async` 收 `@Sendable` 闭包，
        // 而这具身体碰的全是主线程状态（见 `setOnMain`）。
        Self.voiceProbeQueue.async(execute: DispatchWorkItem { [weak self] in
            guard let self else { return }
            let status = self.voiceProvision.inspect()
            self.setOnMain { self.voiceSetup = status }
        })
    }

    /// 一键把通话语音装上：解锁 ADB → 加载厂商语音驱动 → 下发出厂语音校准
    /// → 起 PCM 桥 → 打开 audio_enable。已经在的部分自动跳过，所以它可以
    /// 反复点 —— 客户不需要知道哪一步做过了。
    ///
    /// 第一步会重启一次模块（`AT+QCFG` 写完要 `AT+CFUN=1,1`），**所以这个
    /// 动作不能在通话里跑**：桥挂在 USB 声卡上，重启会把刚接通的通话变成
    /// 一通没声音的电话。通话窗口里那个按钮因此只在空闲时出现。
    func installCallVoice() {
        // 先立起重启窗口：安装中间模块会消失一阵，三秒一次的重连失败写出来
        // 就是客户自己点出来的一片红字，而它只是这个动作的一部分。
        beginAwaitReconnect(seconds: 180)
        note("开始安装通话语音；模块会重启一次，等它回来会自动重连")
        run("安装通话语音") {
            let final = try self.voiceProvision.install { progress in
                switch progress {
                case .step(let name): self.note("… \(name)")
                case .done(let name): self.note("✓ \(name)")
                }
            }
            self.setOnMain { self.voiceSetup = final }
            if !final.ready {
                self.note("通话语音还差一步：\(final.summary)")
            }
        }
    }

    /// 通话语音该不该自己补一遍。给定时器和「刚连上」共用。
    ///
    /// 这里刻意**不**预读任何东西：`voiceSetup.ready` 为真时直接返回，
    /// 一个子进程都不起。客户机上这块九成九的时间都是这条快路。
    private func checkVoicePathIfNeeded() {
        guard simulator == nil else { return }
        guard isConnected, !isWorking, !awaitingReconnect else { return }
        // 通话中不动它：桥挂在 USB 声卡上，半路重装会把一通正在打的电话
        // 变成没声音的电话。等挂断了下一拍自然会来。
        guard call.state == .idle, !isRepairingVoice else { return }
        // 已知是好的，且刚验过，就不起子进程 —— 客户机上九成九的时间走这条。
        if voiceSetup.ready, let verified = voiceSetupVerifiedAt,
           Date().timeIntervalSince(verified) < 300 { return }
        if let notBefore = voiceRepairNotBefore, Date() < notBefore { return }
        runVoiceAutoRepair()
    }

    /// 把丢掉的那几步补回来。
    ///
    /// **只补不需要重启模块的部分。** ADB 那一位没翻起来时必须走
    /// `AT+CFUN=1,1`，模块会消失二十秒、网也断一下 —— 那种动作只能由客户
    /// 自己点「一键安装」，不能背着他做。所以这里一看到 adb 不通就
    /// 收手，把界面留给那个按钮去解释。
    ///
    /// 反过来，`adb` 已经通的时候整条 `install()` 里一步重启都没有（见
    /// `install` 的第 1 步），插拔一次模块正是这种情况：usbcfg 存在模块的
    /// NVRAM 里，掉的只有内核里的驱动。
    private func runVoiceAutoRepair() {
        isRepairingVoice = true
        voiceRepairing = true
        voiceRepairStep = "检查中"
        Self.voiceProbeQueue.async(execute: DispatchWorkItem { [weak self] in
            guard let self else { return }
            let status = self.voiceProvision.inspect()

            guard status.moduleReachable, status.adbUnlocked else {
                // 这一档不是失败，是「还轮不到我」：模块刚插上时 adbd 还在起、
                // AT 通道也未必立刻答话，而这几分钟恰恰是客户插回来等声音的
                // 时候。所以头三次退一分钟就再看一眼；连着三次都没成（多半是
                // ADB 位压根没翻，那要客户点按钮），再退回五分钟一档，免得
                // 白烧 CPU、白刷模块的 dmesg。
                // 2026-09-26 实测：这一档原先一律退五分钟，插上后要等 5 分半
                // 才自己好；原因就是首次尝试撞在 adbd 还没起来的那几秒上。
                self.setOnMain {
                    self.voiceAdbWaitAttempts += 1
                    let wait: TimeInterval = self.voiceAdbWaitAttempts <= 3 ? 60 : 300
                    if !self.voiceBailLogged {
                        self.voiceBailLogged = true
                        self.note(status.moduleReachable
                                  ? "通话语音还在准备中，一分钟后再自动检查一次"
                                  : "通话语音在等模块连上，一分钟后再自动检查")
                    }
                    self.voiceSetup = status
                    self.voiceSetupVerifiedAt = Date()
                    self.isRepairingVoice = false
                    self.voiceRepairing = false
                    self.voiceRepairStep = nil
                    self.voiceRepairNotBefore = Date().addingTimeInterval(wait)
                }
                return
            }
            guard !status.ready else {
                self.setOnMain {
                    self.voiceSetup = status
                    self.voiceSetupVerifiedAt = Date()
                    self.isRepairingVoice = false
                    self.voiceRepairing = false
                    self.voiceRepairStep = nil
                    self.voiceRepairNotBefore = nil
                    self.voiceAdbWaitAttempts = 0
                    self.voiceBailLogged = false
                }
                return
            }

            do {
                let final = try self.voiceProvision.install { progress in
                    let label: String
                    switch progress {
                    case .step(let name): label = name
                    case .done(let name): label = "✓ \(name)"
                    }
                    self.setOnMain { self.voiceRepairStep = label }
                }
                self.setOnMain {
                    self.voiceSetup = final
                    self.voiceSetupVerifiedAt = Date()
                    self.isRepairingVoice = false
                    self.voiceRepairing = false
                    self.voiceRepairStep = nil
                    if final.ready {
                        self.voiceRepairNotBefore = nil
                        self.voiceAdbWaitAttempts = 0
                        self.voiceBailLogged = false
                        self.note("通话语音已自动补装完成（模块每次断电后都要重装一遍）")
                    } else {
                        self.voiceRepairNotBefore = Date().addingTimeInterval(300)
                        self.note("通话语音还差一步：\(final.summary)")
                    }
                }
            } catch {
                self.setOnMain {
                    self.voiceSetup = self.voiceProvision.inspect()
                    self.voiceSetupVerifiedAt = Date()
                    self.isRepairingVoice = false
                    self.voiceRepairing = false
                    self.voiceRepairStep = nil
                    self.voiceRepairNotBefore = Date().addingTimeInterval(300)
                    self.note("通话语音自动补装失败：\(error)")
                }
            }
        })
    }

    /// 通话开始：把桥架起来。
    ///
    /// 起桥要建两个 AudioUnit（两路采集、两路播放），在「刚接通」这一拍同步
    /// 做完会把面板卡住，所以丢到 `callAudioQueue` 上；那条队列是串行的，
    /// 「挂断」不会插到「接通」前面去。
    ///
    /// 前置条件没做完时**不报错**：拨号、接听、挂断、短信都是好的，缺的只是
    /// 语音。说清楚缺什么、去哪里补，别让客户以为整台设备坏了。
    private func startCallAudioBridge() {
        // 麦克风授权是这条链上唯一一件要客户点头的事，也是 2026-09-30 那通
        // 「接通 33 秒才出声」的全部原因：CoreAudio 起输入会停在这里等那个
        // 框，而框在人背后。装完就从没打开过面板的机器，到这一步才问得上，
        // 那就问 —— 弹一次框，总好过一整通电话对方听不见。
        askForMicrophoneIfNeeded(announceGranted: false)

        // 出图那一遍不起桥：桥一起来那一格就变成「通话中」＋两条电平，窗口
        // 跟着长高一截，而商品图要的是同一扇窗的同一张脸。
        guard !voiceSetupPinned else { return }
        guard !callVoiceLive else { return }
        guard !isInteractiveSim else {
            // 演示路径背后没有硬件，起桥只会报「找不到 AC Interface」。
            setOnMain { self.callVoiceLive = true }
            return
        }
        callStartAttempts += 1
        let attempt = callStartAttempts

        // 「体检 → 重挂 → 起桥」整件事排在同一条串行队列上：中间不能被挂断
        // 插队，而体检那两下（adb 子进程、AT 会话）也不能再挂住主线程 ——
        // 来电这一刻模块的 USB 正在重配，正是 adb 最慢、铃响卡片最不该卡的
        // 时候。
        // 包一层 `DispatchWorkItem`：`async` 收 `@Sendable` 闭包，而这具身体
        // 碰的全是主线程状态（同一个理由见 `setOnMain`）。
        Self.callAudioQueue.async(execute: DispatchWorkItem { [weak self] in
            guard let self else { return }

            // ★ 顺序是有讲究的：**先起重挂和桥，最后才体检**。
            //
            // 以前是「体检 → 重挂 → 起桥」，而体检最慢：它要起两个 adb 进程
            // （`adb devices` + `adb shell` 一整套 probe）外加一次 AT 往返。
            // 2026-09-28 那几通电话的日志把代价量出来了 —— 从「来电响铃」到
            // 「通话语音已接通」隔了 2.4 / 2.4 / 5.6 / 9.6 秒，客户拿起手机
            // 就接、一秒内开口，那几秒说的话模块这边压根没接到，听感上就是
            // 「接通了没有声音」，而且**挂断之后一切正常**，最难查的那一类。
            //
            // 现在排在前面的是两件真的能出声的事：把模块那边的语音通路重挂
            // 一次（一条 adb shell），再把桥架起来（纯 CoreAudio，几百毫秒）。
            // 体检挪到后面，它只影响界面上那句「就绪度」，晚一两秒没人受影响。
            //
            // ★ 重挂为什么每通都要做：「体检」只能证明 `alsaucm_test` 进程还在、
            // FIFO 还在，证明不了 `Voice Call` 这个 verb 还挂在模块的混音器上；
            // 模块在上一通结束、USB 重配之后都可能把那套状态收掉 —— 那一刻几个
            // 前置条件一条不差、界面写着「已就绪」，接起来就是一声没有，全程
            // 不报错。重挂的四条就是出厂序列本身，重复下发是幂等的。
            let rearmed = self.voiceProvision.rearmVoiceCall()

            do {
                try self.callBridge.start()
                self.setOnMain {
                    self.callVoiceLive = true
                    self.callSilentRetryDone = false
                    self.callRecoveryAttempts = 0
                    self.callActiveSince = nil
                    self.note(rearmed
                              ? "通话语音已接通（语音通路已重挂）"
                              : "通话语音已接通（麦克风 → 模块，模块 → 扬声器）")
                }
                self.startCallLevelTimer()
            } catch {
                // 桥起不来才是体检真正有用的时候：这时才值得花那几秒问清楚
                // 缺的是驱动、校准、声卡还是别的。
                let readiness = self.voiceProvision.inspect()
                self.setOnMain {
                    self.voiceSetup = readiness
                    self.voiceSetupVerifiedAt = Date()
                    self.note(readiness.ready
                              ? "通话语音接通失败：\(error)"
                              : "这通电话没有语音通路：\(readiness.summary)。"
                                + "挂断后在「通话」窗口点「一键安装」补上，补完再拨就有声音了")
                    guard self.call.state.isBusy,
                          attempt < Self.callStartAttemptsLimit else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, self.call.state.isBusy, !self.callVoiceLive else { return }
                        self.startCallAudioBridge()
                    }
                }
                return
            }

            // 桥起来了。体检照旧问一遍 —— 界面上的「就绪度」和那个「一键安装
            // 通话语音」的按钮都靠它，只是它不再挡在声音前面。
            let readiness = self.voiceProvision.inspect()
            self.setOnMain {
                self.voiceSetup = readiness
                self.voiceSetupVerifiedAt = Date()
                if !readiness.ready {
                    self.note("这通电话的语音通路不完整：\(readiness.summary)。"
                              + "挂断后在「通话」窗口点「一键安装」补上")
                }
            }
        })
    }

    /// 通话结束：拆掉。放在 `defer` 的义务上 —— 桥活着的时候模块那两个端点
    /// 一直被占着，不拆，下一次通话会从「设备忙」开始。
    private func stopCallAudioBridge() {
        callLevelTimer?.invalidate()
        callLevelTimer = nil
        callLevelTicks = 0
        callActiveSince = nil
        callSilentRetryDone = false
        callRecoveryInFlight = false
        Self.callAudioQueue.async(execute: DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 先取峰值再拆桥：`stop()` 会清电平，峰值虽然留着，但这个顺序
            // 读起来最不容易出错。
            let peaks = self.callBridge.peaks
            let seconds = self.callBridge.startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            // 延时那一行只进日志文件、不进活动列表：客户不需要看懂「每块
            // 44 毫秒」，但真收到「通话慢半拍」的反馈时，日志里得能看出来
            // 是块太大还是网络慢（见 `CallAudioBridge.latencyReport`）。
            AppLog.log("通话语音体检：\(self.callBridge.latencyReport)")
            self.callBridge.stop()
            self.setOnMain {
                self.callVoiceLive = false
                self.callLevels = CallAudioBridge.Levels()
                // 留一行能查的证据。两个峰值都是 0 = 这条通路一个采样点都没过
                // 声音，和「客户没说话」是两回事，隔着微信也能判断。
                self.note(String(format: "通话语音已断开（%d 秒，上行峰值 %.4f / 下行峰值 %.4f）",
                                 seconds, peaks.up, peaks.down))
            }
        })
    }

    /// 通话中每四分之一秒读一次两条链路的电平，给通话窗口上那两行表用。
    private func startCallLevelTimer() {
        setOnMain {
            self.callLevelTimer?.invalidate()
            self.callLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.callVoiceLive else { return }
                    self.callLevels = self.callBridge.refreshLevels()
                    self.logCallLevels()
                    // 桥自己发现设备掉了会收摊（`refreshLevels` 里那一段），
                    // 界面跟着熄灯，别留一行冻住的电平骗人。
                    if !self.callBridge.isRunning {
                        self.callVoiceLive = false
                        self.callLevels = CallAudioBridge.Levels()
                        self.callLevelTimer?.invalidate()
                        self.callLevelTimer = nil
                        // 通话还在就再架一次。客户手上只有「接通了没声音」这
                        // 一种感受，让他自己挂断重拨不算修好 —— 而这一档最
                        // 常见的成因（模块重配 USB 换了设备号）重建一次就自愈。
                        if self.call.state.isBusy {
                            let why = self.callBridge.lastProblem ?? "通路中断"
                            self.recoverCallAudio(reason: why, rearm: false)
                        }
                        return
                    }
                    self.watchCallAudio()
                }
            }
        }
    }

    /// 通话中每四分之一秒量一次：这一通到底有没有声音。
    ///
    /// 这一段是 2026-09-29 补的，因为「接通了没声音」以前只能等客户自己发现、
    /// 自己报，再自己挂断重拨 —— 而它多半是能自己修好的。判据在
    /// `CallAudioWatchdog` 里，抽成了纯函数，`--call-audio-check` 会把它跑一遍。
    private func watchCallAudio() {
        // 响铃 / 拨号那两段不判：那时对端本来就没声音，模块那头也还没把
        // 语音挂上来，拿那几秒的数据判只会误报。
        guard call.state == .active else {
            callActiveSince = nil
            return
        }
        if callActiveSince == nil { callActiveSince = Date() }
        let active = Date().timeIntervalSince(callActiveSince ?? Date())
        let verdict = CallAudioWatchdog.verdict(health: callBridge.health,
                                                activeSeconds: active,
                                                silentRetryDone: callSilentRetryDone)
        switch verdict {
        case .fine:
            return
        case .dead(let what):
            // 断的腿在模块那侧时，光重建 Mac 这一头没用：三个设备都还在，
            // 缺的是模块里那条通路（见 `needsModuleRearm`）。
            recoverCallAudio(reason: "\(what)没有数据",
                             rearm: CallAudioWatchdog.needsModuleRearm(deadLegs: what))
        case .oneWay(let which):
            // 客户在说话、模块整整八秒一个采样点都没给。修法和「两头都没
            // 声音」一样：重挂模块那侧的通路，再重接一次桥。
            //
            // 活动列表里的这句话是给客户看的：「下行」是判据里的说法，客户
            // 读到的该是他自己的感受 —— 他说的话对方听不见，或者他听不见
            // 对方。哪一头留给日志去分辨。
            let readable = which == "下行" ? "对方的声音一直没过来" : "声音一直没过来"
            if recoverCallAudio(reason: readable, rearm: true) {
                callSilentRetryDone = true
            }
        case .silent:
            // 两只耳朵都没声音 = 模块那侧的语音通路没挂上，光重建 Mac 这一头
            // 没用，所以这一档连带把通路重挂一次。
            //
            // 「已经为重挂修过」这个账**只在真的排上了才记**：另外一档的重接
            // 正在跑的时候，这一次会排不进去，那时记上账就等于把重挂这件事
            // 悄悄取消掉 —— 下一拍再试才对。每 0.25 秒一拍，所以这里也不能
            // 先把话写进日志：排不上就什么都不说。
            if recoverCallAudio(reason: "接通后一直没声音", rearm: true) {
                callSilentRetryDone = true
            }
        }
    }

    /// 通话中间把桥拆掉重接一次。
    ///
    /// 排在 `callAudioQueue` 上做：这一通的所有音频资源都在那条串行队列手里，
    /// 从主线程直接拆会和正在跑的起桥/挂断打架（`leg` 里的环形缓冲、`HAL`
    /// 单元都是在那里建的）。
    ///
    /// `rearm` 为真时顺带把模块那边的语音通路重挂一次 —— 「两头都没声音」
    /// 那一档的成因在模块那侧，不重挂就只是白重建一遍。重挂之后模块的端点
    /// 可能换号，所以重建要用新解析出来的设备。
    @discardableResult
    private func recoverCallAudio(reason: String, rearm: Bool) -> Bool {
        guard !voiceSetupPinned, !isInteractiveSim else { return false }
        guard call.state.isBusy else { return false }
        guard !callRecoveryInFlight else { return false }
        guard callRecoveryAttempts < Self.callRecoveryLimit else { return false }
        callRecoveryAttempts += 1
        callRecoveryInFlight = true
        note("通话语音断了（\(reason)），正在自动重接")

        Self.callAudioQueue.async(execute: DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.callBridge.stop()
            var rearmed = false
            if rearm { rearmed = self.voiceProvision.rearmVoiceCall() }
            do {
                try self.callBridge.start()
                self.setOnMain {
                    self.callVoiceLive = true
                    self.callRecoveryInFlight = false
                    // 刚接上这一下还没有一个采样点过过：判据的宽限期要从头
                    // 算，否则 0.25 秒之后的下一拍就会拿着「四个环节都没跑过」
                    // 的零记录当场判一次「断了」，把仅剩的那次机会白烧掉。
                    self.callActiveSince = nil
                    self.note(rearmed ? "通话语音已重接（语音通路已重挂）" : "通话语音已重接")
                }
                self.startCallLevelTimer()
            } catch {
                self.setOnMain {
                    self.callRecoveryInFlight = false
                    self.note("通话语音重接失败：\(error)")
                    // 再给一次机会：模块重配 USB 的那一两秒里端点会短暂找不到。
                    guard self.call.state.isBusy,
                          self.callRecoveryAttempts < Self.callRecoveryLimit else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, self.call.state.isBusy, !self.callVoiceLive else { return }
                        // 排下一拍时再数一次账：这次是「又排上了」，不是
                        // 「已经排上过一次」—— 返回值这里没人要，重试的次数
                        // 由 `callRecoveryAttempts` 自己数着。
                        self.recoverCallAudio(reason: reason, rearm: rearm)
                    }
                }
            }
        })
        return true
    }

    /// 通话中的电平日志：默认关，`DJI4G_VOICE_DEBUG=1` 时每 2 秒一行。
    /// 走的是活动列表那套 `note`，所以它同时进面板和 `~/Library/Logs/DJI4G/app.log`，
    /// 客户把诊断包发回来就能看到这一通有没有声音。
    private func logCallLevels() {
        guard ProcessInfo.processInfo.environment["DJI4G_VOICE_DEBUG"] == "1" else { return }
        callLevelTicks += 1
        guard callLevelTicks % 8 == 0 else { return }
        let levels = callLevels
        note(String(format: "通话电平：上行 %.3f / 下行 %.3f", levels.up, levels.down))
    }

    /// 从控制台发一条 USSD（查话费 / 查流量那一类）。
    ///
    /// 不走 `runAT`，两点不一样：答复是 `+CUSD` 这一条**上报**，命令本身只
    /// 回 OK，所以要有人接着读那一口（`waitForUSSD`）；发不出去的时候模块
    /// 回的是 `+CME ERROR: 30`，那串数字对客户没有意义，这里换成一句人话。
    func sendUSSD(_ code: String, completion: @escaping (String) -> Void) {
        run("USSD：\(code)") {
            let sentAt = Date()
            let response = try self.controller.sendUSSD(code)
            var text = ATFailure.explainUSSD(response.final) ?? response.final.text
            if response.isOK {
                if let reply = self.controller.waitForUSSD(since: sentAt, timeout: 20) {
                    text = reply.text.isEmpty ? "已结束" : reply.text
                    self.setOnMain { self.ussdResult = text }
                } else {
                    text = "已发给模块，暂时没等到答复。"
                }
            }
            self.setOnMain { completion(text) }
        }
    }

    func runAT(_ command: String, completion: @escaping (String) -> Void) {
        run("AT：\(command)") {
            let response = try self.controller.session.send(command, timeout: 8)
            let text = response.rawText.isEmpty ? response.final.text : response.rawText
            // 回显落在控制台那个 @State 上，同样只能在主线程写。
            self.setOnMain { completion(text) }
        }
    }

    /// Runs the read-back that arrived while the session was busy.
    ///
    /// Only after a job that worked. A read queued behind a failure would land
    /// second and wipe the red line explaining what just went wrong, so it is
    /// left pending and goes out after the next thing that works — the same
    /// rule that clears that line in the first place.
    private func fulfillPendingRead() {
        // 那通还在响的电话排在所有东西前面：数据开关晚一轮没人看得出来，
        // 一个正在响的电话晚一轮就是没接起来。它真发出去了就到此为止 ——
        // 让数据开关和回读跟在一通电话后面抢会话，只会被 `run` 挡回来。
        if pendingCallIntent != nil {
            flushPendingCallIntent()
            if isWorking { return }
        }
        // 客户的开关排在队首：读回来的数字晚一轮没人看得出来，开关晚一轮
        // 就是「按了没反应」。真去按下它以后会走一遍 `run`，pending 读还在
        // 原地等着，等它跑完再由这里发出去。
        if let wanted = pendingDataSwitch {
            pendingDataSwitch = nil
            setDataEnabled(wanted)
            return
        }
        guard readPending else { return }
        readPending = false
        refreshAll()
    }

    /// 后台 body 里读到的新状态，回到主线程再写回 `@Published`。
    ///
    /// `run` 的 body 跑在后台队列上，而 `voice` 这些 `@Published` 只能在主线程改。
    /// 2026-09-25 的崩溃报告就是这条：`AppModel.voice.setter` 在
    /// `closure #1 in AppModel.dial(_:)` 里 SIGSEGV（EXC_BAD_ACCESS at 0x20），
    /// 栈上全是 Combine 的发布者 —— 后台改 @Published 撞上主线程的 SwiftUI。
    private func refreshVoice() {
        let status = controller.voice.refreshStatus()
        setOnMain { self.voice = status }
    }

    /// 已经在主线程就立刻执行，否则跳回主线程。`run` 的 body 在后台队列上，
    /// 而它碰到的 `@State` / `@Published` 都只能在主线程写。
    private func setOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() }
        // `async(execute:)` 收的是 `@Sendable` 闭包，而这里传的是只能在主线程
        // 跑完的收尾动作（写 `@Published` / `@State`）。包一层 `DispatchWorkItem`
        // 语义完全一样，且不用逼每个调用方去满足 Sendable。
        else { DispatchQueue.main.async(execute: DispatchWorkItem(block: action)) }
    }

    /// Every action funnels through here so the UI can show one busy flag and
    /// surface a single readable error instead of a silent failure.
    ///
    /// Returns false when the action never ran. Callers that carry a completion
    /// handler have to answer for that case themselves.
    @discardableResult
    /// `completion` 在主线程上跑，参数是这一步成没成。数据开关拿它把乐观
    /// 翻过去的位置在失败时翻回来 —— `body` 跑在后台队列上，谁都不能从那里
    /// 直接改 `@Published`，所以这件事只能挂在 `run` 自己回主线程的这一刻。
    private func run(_ label: String,
                     completion: ((Bool) -> Void)? = nil,
                     _ body: @escaping () throws -> Void) -> Bool {
        // The module takes one command at a time, so a second action starting
        // now would interleave its AT traffic with the first. Refusing is
        // right; refusing *silently* is not. The button reads as broken, and
        // the compose sheet sat on 「发送中…」 for good because the completion
        // it was waiting on never ran. Every refusal now says so out loud.
        guard !isWorking else {
            lastError = "上一步操作还没结束，\(label) 没有执行，请稍候再试"
            return false
        }
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try body()
                DispatchQueue.main.async {
                    self.isWorking = false
                    // An error that outlives its cause is a lie the customer
                    // keeps reading: the card goes in, the next action works,
                    // and the panel still says 「未检测到 SIM 卡」 in red. The
                    // red line answers "what is wrong *now*"; the history is
                    // the activity log in 模块设置.
                    self.lastError = nil
                    self.note(label)
                    self.fulfillPendingRead()
                    completion?(true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isWorking = false
                    self.lastError = "\(label)失败：\(error)"
                    self.note("\(label)失败：\(error)")
                    completion?(false)
                }
            }
        }
        return true
    }
}

extension AppModel {
    var bars: Int { signal.bars }
    var dataUsedGB: Double { Double(monthBytes) / 1_000_000_000 }
    var remainingGB: Double? { quotaGB > 0 ? max(0, quotaGB - dataUsedGB) : nil }
    var remainingFraction: Double {
        guard quotaGB > 0 else { return Double(bars) / 5 }
        return max(0, min(1, (quotaGB - dataUsedGB) / quotaGB))
    }
    var signalCaption: String {
        if let rsrp = signal.rsrp { return String(format: "%.0f dBm", rsrp) }
        if let dBm = signal.rssiDBm { return "\(dBm) dBm" }
        return "--"
    }

    /// 模块**现在**报上来的身份；没连着就是 `nil`。
    ///
    /// `identity` 是「最后一次读到的」，断开的时候没人清它 —— 拔线、两个
    /// DJI4G 抢同一个 AT 口、`AT+CFUN=1,1` 之后重新枚举，都会把上一份值原样
    /// 留在内存里。而面板这时候正写着「模块未连接：把模块插到 Mac 的 USB 口」。
    /// 两句话同屏，温度、IMEI、存储这些数字就变成了没人担保时效的数字：客户
    /// 会照着「59 °C」判断模块烫不烫，而那时候模块根本不在电脑上。
    ///
    /// 所以展示层一律从这里取，不要直接读 `identity`。刚才亲手让模块重启的
    /// 那半分钟里也一样是 `nil` —— 那半分钟里模块确实什么也没报过。
    var liveIdentity: ModuleIdentity? { isConnected ? identity : nil }

    var temperatureLabel: String {
        // 温度是读数，不是设备属性：一个过期的读数比一个 `--` 更容易骗人。
        liveIdentity?.temperatures.first.map { "\($0)°C" } ?? "--"
    }
    var stateLine: String {
        if !isConnected {
            return Self.waitingLabel(awaitingReconnect: awaitingReconnect,
                                     attached: attachedIdentity != nil)
        }
        if !sim.ready { return "SIM \(sim.shortLabel)" }
        if !network.dataRegistered { return "未注册" }
        return network.carrier.shortName.isEmpty ? "在线" : network.carrier.shortName
    }
    /// 没连上时的三种说法。三种都没连上，但客户要做的事不一样：只有重启
    /// 窗口里那一句是他自己刚点出来的，等就行。
    nonisolated static func waitingLabel(awaitingReconnect: Bool, attached: Bool) -> String {
        if awaitingReconnect { return "模块重启中" }
        return attached ? "连接中" : "等待模块"
    }

    /// 卡还没插的时候，面板上该说的第二句话。
    ///
    /// 「未插卡」不是死路：USB 网卡和模块声卡这两项一次性设置跟卡没有关系，
    /// 现在就能写完 —— 而且应该现在写完。它们是写进模块的组态，生效要重启
    /// 一次模块；等卡插上、网也通了再改，重启就会把刚上线的网络掐一下。客
    /// 户拿着模块等卡的那几天，正是做这一步的时候。
    ///
    /// 两样都开好之后这句话自己消失。面板上不会自己消失的提示，客户读第三
    /// 遍以后就不读了 —— 那时它挡的就是真出问题的那条红字。
    ///
    /// 读不到组态时（`nil`）当作「不知道」，不当作「没开」：没把握的断言写
    /// 在面板上，是把客户支去点一个他本来不需要点的按钮。
    var preCardSetupNote: String? {
        guard isConnected, !sim.ready else { return nil }
        let needsAudio = data.composition.map { !$0.audio } ?? false
        let needsECM = data.usbnetMode.map { $0 != .ecm } ?? false
        guard needsAudio || needsECM else { return nil }
        // 2026-09-27：这句话原来把「模块声卡、USB 网卡」两个内部名字念给客户
        // 听，两行灰字。现在只留一句能照着做的短句 —— 是哪两样、为什么不用等
        // 卡，悬停在按钮上能看到。
        return "卡还没插也能先开好：设置 →「一键启用」"
    }

    var unreadCount: Int { messages.filter(\.isUnread).count }
}
