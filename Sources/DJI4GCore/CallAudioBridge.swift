import Foundation
import CoreAudio
import AudioToolbox

/// 通话音频桥。
///
/// 之前这个项目里的结论是「一代模块的通话语音不走 USB 声卡」，界面和文档
/// 都按那个写。2026-09-25 的真机测试把它推翻了：声卡在**不等于**通话有声音，
/// 模块固件默认根本不建 DSP 语音通路，得按顺序做完这五步，语音才会真的
/// 进出 `AC Interface` / `AS Interface`：
///
///   1. `AT+QADBKEY="…"` 解锁 ADB，再用 `AT+QCFG="usbcfg",…` 把 adb 位置 1，
///      `AT+CFUN=1,1` 重启 —— 没有 adb 就没有第 2 步的入口。
///   2. adb root 后 `insmod qdc507_aprv3.ko`、`insmod qdc507_voice.ko`
///      （固件里原本没有，`resources/ModuleVoice/` 随包发）。
///   3. 往 `/run/alsaucm_test` 写出厂语音校准序列，打开 Voice Call 通路：
///      `open snd_soc_msm_9x07_Tomtom_I2S` / `set _verb Voice Call` /
///      `set _enadev Auxpcm Rx` / `set _enadev Auxpcm Tx`。
///   4. 起 PCM 桥并 `audio_enable=1`。
///   5. 通话期间跑本类，把 Mac 麦克风和模块两个端点对接起来。
///
/// 1~4 步只做一次（重启模块要重做，见 `ModuleVoiceSetup`）。五步做完之后
/// 声卡上就有真实语音：
///
///   · 下行（对方 → Mac）录到连续 21 秒非零音频，峰值 0.52
///   · 上行（Mac → 对方）测试音对方明确听到
///
/// ★ 第 2、3 步必须用 `setsid` 脱离 adb 会话再执行。USB 在开 adb 之后会
/// 重枚举，跟着 adb 会话一起死的进程会把已经建好的通路一起带走。
///
/// 拓扑沿用 2026-09-12 浏览器里验过的那条（当时测试者反馈「两边都清楚」）：
///
///   Mac 麦克风 ──▶ AS Interface（模块输出，送到对端）
///   AC Interface（模块输入）──▶ Mac 扬声器
///
/// 两条链路各自独立，都直接绑到具体设备，**不动系统默认设备** —— 客户正在
/// 听的音乐、正在开的会不会被搬走，这是刻意的设计取舍。
///
/// 采样率：模块那两个端点都是 8000 Hz 单声道，Mac 内置是 44100 Hz 双声道，
/// 所以每个方向各挂一个 `AudioConverter`。声道数在回调里自己处理（上行把多
/// 声道下混成单声道，下行把单声道复制到每个声道），不交给转换器做映射 ——
/// 转换器的声道映射要求两端都提供 layout，缺一个就是
/// `kAudioConverterErr_...`，是个不值得踩的坑。
public final class CallAudioBridge {

    // MARK: - 对外状态

    public struct Endpoints {
        public let microphone: AudioDevice
        public let speaker: AudioDevice
        public let moduleInput: AudioDevice      // AC Interface，对端 → Mac
        public let moduleOutput: AudioDevice     // AS Interface，Mac → 对端
    }

    public enum BridgeError: Error, CustomStringConvertible {
        case missingDevice(String)
        case unitFailed(String, OSStatus)
        case converterFailed(String, OSStatus)

        public var description: String {
            switch self {
            case .missingDevice(let what): return "找不到\(what)"
            case .unitFailed(let what, let status): return "\(what) 初始化失败（\(status)）"
            case .converterFailed(let what, let status): return "\(what) 采样率转换器创建失败（\(status)）"
            }
        }
    }

    public struct Levels: Equatable {
        /// 上行：送进模块的麦克风电平（0…1）。
        public var up: Float = 0
        /// 下行：从模块收到的对方声音电平（0…1）。
        public var down: Float = 0

        /// 合成的 init 是 internal，App 里那格 `@Published var callLevels`
        /// 需要 public 的。
        public init() {}
    }

    /// 一条通路活着没有。数字全部按**这一通**算（`Leg.start()` 里清零）。
    ///
    /// 这四个计数是分辨「没接上」和「没人说话」的唯一依据：
    /// 回调一次都跑不起来 = 设备在位但一个采样点都没过，通路是断的；
    /// 回调在跑而峰值是 0 = 通路通着，只是这一段里两头都没出声。
    /// 两种情况的处置完全不同，不能都写成「没声音」。
    public struct Health: Equatable {
        public var uplinkInputCallbacks = 0
        public var uplinkOutputCallbacks = 0
        public var uplinkPeak: Float = 0
        public var downlinkInputCallbacks = 0
        public var downlinkOutputCallbacks = 0
        public var downlinkPeak: Float = 0
        /// 有一次播放回调的帧数超过了预留暂存区（按静音填了）。
        public var oversizedCallbacks = 0

        public init() {}

        /// 一次回调都没跑起来的那些环节，名字给人看。
        public var deadLegs: [String] {
            var names: [String] = []
            if uplinkInputCallbacks == 0 { names.append("麦克风采集") }
            if uplinkOutputCallbacks == 0 { names.append("模块放音") }
            if downlinkInputCallbacks == 0 { names.append("模块录音") }
            if downlinkOutputCallbacks == 0 { names.append("扬声器播放") }
            return names
        }
    }

    public private(set) var endpoints: Endpoints?
    public private(set) var levels = Levels()
    public private(set) var startedAt: Date?

    /// 上一次自动收摊的原因。**只有「被判定为通路坏了」才写**，客户自己
    /// 挂断那条路不写 —— 调用方要能靠它区分「这一通结束了」和「这一通
    /// 半路断了、通话还在」，后者才值得自动重接。
    public private(set) var lastProblem: String?

    /// 出错或设备掉线时回话（一直在音频线程之外调用）。
    public var onEvent: ((String) -> Void)?

    public var isRunning: Bool { running }

    private var running = false
    private let lock = NSLock()
    private let uplink = Leg()
    private let downlink = Leg()

    /// 通话时给**模块那块 USB 声卡**用的设备缓冲（帧）。
    ///
    /// 为什么要有这个数：这块声卡出厂 512 帧。一块音频有多大，说的话就要在
    /// 缓冲里躺多久才轮到被送出去 —— 通话里听出来就是「慢半拍」。客户
    /// 2026-09-30 反馈的延时就是它，和网络、和运营商都没关系（同一通电话
    /// 上行峰值 0.0055 / 下行 0.0000，通路是通的，只是慢）。
    ///
    /// 实测（`dji4gctl bridge`，30 秒，2026-09-30）：
    ///   · 512 帧（出厂）→ 上行每块 64.0 ms、下行每块 64.0 ms
    ///   · 256 帧        → 每块 32.0 ms
    ///   · 128 帧        → 每块 16.0 ms
    ///   ·  64 帧（默认）→ 每块  8.0 ms
    /// 128 帧往下，一块比「环形缓冲垫的那 20 毫秒」还小，放音设备每次来要
    /// 一块、缓冲里总是够 —— 补静音的**总量**不再变多，块越小铺得越匀。
    /// 再往下（32 帧 = 4 ms）驱动也受理，但回调次数翻倍、省下的 8 毫秒在
    /// 整通电话里听不出来，所以停在 64 帧。
    ///
    /// 只动模块的端点：Mac 的麦克风和扬声器同时被别的 App 用着，替客户的
    /// 播放器改缓冲不合适，那边的默认值本来也只有十几毫秒，不差这点。
    ///
    /// 排查时可以用环境变量现场改（客户界面上没有这一项，也不该有）。
    public static let moduleBufferFrames: UInt32 = {
        if let text = ProcessInfo.processInfo.environment["DJI4G_AUDIO_BUFFER"],
           let value = UInt32(text), value >= 3 {
            return value
        }
        return 64
    }()

    public init() {}

    // MARK: - 设备选择

    /// 挑出这一通电话要用的四个端点。
    ///
    /// Mac 侧取**当前系统默认**的输入输出 —— 客户插着耳机就用耳机，这是最
    /// 符合直觉的选择。只有一种情况例外：默认设备本身就是模块的端点（客户
    /// 之前手工切过，或者上一版界面把它留在了那儿），那种情况下继续用会把
    /// 对端的声音原样送回对端，所以退回内置设备。
    public static func resolveEndpoints() throws -> Endpoints {
        // 只认**按名字**匹配到的模块端点。这里不能用 `findModulePair()` 的
        // 兜底逻辑：那个兜底是「任意一个 USB 声卡」，在没有加载驱动、模块
        // 还没报声卡的时候，它会把摄像头的麦克风、iPhone 的连续互通麦克风
        // 之类的东西认成模块 —— 通话音频就送到那儿去了，而且界面上一切正常。
        let usb = AudioDevices.all().filter { $0.transport == "USB" && VoiceService.matchesModuleName($0) }
        guard let moduleInput = usb.first(where: { $0.hasInput }) else {
            throw BridgeError.missingDevice("模块的录音端点（AC Interface）")
        }
        guard let moduleOutput = usb.first(where: { $0.hasOutput }) else {
            throw BridgeError.missingDevice("模块的放音端点（AS Interface）")
        }

        let all = AudioDevices.all()
        let moduleIDs = Set([moduleInput.id, moduleOutput.id])

        // Mac 侧用**当前系统默认**的输入输出 —— 客户插着耳机就用耳机。
        // 唯一例外是默认设备本身就是模块端点（手工切过），那会把对端的声音
        // 原样送回对端，所以退回内置设备。
        func pick(_ id: AudioDeviceID?, wantsInput: Bool) -> AudioDevice? {
            guard let id, !moduleIDs.contains(id),
                  let device = all.first(where: { $0.id == id }) else { return nil }
            return wantsInput ? (device.hasInput ? device : nil) : (device.hasOutput ? device : nil)
        }

        var mic = pick(AudioDevices.defaultDevice(input: true), wantsInput: true)
        var speaker = pick(AudioDevices.defaultDevice(input: false), wantsInput: false)

        if mic == nil {
            mic = builtin(all, contains: ["built-in", "内置", "内建"], needsInput: true)
        }
        if speaker == nil {
            speaker = builtin(all, contains: ["built-in", "内置", "内建"], needsInput: false)
        }
        if mic == nil {
            mic = all.first { $0.hasInput && !moduleIDs.contains($0.id) }
        }
        if speaker == nil {
            speaker = all.first { $0.hasOutput && !moduleIDs.contains($0.id) }
        }

        guard let microphone = mic else { throw BridgeError.missingDevice("Mac 的麦克风") }
        guard let speakerDevice = speaker else { throw BridgeError.missingDevice("Mac 的扬声器") }

        return Endpoints(microphone: microphone, speaker: speakerDevice,
                         moduleInput: moduleInput, moduleOutput: moduleOutput)
    }

    private static func builtin(_ all: [AudioDevice], contains needles: [String], needsInput: Bool) -> AudioDevice? {
        all.first { device in
            let name = device.name.lowercased()
            guard needles.contains(where: { name.contains($0) }) else { return false }
            return needsInput ? device.hasInput : device.hasOutput
        }
    }

    // MARK: - 起停

    public func start() throws {
        guard !running else { return }
        let endpoints = try Self.resolveEndpoints()
        self.endpoints = endpoints

        do {
            try uplink.start(source: endpoints.microphone, sink: endpoints.moduleOutput)
            try downlink.start(source: endpoints.moduleInput, sink: endpoints.speaker)
        } catch {
            uplink.stop()
            downlink.stop()
            throw error
        }

        lock.lock()
        running = true
        startedAt = Date()
        lastProblem = nil
        lock.unlock()
        onEvent?("通话音频已接通：麦克风 → 模块，模块 → 扬声器")
    }

    public func stop() {
        guard running || endpoints != nil else { return }
        uplink.stop()
        downlink.stop()
        lock.lock()
        running = false
        levels = Levels()
        lock.unlock()
        onEvent?("通话音频已断开")
    }

    /// 整通电话的峰值。挂断之后仍然有效（`stop()` 不清它），所以通话结束
    /// 那一行日志里能写上「这一通到底有没有过声音」，不用让客户再复现一次。
    public var peaks: Levels {
        var both = Levels()
        both.up = uplink.peak
        both.down = downlink.peak
        return both
    }

    /// 给命令行和日志用的诊断快照。
    public var diagnostics: String {
        func describe(_ name: String, _ leg: Leg) -> String {
            let block = leg.blockReport
            var text = "  \(name)：采集回调 \(leg.inputCallbacks) 次 / \(leg.inputFrames) 帧"
                + "（每块 \(Self.ms(block.inputAvg)) ms，最多 \(Self.ms(block.inputMax)) ms），"
                + "转换后 \(leg.producedFrames) 帧，播放回调 \(leg.outputCallbacks) 次"
                + " / \(leg.outputFrames) 帧（每块 \(Self.ms(block.outputAvg)) ms，"
                + "最多 \(Self.ms(block.outputMax)) ms）"
            let ring = leg.ringReport
            text += "，缓冲里排着 \(Self.ms(ring.shallowestMs))…\(Self.ms(ring.deepestMs)) ms"
            if let skew = leg.startupSkewMilliseconds {
                text += "，起跑错位 \(Self.ms(skew)) ms"
            }
            if leg.starvedCallbacks > 0 {
                text += "，补给静音 \(leg.starvedCallbacks) 次"
            }
            text += "，峰值 \(String(format: "%.4f", leg.peak))"
            return text
        }
        return describe("上行", uplink) + "\n" + describe("下行", downlink)
            + "\n  " + latencyReport
    }

    /// 一行话的延时体检：每块音频多少毫秒、模块声卡缓冲多少帧。
    ///
    /// 块的大小和延时是同一件事 —— 模块那块声卡默认 512 帧，交到 App 手里
    /// 却是 2822 帧一块（353 毫秒）。这一行就是拿来量化它的：改之前多少、
    /// 改之后多少，摆在一起看。
    public var latencyReport: String {
        let up = uplink.blockReport
        let down = downlink.blockReport
        var text = "每块音频：上行 麦克风 \(Self.ms(up.inputAvg)) ms → 模块 "
            + "\(Self.ms(up.outputMax)) ms，下行 模块 \(Self.ms(down.inputMax)) ms"
            + " → 扬声器 \(Self.ms(down.outputAvg)) ms"
        if let frames = uplink.sinkBufferFrames ?? downlink.sourceBufferFrames {
            text += "；模块声卡缓冲 \(frames) 帧"
        }
        let upRing = uplink.ringReport
        let downRing = downlink.ringReport
        text += "；我们这层排着 \(Self.ms(max(upRing.deepestMs, downRing.deepestMs))) ms"
        let trimmed = uplink.trimmedMilliseconds + downlink.trimmedMilliseconds
        let silent = uplink.silentMilliseconds + downlink.silentMilliseconds
        let played = Double(uplink.outputFrames + downlink.outputFrames)
        if trimmed > 0.05 || silent > 0.05 {
            let rate = played > 0 ? silent / played * 100 : 0
            text += "；重排丢 \(Self.ms(trimmed)) ms，补静音 \(Self.ms(silent)) ms"
                + "（占 \(String(format: "%.2f", rate))%）"
        }
        if uplink.starvedCallbacks + downlink.starvedCallbacks > 0 {
            text += "，补给静音 \(uplink.starvedCallbacks + downlink.starvedCallbacks) 次"
        }
        return text
    }

    /// 两条腿此刻的环形缓冲深度（毫秒）—— 我们这一层眼下排着多少音频。
    /// 走势比绝对值重要：一路往上说明攒起来了，通话会越讲越慢。
    public var ringDepthMilliseconds: (up: Double, down: Double) {
        return (uplink.ringDepthMilliseconds, downlink.ringDepthMilliseconds)
    }

    private static func ms(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// 这一通的体检数字。给「接通了却没有声音」那条自动重接的路用。
    public var health: Health {
        var snapshot = Health()
        snapshot.uplinkInputCallbacks = uplink.inputCallbacks
        snapshot.uplinkOutputCallbacks = uplink.outputCallbacks
        snapshot.uplinkPeak = uplink.peak
        snapshot.downlinkInputCallbacks = downlink.inputCallbacks
        snapshot.downlinkOutputCallbacks = downlink.outputCallbacks
        snapshot.downlinkPeak = downlink.peak
        snapshot.oversizedCallbacks = uplink.oversizedCallbacks + downlink.oversizedCallbacks
        return snapshot
    }

    public func refreshLevels() -> Levels {
        guard running else { return Levels() }
        var fresh = Levels()
        fresh.up = uplink.currentLevel
        fresh.down = downlink.currentLevel
        lock.lock()
        levels = fresh
        lock.unlock()

        if let why = stoppingReason() {
            lastProblem = why
            onEvent?("通话音频中断：\(why)")
            stop()
        }
        return levels
    }

    /// 这一通该不该判死。返回原因；`nil` 表示还好。
    private func stoppingReason() -> String? {
        if uplink.failed || downlink.failed {
            return uplink.failureText ?? downlink.failureText ?? "音频设备已断开"
        }
        // 绑着的那四台设备还在不在系统里。
        //
        // 模块在通话开始/结束时会重配一次 USB，重配之后 `AudioObjectID` 换号，
        // 旧号成了一个不存在的对象 —— 读它任何属性都失败。而 AUHAL 那边对此
        // **一声不吭**：不报错，只是从此不再回调，电平恒为 0.000，界面上一切
        // 正常。这就是「接通后没有声音」最常见的形状，所以这里主动查一次。
        guard let endpoints else { return nil }
        let bound: [(String, AudioDevice)] = [("Mac 的麦克风", endpoints.microphone),
                                              ("Mac 的扬声器", endpoints.speaker),
                                              ("模块的录音端点", endpoints.moduleInput),
                                              ("模块的放音端点", endpoints.moduleOutput)]
        for (label, device) in bound where device.nominalSampleRate == nil {
            return "\(label)已经不在系统里了"
        }
        return nil
    }

    // MARK: - 一条链路

    /// 一条单向链路：源设备采集 → 重采样 → 环形缓冲 → 目标设备播放。
    private final class Leg {
        private let ring = PCMRing(capacity: 32_000)
        private var input: HALInput?
        private var output: HALOutput?
        private var converter: AudioConverterBridge?
        private var source: AudioDevice?
        private var sink: AudioDevice?
        private var level: Float = 0
        /// 诊断计数：哪一步没数据，一眼能看出来。
        private(set) var inputCallbacks = 0
        private(set) var inputFrames = 0
        private(set) var producedFrames = 0
        private(set) var outputCallbacks = 0
        private(set) var outputFrames = 0
        /// 一次回调里最多给过 / 要过多少帧。**这个数就是延时**：一块 353
        /// 毫秒的声音，从进缓冲到放完，最少也得等自己这一块播完。以前日志
        /// 里只有「回调多少次」，块有多大看不出来，所以「延时」这件事根本
        /// 没数据可查（2026-09-30 补的）。
        private(set) var inputBlockMax = 0
        private(set) var outputBlockMax = 0
        /// 播放回调来取数据时环形缓冲是空的（这块按静音补了）。客户听到的
        /// 「一顿一顿」就是它，块调小之后最值得盯的就是这个数。
        private(set) var starvedCallbacks = 0
        /// 起桥之后模块端点实际生效的设备缓冲（帧）。Mac 侧不动，那边是 nil。
        private(set) var sourceBufferFrames: UInt32?
        private(set) var sinkBufferFrames: UInt32?
        private(set) var peak: Float = 0
        private(set) var failed = false
        private(set) var failureText: String?

        /// 采集回调的暂存区。回调跑在实时线程上，不能在里面分配内存 ——
        /// 包括「不够了就再要一块大的」：那条路 `malloc` 一样拿锁。
        private var mono: [Float] = []
        private var monoCapacity = 0
        /// 采集回调一次要的帧数超过暂存区时，只处理得下的这一段（少几个
        /// 采样点听不出来），次数记进体检里。
        private var converted: [Float] = []

        /// 播放回调的暂存区。同上，一次分好、反复用（见 `produce`）。
        private var playScratch: UnsafeMutablePointer<Float>?
        private var playCapacity = 0
        private(set) var oversizedCallbacks = 0

        /// 环形缓冲要维持的目标深度（帧，按放音设备的采样率算）。
        private var trimTargetFrames = 0
        private var trimHighWaterFrames = 0
        private var trimCapFrames = 0
        /// 这一通里为了把深度拉回目标值丢掉了多少帧，以及补了多少帧静音。
        /// 两个数都该是「小到可以忽略」：大了就说明目标深度不合适。
        private(set) var trimmedFrames = 0
        private(set) var silentFrames = 0
        /// 正在把起跑垫底削回目标值（削完要把深度统计清零，见 `produce`）。
        private var trimming = false

        /// 两边第一块回调各自什么时候来的。起跑错位（生产者先跑、消费者后跑
        /// 的那一百来毫秒）就是它把缓冲垫起来的 —— 见 `start` 里的起跑顺序。
        private var firstIngestAt: Date?
        private var firstProduceAt: Date?

        var currentLevel: Float { level }

        deinit {
            playScratch?.deallocate()
        }

        func start(source: AudioDevice, sink: AudioDevice) throws {
            self.source = source
            self.sink = sink
            failed = false
            failureText = nil
            ring.reset()

            // 计数器和峰值一律按「这一通」算。跨通累加会出两种错，2026-09-29
            // 两个都踩到了：
            //   · 第一通出过声，后面几通即使一声没有，日志里也照抄同一个峰值
            //     —— 连续四通写着四个一模一样的 0.2686/0.7202，从这行字里
            //     根本看不出哪一通真的没声音（这个峰值是**累加过的最大值**）；
            //   · 「这一通一个采样点都没过」这个判据（见 `Health`）会被上一通
            //     的数字顶掉，永远不成立。
            inputCallbacks = 0
            inputFrames = 0
            producedFrames = 0
            outputCallbacks = 0
            outputFrames = 0
            inputBlockMax = 0
            outputBlockMax = 0
            starvedCallbacks = 0
            sourceBufferFrames = nil
            sinkBufferFrames = nil
            oversizedCallbacks = 0
            firstIngestAt = nil
            firstProduceAt = nil
            peak = 0
            trimmedFrames = 0
            silentFrames = 0
            trimming = false

            let sourceRate = source.nominalSampleRate ?? 44_100
            let sinkRate = sink.nominalSampleRate ?? 8_000

            // 环形缓冲要垫的目标深度。**放音设备一次要多少，缓冲里就得先有
            // 多少**，不然那一次回调的尾巴只能是静音 —— 听感上就是「卡一下」。
            // 两条腿最坏的情况都是「一次要 11.6 ms、对面一块只送 8 ms」，两头
            // 错开的那一下要垫住 ≈ 20 ms；24 还是 20 对人耳没差别，但缓冲浅了
            // 就会一直补静音（实测浅到 16 ms 时，24 秒里补了 319 次）。上限
            // 32 ms，多出来的由 `produce` 削掉，一次最多削 5 ms。
            trimTargetFrames = Int(sinkRate * 0.020)
            trimHighWaterFrames = Int(sinkRate * 0.032)
            trimCapFrames = max(Int(sinkRate / 200), 8)

            // 客户端格式的声道数必须跟**设备本身**一致。少声明一个声道，
            // AUHAL 不会报错，只会安静地给回零 —— 麦克风是双声道而这里写
            // 单声道时，上行电平就永远是 0.000（2026-09-25 踩到）。
            // 声道数的合并/复制在下游自己做，转换器始终是单声道对单声道。
            let capturedChannels = UInt32(max(source.inputChannelCount, 1))
            let playedChannels = UInt32(max(sink.outputChannelCount, 1))
            let captured = AudioStreamBasicDescription.float32(rate: sourceRate, channels: capturedChannels)
            let played = AudioStreamBasicDescription.float32(rate: sinkRate, channels: playedChannels)

            let inputUnit = try HALInput(device: source, clientFormat: captured) { [weak self] buffer, frames in
                self?.ingest(buffer, frames)
            }
            let outputUnit = try HALOutput(device: sink, clientFormat: played) { [weak self] buffer, frames in
                self?.produce(buffer, frames)
            }

            // 暂存区按「一次回调最多 4096 帧、按比例放大」预留，之后只在
            // 回调里复用，不再分配内存。
            let ratio = sinkRate / sourceRate
            let convertedCapacity = max(Int(ceil(4096 * ratio)) + 1024, 4096)
            monoCapacity = 8192
            mono = [Float](repeating: 0, count: monoCapacity)
            converted = [Float](repeating: 0, count: convertedCapacity)

            // 播放回调里不能分配内存（`malloc` 会拿锁，拿锁的那一下就是一次
            // 爆音）。原先每回调分配一次 `[Float]`，44.1 kHz 那条链一秒八十
            // 多次 —— 机器一忙就是断断续续的杂音，听感上跟「没声音」是一回事。
            if playScratch == nil {
                playCapacity = 8192
                playScratch = UnsafeMutablePointer<Float>.allocate(capacity: playCapacity)
                playScratch?.initialize(repeating: 0, count: playCapacity)
            }

            // 转换器一律建**单声道对单声道**（见下面 AudioConverterBridge
            // 注释）：多声道而且是「非交错」时，转换器按约定要求输入、输出各
            // 给够「声道数」个缓冲区，我们只给一个，它不报错，只是安静地返回
            // 0 帧 —— 两个方向都断，电平恒为 0.000（2026-09-25 踩到）。
            // 下混在 ingest 里做，复制到各声道在 produce 里做，转换器只管变采样率。
            let converter = try AudioConverterBridge(
                input: .float32(rate: sourceRate, channels: 1),
                output: .float32(rate: sinkRate, channels: 1))
            self.converter = converter
            input = inputUnit
            output = outputUnit

            inputUnit.onFailure = { [weak self] text in self?.fail(text) }
            outputUnit.onFailure = { [weak self] text in self?.fail(text) }

            // ★ 起跑顺序：先录音，**等缓冲垫到目标深度再放音**。垫多少是定死
            // 的，不靠设备起跑那一下的运气。
            //
            // 反过来（先放音）的毛病是反的：缓冲一直是空的，放音设备每次来要
            // 一块、缓冲里只躺着半块，尾巴只能补静音 —— 实测 14 秒里补了 286
            // 次，听感是「沙沙的、一顿一顿」。
            //
            // 以前是「先录音、不等」，那更糟：放音设备要过一百来毫秒才吐第一
            // 块，录音这段时间灌进去多少就垫多少 —— 2026-09-30 实测接通第 1 秒
            // 缓冲里排着 98 / 99 毫秒，而且两个设备的时钟只差千分之几，这层垫
            // 底要靠它慢慢淌，一通电话打完都淌不干净，客户听到的就是**整通电话
            // 都慢半拍**。多出来的那一段现在由 `produce` 削回去（`trimmedFrames`）。
            try inputUnit.start()
            primeRing(deadline: 0.25)
            do { try outputUnit.start() } catch { inputUnit.stop(); throw error }

            // 实际生效的缓冲帧数（只有模块那两个端点会被调，见
            // `moduleBufferFrames` 上面那段）。写进体检里：设没设上、驱动
            // 认了多少，从日志里一眼能看出来，不用再猜。
            sourceBufferFrames = inputUnit.appliedBufferFrames
            sinkBufferFrames = outputUnit.appliedBufferFrames
        }

        /// 等环形缓冲垫到目标深度。录音设备起跑本身要几十毫秒，所以是轮询
        /// 而不是睡固定时长；等不到（设备起不来）也照常往下走，不会卡住通话。
        private func primeRing(deadline seconds: Double) {
            guard trimTargetFrames > 0 else { return }
            let until = Date().addingTimeInterval(seconds)
            while ring.depth < trimTargetFrames, Date() < until {
                Thread.sleep(forTimeInterval: 0.002)
            }
        }

        func stop() {
            output?.stop()
            input?.stop()
            output = nil
            input = nil
            converter = nil
            level = 0
            ring.reset()
        }

        private func fail(_ text: String) {
            failed = true
            failureText = text
        }

        /// 采集回调：多声道下混成单声道，重采样，推进环形缓冲。
        private func ingest(_ buffer: UnsafeMutableAudioBufferListPointer, _ frames: Int) {
            guard frames > 0 else { return }
            inputCallbacks += 1
            inputFrames += frames
            if firstIngestAt == nil { firstIngestAt = Date() }
            if frames > inputBlockMax { inputBlockMax = frames }
            // 暂存区是起桥时一次分好的，这里**一次内存都不分配**（见字段上
            // 的注释）。真遇上比 8192 帧还大的回调，就只处理放得下的那一段
            // ——宁可掐掉几毫秒的尾巴，也不能在实时线程上拿锁。
            let usable = min(frames, monoCapacity)
            if usable < frames { oversizedCallbacks += 1 }
            guard usable > 0 else { return }

            // 下混：把所有声道求和取平均。麦克风通常只有一个声道有信号，
            // 直接取 0 号在某些 USB 麦克风上会拿到一整个静音声道。
            let channels = buffer.count
            if channels == 0 { return }
            let first = buffer[0]
            guard let base = first.mData?.assumingMemoryBound(to: Float.self) else { return }
            if channels == 1 {
                mono.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress?.update(from: base, count: usable)
                }
            } else {
                mono.withUnsafeMutableBufferPointer { dst in
                    guard let out = dst.baseAddress else { return }
                    for i in 0..<usable { out[i] = base[i] }
                    for channel in buffer.dropFirst() {
                        guard let data = channel.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        for i in 0..<usable { out[i] += data[i] }
                    }
                    let scale = 1.0 / Float(channels)
                    for i in 0..<usable { out[i] *= scale }
                }
            }

            guard let converter else { return }
            let produced = mono.withUnsafeMutableBufferPointer { src -> Int in
                converted.withUnsafeMutableBufferPointer { dst -> Int in
                    converter.convert(input: src.baseAddress!, inputFrames: usable,
                                      output: dst.baseAddress!, outputCapacity: dst.count)
                }
            }
            guard produced > 0 else { return }
            producedFrames += produced
            converted.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                ring.write(base, produced)
            }
            let rms = Self.rms(converted, produced)
            level = rms
            if rms > peak { peak = rms }
        }

        /// 播放回调：从环形缓冲取，不够就补静音。
        private func produce(_ buffer: UnsafeMutableAudioBufferListPointer, _ frames: Int) {
            guard frames > 0 else { return }
            outputCallbacks += 1
            outputFrames += frames
            if firstProduceAt == nil { firstProduceAt = Date() }
            if frames > outputBlockMax { outputBlockMax = frames }

            guard let scratch = playScratch, frames <= playCapacity else {
                // 一次回调要的帧数超过预留。以前这种情况会整条链静音而且说不
                // 出原因，现在按静音填、把次数记进体检里（`Health` 会报出来）。
                oversizedCallbacks += 1
                for channel in 0..<buffer.count {
                    guard let data = buffer[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<frames { data[i] = 0 }
                    buffer[channel].mDataByteSize = UInt32(frames * 4)
                }
                return
            }

            // 缓冲深过目标就从**最旧的**那头削掉一小段。垫着的深度就是延时，
            // 让它一直待在一二十毫秒：两个设备的时钟差（实测千分之几）会让
            // 深度慢慢往上爬，不削的话一通电话会越讲越慢。
            let excess = ring.depth - trimHighWaterFrames
            if excess > 0 {
                // 一次削多少：超出得多就削得快（起跑垫的那一百来毫秒要在一秒
                // 内拉回来），快到目标时一次只削一两帧 —— 削掉的每一帧都是一
                // 个断口，宁可多削几次小口，也别削一大口（那是一声「咔」）。
                var step = min(excess / 4, trimCapFrames)
                if step < 1 { step = 1 }
                if step > excess { step = excess }
                trimmedFrames += ring.skip(step)
                trimming = true
            } else if trimming {
                // 起跑垫底削回目标之后，深度统计从这一刻重新算：日志里
                // 「缓冲里排着 0.0…127.7 ms」的那个 127.7 就是起跑那一下，
                // 挂在稳定之后的读数里只会误导人。
                ring.resetStats()
                trimming = false
            }

            // 缓冲里不够就补静音：宁可让客户听见一小段空白，也不能把上一轮
            // 留在暂存区里的旧采样当成新声音播出去（那是回声）。
            let got = ring.read(into: scratch, frames)
            if got < frames {
                // 环形缓冲空了：这一块剩下的时间只能是静音。客户听到的
                // 「一顿一顿」就是它，次数单记一份，好判断块调小之后有没有
                // 把声音调破。
                starvedCallbacks += 1
                silentFrames += frames - got
                for i in got..<frames { scratch[i] = 0 }
            }
            for channel in 0..<buffer.count {
                guard let data = buffer[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                data.update(from: scratch, count: frames)
                buffer[channel].mDataByteSize = UInt32(frames * 4)
            }
        }

        /// 丢样、补静音各多少毫秒（都按放音设备的采样率算）。
        private func sinkMilliseconds(_ frames: Int) -> Double {
            Double(frames) / max(sink?.nominalSampleRate ?? 1, 1) * 1000
        }
        var trimmedMilliseconds: Double { sinkMilliseconds(trimmedFrames) }
        var silentMilliseconds: Double { sinkMilliseconds(silentFrames) }

        /// 起跑错位：生产者第一块比消费者第一块早多少毫秒。正数就是「录音
        /// 先跑、放音后跑」，这个数有多大，缓冲里就白垫多少毫秒。
        var startupSkewMilliseconds: Double? {
            guard let firstIngestAt, let firstProduceAt else { return nil }
            return firstProduceAt.timeIntervalSince(firstIngestAt) * 1000
        }

        static func rms(_ samples: [Float], _ count: Int) -> Float {
            guard count > 0 else { return 0 }
            var sum: Float = 0
            for i in 0..<count { sum += samples[i] * samples[i] }
            return (sum / Float(count)).squareRoot()
        }

        /// 每块音频的毫秒数。`max` 是这一通里最大的一块 —— **通话延时的下限
        /// 就是它**：一块音频从进缓冲到放完，怎么都得等自己这一块播完。
        var blockReport: (inputAvg: Double, inputMax: Double,
                          outputAvg: Double, outputMax: Double) {
            // 帧数是按客户端格式算的，而客户端格式的采样率就是设备自己的
            // 采样率（见 `start` 里的 `captured` / `played`），所以直接换算。
            let inRate = max(source?.nominalSampleRate ?? 1, 1)
            let outRate = max(sink?.nominalSampleRate ?? 1, 1)
            func ms(_ frames: Int, _ rate: Double) -> Double {
                Double(frames) / rate * 1000
            }
            return (inputCallbacks > 0 ? ms(inputFrames / inputCallbacks, inRate) : 0,
                    ms(inputBlockMax, inRate),
                    outputCallbacks > 0 ? ms(outputFrames / outputCallbacks, outRate) : 0,
                    ms(outputBlockMax, outRate))
        }

        /// 这一刻环形缓冲里排着多少毫秒（我们这一层眼下的延时）。
        var ringDepthMilliseconds: Double {
            let outRate = max(sink?.nominalSampleRate ?? 1, 1)
            return Double(ring.depth) / outRate * 1000
        }

        /// 环形缓冲排得最深、最浅多少毫秒 —— 这是**我们这一层**加的延时，
        /// 和声卡缓冲是两回事。深到几十毫秒说明数据攒起来了（延时跟着长），
        /// 浅到 0 说明供不上（那几帧按静音补了）。
        var ringReport: (shallowestMs: Double, deepestMs: Double) {
            let outRate = max(sink?.nominalSampleRate ?? 1, 1)
            func ms(_ frames: Int) -> Double { Double(frames) / outRate * 1000 }
            return (ring.shallowest == Int.max ? 0 : ms(ring.shallowest), ms(ring.deepest))
        }
    }
}

// MARK: - 环形缓冲

/// 单生产者单消费者的浮点环形缓冲。读写各持一把锁 —— 实时线程上
/// `NSLock` 短临界区是可接受的，比无锁实现少一个出错的地方。
final class PCMRing {
    private var storage: [Float]
    private var readIndex = 0
    private var filled = 0
    private let lock = NSLock()
    /// 这一通里缓冲最深、最浅排到过多少帧。**深度就是延时**：排着 800 帧
    /// 的 8 kHz 音频，等于这一刻的声音要等 100 毫秒才播得出去。以前只有
    /// 「回调多少次」，谁也说不清我们这一层到底垫了多久（2026-09-30 加）。
    private(set) var deepest = 0
    private(set) var shallowest = Int.max

    init(capacity: Int) {
        storage = [Float](repeating: 0, count: max(capacity, 1024))
    }

    func reset() {
        lock.lock()
        readIndex = 0
        filled = 0
        deepest = 0
        shallowest = Int.max
        lock.unlock()
    }

    /// 把「最深/最浅排到过多少」从这一帧重新算。
    func resetStats() {
        lock.lock()
        deepest = filled
        shallowest = filled
        lock.unlock()
    }

    var depth: Int {
        lock.lock()
        defer { lock.unlock() }
        return filled
    }

    func write(_ samples: UnsafePointer<Float>, _ count: Int) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        var remaining = count
        var offset = 0
        while remaining > 0 {
            let writeIndex = (readIndex + filled) % storage.count
            let chunk = min(remaining, storage.count - writeIndex)
            for i in 0..<chunk { storage[writeIndex + i] = samples[offset + i] }
            let overflow = max(0, filled + chunk - storage.count)
            filled = min(storage.count, filled + chunk) - overflow
            if overflow > 0 { readIndex = (readIndex + overflow) % storage.count }
            offset += chunk
            remaining -= chunk
        }
        if filled > deepest { deepest = filled }
    }

    /// 从**最旧**的一头丢掉若干帧（放音侧用来把缓冲深度拉回目标值）。
    /// 丢的是已经过时的声音，这样深度降下来、客户听到的又是最新的那一块。
    @discardableResult
    func skip(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        let dropped = min(count, filled)
        readIndex = (readIndex + dropped) % storage.count
        filled -= dropped
        return dropped
    }

    func read(into destination: UnsafeMutablePointer<Float>, _ count: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let take = min(count, filled)
        var offset = 0
        var remaining = take
        while remaining > 0 {
            let chunk = min(remaining, storage.count - readIndex)
            for i in 0..<chunk { destination[offset + i] = storage[readIndex + i] }
            readIndex = (readIndex + chunk) % storage.count
            offset += chunk
            remaining -= chunk
        }
        filled -= take
        if filled < shallowest { shallowest = filled }
        return take
    }
}

// MARK: - 设备缓冲

/// 把**模块那块 USB 声卡**的缓冲调小，返回实际生效的帧数。别的设备返回 nil。
///
/// ★ 为什么要动它：这块声卡出厂 512 帧，但它交到 App 手里的却是 2822 帧
/// 一块 —— 353 毫秒（2026-09-30 实测，比例正好 44100 / 8000）。353 毫秒一块
/// 的意思就是：麦克风里说的话，先在缓冲里躺 353 毫秒才轮到被送进模块。
/// 通话里听出来就是「慢半拍」。设成 64 帧之后每块 44 毫秒。
///
/// ★ 为什么只动模块：Mac 的麦克风、扬声器同时被别的 App 用着（音乐、会议），
/// 替客户的播放器改缓冲不合适；那两边的默认值本来也只有十几毫秒。
///
/// 调完一定**读回来看**：驱动有自己的允许范围，可能不受理、也可能给我们
/// 另一个值。日志里写的是读回来的那个数，不是我们要的那个数。
@discardableResult
private func applyModuleBufferSize(_ device: AudioDevice) -> UInt32? {
    guard VoiceService.matchesModuleName(device) else { return nil }
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyBufferFrameSize,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var frames: UInt32 = 0
    guard AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &frames) == noErr else {
        return nil
    }
    var wanted = CallAudioBridge.moduleBufferFrames
    if frames != wanted,
       AudioObjectSetPropertyData(device.id, &address, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &wanted) == noErr {
        _ = AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &frames)
    }
    return frames
}

// MARK: - AUHAL 输入

/// 单个设备的采集单元（HALOutput 组件、只开输入方向）。
///
/// **采集回调里必须自己调 `AudioUnitRender` 取数据。** 回调给的 `ioData` 是
/// 空的，直接读它只会得到一片静音，而且不报错 —— 第一版就是这么写的，诊断
/// 计数显示「采集回调 0 次」，其实是回调在跑、只是从没往里写东西。
/// 2026-09-25 跟着 `/tmp/vt/vt.swift` 里已经验证可用的录音实现改了过来。
final class HALInput {
    private var unit: AudioUnit?
    private let device: AudioDevice
    private let clientFormat: AudioStreamBasicDescription
    private let handler: (UnsafeMutableAudioBufferListPointer, Int) -> Void
    private let channels: Int
    /// 每声道最大帧数。回调里不能分配内存，所以这块是启动时一次分配好的。
    private let maxFrames = 8192
    private var scratch: UnsafeMutablePointer<Float>?
    private var list: UnsafeMutableAudioBufferListPointer?
    /// 起桥之后模块端点实际生效的设备缓冲（帧）。Mac 侧不动，那边是 nil。
    private(set) var appliedBufferFrames: UInt32?
    var onFailure: ((String) -> Void)?

    init(device: AudioDevice,
         clientFormat: AudioStreamBasicDescription,
         handler: @escaping (UnsafeMutableAudioBufferListPointer, Int) -> Void) throws {
        self.device = device
        self.clientFormat = clientFormat
        self.handler = handler
        channels = max(Int(clientFormat.mChannelsPerFrame), 1)

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CallAudioBridge.BridgeError.missingDevice("HAL 音频组件")
        }
        var newUnit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &newUnit)
        guard status == noErr, let created = newUnit else {
            throw CallAudioBridge.BridgeError.unitFailed("采集单元 \(device.name)", status)
        }
        unit = created

        let total = maxFrames * channels
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: total)
        buffer.initialize(repeating: 0, count: total)
        scratch = buffer
        list = AudioBufferList.allocate(maximumBuffers: channels)

        configure()
    }

    private func configure() {
        guard let unit else { return }
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        var identifier = device.id
        // 打开输入方向、关掉输出方向：这个单元只用来采集。
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, 4)
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, 4)
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &identifier, 4)
        var format = clientFormat
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                             &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var callback = AURenderCallbackStruct(
            inputProc: { reference, flags, timestamp, bus, frames, _ in
                let this = Unmanaged<HALInput>.fromOpaque(reference).takeUnretainedValue()
                this.receive(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                             &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    }

    private func receive(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                         timestamp: UnsafePointer<AudioTimeStamp>,
                         bus: UInt32,
                         frames: UInt32) {
        guard let unit, let scratch, let list else { return }
        let frameCount = Int(frames)
        guard frameCount > 0, frameCount <= maxFrames else { return }

        // 每个声道一个 buffer（非交错），各自指向暂存区里属于它的那一段。
        for channel in 0..<channels {
            list[channel] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(scratch + channel * maxFrames))
        }

        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, list.unsafeMutablePointer)
        guard status == noErr else {
            onFailure?("采集 \(device.name) 失败（\(status)）")
            return
        }
        handler(list, frameCount)
    }

    func start() throws {
        guard let unit else { return }
        let initialized = AudioUnitInitialize(unit)
        guard initialized == noErr else {
            throw CallAudioBridge.BridgeError.unitFailed("采集单元 \(device.name)", initialized)
        }
        // 初始化之后调一次
        appliedBufferFrames = applyModuleBufferSize(device)
        let started = AudioOutputUnitStart(unit)
        guard started == noErr else {
            AudioUnitUninitialize(unit)
            throw CallAudioBridge.BridgeError.unitFailed("启动采集 \(device.name)", started)
        }
        // 起跑之后再调一次：驱动会在「开始跑」这一步把值弹回默认，只有这时候
        // 设的才是跑起来之后生效的那个（见 `applyModuleBufferSize`）。
        appliedBufferFrames = applyModuleBufferSize(device) ?? appliedBufferFrames
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    deinit {
        stop()
        if let scratch { scratch.deallocate() }
        list = nil
    }
}

// MARK: - AUHAL 输出

/// 单个设备的播放单元（HALOutput 组件、只开输出方向）。
final class HALOutput {
    private var unit: AudioUnit?
    private let device: AudioDevice
    private let clientFormat: AudioStreamBasicDescription
    private let filler: (UnsafeMutableAudioBufferListPointer, Int) -> Void
    /// 起桥之后模块端点实际生效的设备缓冲（帧）。Mac 侧不动，那边是 nil。
    private(set) var appliedBufferFrames: UInt32?
    var onFailure: ((String) -> Void)?

    init(device: AudioDevice,
         clientFormat: AudioStreamBasicDescription,
         filler: @escaping (UnsafeMutableAudioBufferListPointer, Int) -> Void) throws {
        self.device = device
        self.clientFormat = clientFormat
        self.filler = filler

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CallAudioBridge.BridgeError.missingDevice("HAL 音频组件")
        }
        var newUnit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &newUnit)
        guard status == noErr, let created = newUnit else {
            throw CallAudioBridge.BridgeError.unitFailed("放音单元 \(device.name)", status)
        }
        unit = created
        configure()
    }

    private func configure() {
        guard let unit else { return }
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        var identifier = device.id
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, 4)
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disable, 4)
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &identifier, 4)
        var format = clientFormat
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                             &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var callback = AURenderCallbackStruct(
            inputProc: { reference, _, _, _, frames, data in
                guard let data else { return noErr }
                let this = Unmanaged<HALOutput>.fromOpaque(reference).takeUnretainedValue()
                this.fill(frames: frames, data: data)
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                             &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    }

    private func fill(frames: UInt32, data: UnsafeMutablePointer<AudioBufferList>) {
        filler(UnsafeMutableAudioBufferListPointer(data), Int(frames))
    }

    func start() throws {
        guard let unit else { return }
        let initialized = AudioUnitInitialize(unit)
        guard initialized == noErr else {
            throw CallAudioBridge.BridgeError.unitFailed("放音单元 \(device.name)", initialized)
        }
        // 初始化之后调一次
        appliedBufferFrames = applyModuleBufferSize(device)
        let started = AudioOutputUnitStart(unit)
        guard started == noErr else {
            AudioUnitUninitialize(unit)
            throw CallAudioBridge.BridgeError.unitFailed("启动放音 \(device.name)", started)
        }
        // 起跑之后再调一次（同 `HALInput.start`）。
        appliedBufferFrames = applyModuleBufferSize(device) ?? appliedBufferFrames
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    deinit { stop() }
}

// MARK: - 采样率转换

/// `AudioConverter` 的薄封装：把定长的一块输入换成一块输出。
///
/// ★ 只用来做**单声道对单声道**的采样率转换。交错/多声道的转换请绕道：
/// 非交错格式下，转换器要求输入回调和输出缓冲区各按「声道数」提供多个
/// 缓冲区，数量对不上时不报错、只返回 0 帧，从电平上看就是「全零、没声音」，
/// 极难排查。声道合并与复制由调用方在 HAL 回调里自己做完再用这个类。
final class AudioConverterBridge {
    private var converter: AudioConverterRef?
    private let outputCapacity: Int
    /// 输出采样率 ÷ 输入采样率。请求多少输出帧必须按它算 —— 见 `convert`。
    private let ratio: Double

    init(input: AudioStreamBasicDescription, output: AudioStreamBasicDescription) throws {
        var source = input
        var destination = output
        var created: AudioConverterRef?
        let status = AudioConverterNew(&source, &destination, &created)
        guard status == noErr, let converter = created else {
            throw CallAudioBridge.BridgeError.converterFailed("\(input.mSampleRate)→\(output.mSampleRate)", status)
        }
        self.converter = converter
        ratio = output.mSampleRate / max(input.mSampleRate, 1)
        outputCapacity = Int(ceil(16_384 * ratio)) + 2048
    }

    /// 返回真正写进 `output` 的帧数。
    ///
    /// 这里的请求帧数**必须**按输入帧数等比算出来。第一版写的是「要满整个
    /// 输出缓冲区」，结果转换器发现输入不够，就按约定用静音补到请求的帧数
    /// —— 返回值看着一切正常，缓冲区里 98% 是补出来的静音，电平被稀释几十
    /// 倍，「上行 0.000」而麦克风其实有信号。
    ///
    /// 少于应有帧数时（取整损耗）由转换器内部自己缓冲，下一次调用补上，
    /// 所以这里向下取整是安全的。
    func convert(input: UnsafePointer<Float>, inputFrames: Int,
                 output: UnsafeMutablePointer<Float>, outputCapacity capacity: Int) -> Int {
        guard let converter, inputFrames > 0 else { return 0 }

        var context = InputContext(samples: input, frames: inputFrames, served: false)
        let wanted = Int(Double(inputFrames) * ratio)
        let target = min(capacity, outputCapacity, max(wanted, 1))
        guard target > 0 else { return 0 }

        var outputList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1,
                                  mDataByteSize: UInt32(target * MemoryLayout<Float>.size),
                                  mData: UnsafeMutableRawPointer(output)))
        var requested = UInt32(target)

        // 回调的参数顺序是（转换器、包数指针、缓冲区指针、包描述指针、用户数据）：
        // 第二个是 inNumberDataPackets，第三个才是 ioData —— 别按名字猜。
        let status = withUnsafeMutablePointer(to: &context) { pointer -> OSStatus in
            AudioConverterFillComplexBuffer(converter, { _, packetCount, data, _, userData -> OSStatus in
                guard let userData else {
                    packetCount.pointee = 0
                    return noErr
                }
                let context = userData.assumingMemoryBound(to: InputContext.self)
                guard !context.pointee.served else {
                    packetCount.pointee = 0
                    return noErr
                }
                context.pointee.served = true
                let list = UnsafeMutableAudioBufferListPointer(data)
                guard list.count > 0,
                      let destination = list[0].mData?.assumingMemoryBound(to: Float.self) else {
                    packetCount.pointee = 0
                    return noErr
                }
                let count = context.pointee.frames
                destination.update(from: context.pointee.samples, count: count)
                list[0].mDataByteSize = UInt32(count * MemoryLayout<Float>.size)
                packetCount.pointee = UInt32(count)
                return noErr
            }, pointer, &requested, &outputList, nil)
        }
        guard status == noErr else { return 0 }
        // `requested` 在调用后被改写成真正产出的包数（PCM 里包就是帧）。
        let frames = min(Int(requested), target)
        outputList.mBuffers.mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
        return frames
    }

    private struct InputContext {
        let samples: UnsafePointer<Float>
        let frames: Int
        var served: Bool
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }
}

// MARK: - 描述符工具

extension AudioStreamBasicDescription {
    /// 32 位浮点、打包、非交错。AUHAL 的客户端格式用这个最省事。
    static func float32(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0)
    }
}

extension AudioDevice {
    /// 设备的输入/输出声道数。AUHAL 的客户端格式要按这个来声明。
    public var inputChannelCount: Int {
        AudioDevices.channelCount(id, scope: kAudioObjectPropertyScopeInput)
    }

    public var outputChannelCount: Int {
        AudioDevices.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
    }

    public var nominalSampleRate: Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { return nil }
        return rate
    }
}

// MARK: - 通话中的判据

/// 「这一通有没有出声」的判据。
///
/// 抽成纯函数是有原因的：它决定要不要在客户通话中间动手重建通路，判错一次
/// 就是「好好的通话被打断」。纯函数才能在 `--call-audio-check` 里把每一种
/// 边界都跑一遍，而不是等真机上出问题再猜。
public enum CallAudioWatchdog {

    /// 通话进入「通话中」之后，至少看这么久再判「没接上」。
    ///
    /// 响铃那一段不判：那时对端本来就没声音，模块那头也还没把语音挂上来，
    /// 拿那几秒的数据判只会误报。
    public static let stallGrace: TimeInterval = 3
    /// 两头都 0 要连续看这么久才判「通路没挂上」。
    ///
    /// 比「没接上」宽，因为「没人说话」是正常状态：通话刚接起来、两个人
    /// 都还没开口的头几秒，两个峰值本来就是 0。
    public static let silenceGrace: TimeInterval = 4
    /// 「一个方向有声、另一个方向一个采样点都没有」要连续看这么久才判。
    ///
    /// 比另外两个都长：这一档的成因在模块那侧，修一次要重挂通路、重接桥，
    /// 打断的是一通**已经在说话**的电话。宁可晚两秒。
    public static let oneWayGrace: TimeInterval = 8

    /// 「这一头确实有声」的门槛。客户正常说话时上行轻松越过 0.05，取 0.02 ——
    /// 只听得见话筒底噪的那种安静不算「有人说话」。
    public static let audibleFloor: Float = 0.02

    /// 「那一头一个采样点都没有」的天花板。
    ///
    /// 不写成「等于 0」：这条 USB 通路活着的时候，即使对端一声不出，过来的
    /// 底噪也在 0.002 上下（2026-09-30 01:51 那通实测 0.0026）。低过这个数
    /// 就是真的一整个采样点都没过来。
    public static let deadSilenceCeiling: Float = 0.001

    public enum Verdict: Equatable {
        /// 没事，别动。
        case fine
        /// 通路断了：设备在位却一个采样点都没过。要拆掉重接。
        case dead(String)
        /// 通路通着、但两头一声没有：多半是模块那边的语音通路没挂上。
        /// 要重挂一次再重接。
        case silent
        /// 只坏了一半：客户在说话（上行有声），而模块整整八秒没送过来一个
        /// 采样点。参数里是哪一头。
        case oneWay(String)
    }

    /// 断掉的腿里有模块那一侧的吗。
    ///
    /// 有，就得连模块一起重挂。那三个设备好端端地挂在系统里，缺的是模块里
    /// 那条语音通路 —— 把桥拆了重建，解析到的还是同一批设备、还是同一条没
    /// 挂上的通路，白折腾一通。
    public static func needsModuleRearm(deadLegs: String) -> Bool {
        deadLegs.contains("模块")
    }

    /// - Parameters:
    ///   - health: `CallAudioBridge.health`（按这一通算的数字）。
    ///   - activeSeconds: 通话进入「通话中」之后过了多久。
    ///   - silentRetryDone: 这一通是不是已经为重挂重接过一次了（「两头都没
    ///     声音」和「只有一头有声」共用这一笔账）。这一档每通只修一次 —— 修
    ///     不好说明不是这条路能修的，反复拆只会把一通好电话拆坏。
    public static func verdict(health: CallAudioBridge.Health,
                               activeSeconds: TimeInterval,
                               silentRetryDone: Bool) -> Verdict {
        guard activeSeconds >= stallGrace else { return .fine }
        let dead = health.deadLegs
        if !dead.isEmpty { return .dead(dead.joined(separator: "、")) }
        guard activeSeconds >= silenceGrace else { return .fine }
        if health.uplinkPeak == 0, health.downlinkPeak == 0, !silentRetryDone {
            return .silent
        }
        // 「两头都 0」那一档管不到只坏一半的通路，而只坏一半恰恰是最难被发现
        // 的：好的一头一直有声音，电平表看着是活的，坏的那一头却是整整一通
        // 里一个采样点都没有。
        //
        // 2026-09-30 01:17 那通 48 秒的电话就是这样 —— 上行峰值 0.2245、下行
        // 0.0000，而当时的判据每一拍都给「没事」，客户那边全程一声没有。
        //
        // 只认「上行有声、下行没有」这一个方向。反过来（对方在说、我方还没
        // 开口）是每一通电话里最正常的一半，判它等于把好电话拆掉。
        guard activeSeconds >= oneWayGrace else { return .fine }
        if !silentRetryDone,
           health.uplinkPeak >= audibleFloor,
           health.downlinkPeak <= deadSilenceCeiling {
            return .oneWay("下行")
        }
        return .fine
    }
}
