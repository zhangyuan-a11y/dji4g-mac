import Foundation

/// 模块语音通路的一键安装与体检。
///
/// 通话要有声音，模块上必须同时满足五件事（`CallAudioBridge` 的注释里有完整
/// 背景）。这里负责把它们做成客户点一下就能完成的过程，并且**可重复执行**：
/// 已经做过的步骤跳过，只补没做的。
///
///   adb 能连上  →  厂商两个驱动已加载  →  出厂语音校准已下发
///              →  PCM 桥在跑  →  `audio_enable=1`  →  声卡出现
///
/// 为什么必须走 ADB：模块固件里**没有**这两个驱动，也不建 DSP 语音通路，
/// 而打开它的唯一入口是模块上的 shell。所以这不是「调试用的后门」，是功能
/// 本身的一部分 —— 除非哪天模块刷成自带语音驱动的固件，否则省不掉。
///
/// 几个刻意的取舍：
///
///   · ADB 用**独立端口**（默认 5039）。客户机上很可能已经装了 platform-tools
///     给自己别的设备用，抢占 5037 会把人家正在调试的东西踢掉。
///   · 装完**不关** adb。关掉会触发 USB 重枚举，刚建好的声卡和桥会一起没；
///     而且远程排查也要靠它。
///   · usbcfg 只翻 **adb 那一位**，其余（VID/PID、diag、nmea、at、modem、
///     net、audio）原样保留。客户手里可能是改过 VID/PID 的模块，整个字符串
///     覆盖会把那些改动抹掉。
///   · 一律用 `setsid` 起后台进程。跟着 adb 会话一起死的进程会被 USB 重枚举
///     带走，表现是「装完是好的，过一会儿又没了」。
public final class ModuleVoiceSetup {

    // MARK: - 状态

    /// 五个前置条件各自成不成立。`issues` 里是给人看的原因。
    public struct Status: Equatable {
        /// adb 可执行文件的位置，找不到就是 nil。
        public var adbBinary: String?
        /// adb 能看到模块（设备列表里有它）。
        public var moduleReachable = false
        /// `usbcfg` 里 adb 位是 1。**只说明开关扳了**，不代表 adb 就能用 ——
        /// 还要交过口令（见 `raiseADB`），两件都成立 `adb devices` 才有东西。
        /// 这两件事分开记，界面才能把「模块没插」和「只差解锁」说清楚。
        public var adbUnlocked = false
        /// 厂商两个 .ko 都在 `/proc/modules` 里。
        public var driversLoaded = false
        /// `alsaucm_test` 在跑、FIFO 在（出厂语音校准已下发）。
        public var calibrated = false
        /// PCM 桥进程在跑。
        public var bridgeRunning = false
        /// `/sys/class/android_usb/f_audio/audio_enable` 是 1。
        public var audioEnabled = false
        /// `/proc/asound/cards` 里有声卡。
        public var soundCardPresent = false

        public var issues: [String] = []
        /// 步骤标签，给界面显示「做到哪一步了」。
        public var steps: [String] = []

        /// 显式写一个 public init：合成的那个是 internal，跨模块（App 里那格
        /// `@Published var voiceSetup`）就用不了。
        public init() {}

        /// 通话能不能有声音，看这个。
        public var ready: Bool {
            driversLoaded && calibrated && bridgeRunning && audioEnabled && soundCardPresent
        }

        /// 两个字的短标签，给卡片上那一格用（`summary` 太长，塞不进 Field）。
        ///
        /// 这七种状态底下是三件不同的事：没插好、还差一次「一键安装」、
        /// 装好了只等声卡。客户看得懂的是这三件，不是驱动和桥的名字。
        public var shortLabel: String {
            if ready { return "已就绪" }
            if adbBinary == nil { return "缺少组件" }
            // 位是 1 却连不上，说明就差口令那一步（或者模块要再插拔一次），
            // 这两种客户要做的事完全不同，别都写成「未连接」。
            if !moduleReachable { return adbUnlocked ? "待重启" : "未连接" }
            if !adbUnlocked { return "未安装" }
            if !driversLoaded { return "未安装" }
            if !calibrated { return "未安装" }
            if !bridgeRunning { return "未安装" }
            if !audioEnabled { return "声卡未开" }
            return "声卡未开"
        }

        /// 一句话总结，给面板上的那行小字用。
        public var summary: String {
            if ready { return "通话语音已就绪" }
            if adbBinary == nil { return "通话语音组件没装全，重装一次这个软件" }
            if !moduleReachable {
                return adbUnlocked
                    ? "模块在，但还没准备好（拔插一次或点「一键安装」）"
                    : "没看到模块，检查线有没有插好"
            }
            if !adbUnlocked { return "还没装过通话语音（会重启模块一次）" }
            if !driversLoaded { return "通话语音还没装好" }
            if !calibrated { return "通话语音还没装好" }
            if !bridgeRunning { return "通话语音还没装好" }
            if !audioEnabled { return "通话语音好了，只差打开声卡" }
            return "通话语音好了，只差打开声卡"
        }

        /// 技术版总结。只给折叠起来的控制台用 —— 客户看不到这里。
        public var technicalSummary: String {
            if ready { return "通话语音已就绪" }
            if adbBinary == nil { return "缺少 adb 组件" }
            if !moduleReachable {
                return adbUnlocked
                    ? "模块在，但 ADB 还没放出来（解锁一次即可）"
                    : "模块未通过 ADB 连接"
            }
            if !adbUnlocked { return "需要先解锁 ADB（会重启模块）" }
            if !driversLoaded { return "需要加载厂商语音驱动" }
            if !calibrated { return "需要下发语音校准" }
            if !bridgeRunning { return "需要启动 PCM 桥" }
            if !audioEnabled { return "需要打开 audio_enable" }
            return "需要声卡就绪"
        }
    }

    public enum SetupError: Error, CustomStringConvertible {
        case adbMissing
        case adbFailed(String, String)
        case moduleNotReachable(String)
        case atRequired
        case challengeUnreadable(String)
        case challengeRejected(String)
        case unlockRejected(String)
        case usbcfgUnreadable(String)
        case usbcfgRejected(String)
        case pushFailed(String)
        case insmodFailed(String, String)
        case calibrateFailed(String)
        case bridgeFailed(String)
        case resourceMissing(String)

        public var description: String {
            switch self {
            case .adbMissing:
                return "这个安装包里少了通话语音组件，重新解压一遍再装。"
            case .adbFailed(let what, let detail):
                return "装入通话语音时出错（\(what)）：\(detail)"
            case .moduleNotReachable(let detail):
                return "没连上模块：\(detail)"
            case .atRequired:
                return "模块没连上，把模块插好再试一次"
            case .challengeUnreadable(let detail):
                return "没读到模块的身份信息：\(detail)"
            case .challengeRejected(let detail):
                return "模块回的身份信息不对：\(detail)"
            case .unlockRejected(let detail):
                return "模块没接受这次准备：\(detail)"
            case .usbcfgUnreadable(let detail):
                return "没读到模块的设置：\(detail)"
            case .usbcfgRejected(let detail):
                return "模块没接受这次设置：\(detail)"
            case .pushFailed(let detail):
                return "往模块装文件失败：\(detail)"
            case .insmodFailed(let name, let detail):
                return "语音组件没装进去（\(name)）：\(detail)"
            case .calibrateFailed(let detail):
                return "语音校准没通过：\(detail)"
            case .bridgeFailed(let detail):
                return "语音通道没起来：\(detail)"
            case .resourceMissing(let name):
                return "安装包缺少 \(name)"
            }
        }
    }

    /// 每一步的进展，给界面显示。
    public enum Progress: Equatable {
        case step(String)
        case done(String)
    }

    // MARK: - 依赖

    private let session: ATSession?
    private let adb: ADBRunner
    private let resources: URL?

    /// - Parameters:
    ///   - session: AT 会话。解锁那两步必须走它（`AT+QADBKEY`、`AT+QCFG`）；
    ///     nil 时只能做「检查」和「加载驱动」，不能解锁。
    ///   - resources: 放 `qdc507_*.ko`、`mavo-pcm-bridge.armv7`、`manifest.json`
    ///     的目录。传 nil 就按 app 的布局自己找。
    public init(session: ATSession?, resources: URL? = nil) {
        self.session = session
        self.adb = ADBRunner()
        self.resources = resources ?? Self.defaultResourceDirectory()
    }

    /// app 里放模块资源的地方：`Contents/Resources/ModuleVoice/`。
    public static func defaultResourceDirectory() -> URL? {
        // 开发/调试时指向源码树里的 resources/ModuleVoice，省得先打一个 app。
        if let explicit = ProcessInfo.processInfo.environment["DJI4G_MODULE_VOICE"],
           !explicit.isEmpty,
           FileManager.default.fileExists(atPath: "\(explicit)/manifest.json") {
            return URL(fileURLWithPath: explicit)
        }
        for dir in AppResources.searchDirectories() {
            let candidate = dir.appendingPathComponent("ModuleVoice")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
                return candidate
            }
        }
        // 裸二进制（`./.build/debug/dji4gctl ...`、以及交付包里摊在
        // Contents/Resources/ 的那一份）从可执行文件往上找源码树里的
        // `resources/ModuleVoice`。只在这里找，不并进
        // `AppResources.searchDirectories()`：那里明确不要「app 的上一级
        // 目录」，否则 /Applications 里一个放错位置的文件就能骗过体检。
        if let executable = Bundle.main.executableURL {
            var dir = executable.deletingLastPathComponent()
            for _ in 0..<6 {
                let candidate = dir.appendingPathComponent("resources/ModuleVoice")
                if FileManager.default.fileExists(
                    atPath: candidate.appendingPathComponent("manifest.json").path) {
                    return candidate
                }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        // 也允许塞进 SwiftPM 资源包
        for dir in AppResources.searchDirectories() {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for entry in entries where entry.pathExtension == "bundle" {
                let candidate = entry.appendingPathComponent("ModuleVoice")
                if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
                    return candidate
                }
            }
        }
        return nil
    }

    // MARK: - 体检

    /// 把当前状态量一遍。不改模块上的任何东西 —— 界面随时可以调。
    public func inspect() -> Status {
        var status = Status()
        status.adbBinary = adb.binary

        guard adb.binary != nil else {
            status.issues.append("找不到 adb")
            status.steps.append("缺 adb")
            return status
        }

        guard let devices = try? adb.run(["devices"]), devices.contains("\tdevice") else {
            // adb 连不上不等于模块不在：USB 上它可能好好的，只是还没解锁。
            // 这里再问一次 AT 通道的 adb 位，界面才能把「只差解锁」和「模块
            // 没插」分开说 —— 这两种情况客户要做的事完全不同。
            if let session,
               let line = try? session.send("AT+QCFG=\"usbcfg\"").firstValue(for: "+QCFG"),
               let bit = Self.adbBit(inUsbcfg: line) {
                status.adbUnlocked = bit == 1
            }
            status.issues.append("ADB 里看不到模块（adb devices 没有 device 行）")
            status.steps.append("等 adb 连上模块")
            return status
        }
        status.moduleReachable = true
        status.steps.append("adb 已连上模块")

        let output = try? adb.shell(Self.probe)
        guard let output else {
            status.issues.append("adb shell 没响应")
            status.steps.append("adb shell 无响应")
            return status
        }

        if ProcessInfo.processInfo.environment["DJI4G_VOICE_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("[[probe]]\n\(output)\n[[/probe]]\n".utf8))
        }

        let counts = parse(probe: output)
        status.driversLoaded = counts.aprv3 > 0 && counts.voice > 0
        status.audioEnabled = counts.audioEnable == "1"
        status.soundCardPresent = counts.cards > 0
        status.bridgeRunning = counts.bridge > 0
        status.calibrated = counts.alsaucm > 0 && counts.fifo

        // usbcfg 的 adb 位要另外问 AT 通道，adb 自己看不出来。没有 AT 会话时
        // 退一步按「adb 连得上」推断：adbd 是被这一位放出来的，它在线就说明
        // 这一位是 1。这样命令行单独跑体检也不会误报「未解锁」。
        if let session, let line = try? session.send("AT+QCFG=\"usbcfg\"").firstValue(for: "+QCFG"),
           let bit = Self.adbBit(inUsbcfg: line) {
            status.adbUnlocked = bit == 1
        } else {
            status.adbUnlocked = status.moduleReachable
        }

        if !status.driversLoaded { status.issues.append("厂商语音驱动未加载") ; status.steps.append("加载厂商驱动") }
        if !status.calibrated { status.issues.append("语音校准未下发") ; status.steps.append("下发语音校准") }
        if !status.bridgeRunning { status.issues.append("PCM 桥未启动") ; status.steps.append("启动 PCM 桥") }
        if !status.audioEnabled { status.issues.append("audio_enable 未打开") ; status.steps.append("打开 audio_enable") }
        if !status.soundCardPresent { status.issues.append("声卡未出现") ; status.steps.append("等声卡出现") }
        if status.ready { status.steps.append("全部就绪") }
        return status
    }

    // MARK: - 安装

    /// 把五步补齐到全部成立。已经成立的步骤会跳过，重复跑是安全的。
    ///
    /// `adb devices` 里没有模块时必须提供 `session`：解锁那一步走 AT，而且
    /// 可能要 `AT+CFUN=1,1` 重启模块 —— 重启后本方法会等 ADB 重新连上，
    /// 调用方不需要自己重连。
    @discardableResult
    public func install(progress: ((Progress) -> Void)? = nil) throws -> Status {
        guard adb.binary != nil else { throw SetupError.adbMissing }
        let report: (String) -> Void = { progress?(.step($0)) }

        // 0) 型号门禁：下面推的 .ko 是一代 QDC507 专属组件，
        //    在动手改任何设置之前先确认接进来的就是它。
        guard let session else { throw SetupError.atRequired }
        try ModuleIdentityGate.requireGenerationOne(session)

        // 1) 解锁 ADB —— 没解锁后面一步都做不了。
        if !adbAppears(within: 0) {
            report("第 1 步 · 准备模块")
            try raiseADB(report: report)
        }
        progress?(.done("第 1 步 好了"))

        // 2) 把资源推上去并加载驱动。
        var status = inspect()
        if !status.driversLoaded {
            report("第 2 步 · 装入通话语音")
            // 内核门禁：qdc507_*.ko 只在 3.18.44 线上验证过，
            // 其他内核（包括二代）一律拒绝，绝不能靠“试试看”。
            let kernel = ((try? adb.shell("uname -r", timeout: 15)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard ModuleGate.voiceKernelSupported(kernel) else {
                throw ModuleGateError.unsupportedKernel(kernel: kernel)
            }
            try pushResources()
            try loadDrivers()
        }
        progress?(.done("第 2 步 好了"))

        // 3) 出厂语音校准。桥在跑的话先停掉 —— 桥占着语音通路时 alsaucm_test
        //    起不来，会卡死在初始化里（详见 stopBridge）。第 4 步会把它起回来。
        status = inspect()
        if !status.calibrated {
            if status.bridgeRunning {
                report("第 3 步 · 正在校准")
                stopBridge()
                Thread.sleep(forTimeInterval: 1)
            }
            report("第 3 步 · 正在校准")
            try calibrate()
        }
        progress?(.done("第 3 步 好了"))

        // 4) PCM 桥 + audio_enable。
        status = inspect()
        if !status.bridgeRunning || !status.audioEnabled {
            report("第 4 步 · 打开语音通道")
            try startBridge()
        }
        progress?(.done("第 4 步 好了"))

        // 5) 等声卡出现，然后收尾量一次。
        report("第 5 步 · 等声卡出现")
        try waitForSoundCard(timeout: 20)
        let final = inspect()
        progress?(.done(final.summary))
        return final
    }

    // MARK: - 复原

    /// 复原时清掉了什么。给 `dji4gctl restore` 报告用 —— 客户看见的每一行
    /// 都得是真做过的，不能是「我以为我清了」。
    public struct RestoreReport {
        /// 模块上被删掉的文件（全路径）。
        public var removedFiles: [String] = []
        /// 被停掉的常驻进程。
        public var stoppedProcesses: [String] = []
        /// 被卸掉的内核模块。
        public var unloadedModules: [String] = []
        /// 没做成的理由（`nil` 表示真的连上模块做过了）。
        public var skippedReason: String?

        public init() {}
    }

    /// 把**模块里**由本工具留下的东西撤掉。不刷机、不动模块的系统、不动卡里
    /// 的东西，也不碰 `usbcfg` / `usbnet` —— 那两条走 AT，由 `dji4gctl restore`
    /// 负责，这里只管 shell 这一侧：
    ///
    ///   · 停掉 PCM 桥和语音校准守护。重启本来也会没，但先停掉能立刻把声卡和
    ///     语音通路放掉，不用等一次断电。
    ///   · 卸掉两个厂商驱动，同上。
    ///   · 删掉推进 `/data/local/tmp` 的三个文件 —— **这是唯一重启也不会自己
    ///     消失的留痕**，所以必须主动清。顺手把 `/var/tmp` 里的日志和校准
    ///     留下的 FIFO 一起带走。
    ///
    /// ADB 连不上就跳过、不抛错：没装过通话语音的模块本来就没有这些东西，而
    /// 复原流程不该因为「本来就没什么可清」而报失败。
    @discardableResult
    public func removeStagedFiles() -> RestoreReport {
        var report = RestoreReport()
        // 复原会 rm / rmmod / 杀进程，全是写操作：确认不了型号就不动模块。
        if let session {
            do { try ModuleIdentityGate.requireGenerationOne(session) }
            catch {
                report.skippedReason = "未确认是一代模块，已跳过模块内清理"
                return report
            }
        } else {
            report.skippedReason = "没有 AT 会话，无法确认型号，已跳过模块内清理"
            return report
        }
        guard adb.binary != nil else {
            report.skippedReason = "这台机器上没有 adb"
            return report
        }
        guard (try? adb.run(["devices"], timeout: 12))?.contains("\tdevice") == true else {
            report.skippedReason = "模块没连上"
            return report
        }

        // 先停进程再卸驱动。反过来做的话，桥会去 open 一张正在消失的声卡，
        // 那种时刻最容易卡进 D 状态（连 kill -9 都杀不掉，只能重启模块）。
        for name in ["mavo-pcm-bridge", "alsaucm_test"] {
            guard processRunning(name) else { continue }
            _ = try? adb.shell(Self.killScript(named: name))
            report.stoppedProcesses.append(name)
        }

        let loaded = (try? adb.shell("cat /proc/modules")) ?? ""
        for name in [Self.aprv3Module, Self.voiceModule] {
            let bare = name.replacingOccurrences(of: ".ko", with: "")
            guard loaded.contains(bare) else { continue }
            _ = try? adb.shell("rmmod \(bare)")
            // rmmod 的成败看 /proc/modules：模块被占着时它只会回一句
            // 「Resource temporarily unavailable」，返回值看不出区别。
            let after = (try? adb.shell("cat /proc/modules")) ?? ""
            if !after.contains(bare) { report.unloadedModules.append(bare) }
        }

        // 删文件放在最后：驱动卸完之前删掉 .ko，之后想再 insmod 就没源了。
        let staging = Self.stagingDirectory
        let script = """
        for f in \(staging)/\(Self.aprv3Module) \(staging)/\(Self.voiceModule) \
                 \(staging)/\(Self.bridgeBinary) /var/tmp/alsaucm.out /var/tmp/bridge.log \
                 \(Self.calibrationFIFO) \(Self.calibrationFIFO).stale-*; do
          [ -e "$f" ] || continue
          rm -f "$f" 2>/dev/null && echo "REMOVED $f"
        done
        echo "DONE"
        """
        let output = (try? adb.shell(script, timeout: 30)) ?? ""
        report.removedFiles = Self.lines(in: output)
            .filter { $0.hasPrefix("REMOVED ") }
            .map { String($0.dropFirst("REMOVED ".count)) }
        return report
    }

    /// 模块上还有没有这个进程在跑（僵尸不算 —— 僵尸不占资源，也没什么可停的）。
    private func processRunning(_ name: String) -> Bool {
        let probe = """
        for d in /proc/[0-9]*; do
          [ "$(cat $d/comm 2>/dev/null)" = "\(name)" ] || continue
          [ "$(sed 's/^[^)]*) //' $d/stat 2>/dev/null | cut -c1)" = Z ] && continue
          echo RUNNING; break
        done
        """
        return ((try? adb.shell(probe, timeout: 15)) ?? "").contains("RUNNING")
    }

    // MARK: - 第 1 步：解锁

    /// 把 ADB 弄成**真的能用**。
    ///
    /// 「能用」要两件事同时成立，而这两件真机上各自单独踩过：
    ///
    ///   1. `usbcfg` 的 adb 位是 1。这一位是 **USB 枚举**的时候看的：从 0 翻成
    ///      1 之后必须 `AT+CFUN=1,1` 重启，主机这边才会多出 ADB 那个接口。
    ///   2. 交过口令（`AT+QADBKEY`）。位是 1、接口也在 USB 上列着，adbd 照样
    ///      可以不理主机 —— 现场就是这样：位 = 1、接口在、`adb devices` 空。
    ///      以前拿「位是 1」当「已解锁」，于是解锁这步被整段跳过，后面每一步
    ///      都报「ADB 里看不到模块」，看着像数据线的问题。
    ///
    /// 顺序按「最省事的那条先试」排：**先交口令**（不重启）→ 等 → 还不行就
    /// 重启一次让接口重新枚举 → 等 → 再补交一次口令（有的固件把口令当成
    /// 「每次上电一次」的临时状态，重启会清掉）→ 最后按失败收尾。
    private func raiseADB(report: (String) -> Void) throws {
        let rebooting = try unlockADB()
        report("等模块重启")
        if adbAppears(within: rebooting ? 80 : 15) { return }

        if !rebooting {
            report("重启模块，再连一次")
            try rebootModule()
            if adbAppears(within: 80) { return }

            // 重启可能把口令清掉，补交一遍再等一轮。这一步读不到挑战值也
            // 不算错 —— 见 `unlockADB` 里的说明。
            _ = try? unlockADB()
            report("等模块连上")
            if adbAppears(within: 30) { return }
        }

        try waitForADB(timeout: 15)
    }

    /// 交一次解锁口令（`AT+QADBKEY`）；位还是 0 的话顺手把它翻成 1。
    ///
    /// 返回值说的是**要不要等重启**：翻了位（`AT+CFUN=1,1` 已经发出去）是
    /// true，只交了口令是 false。调用方靠它决定等多久。
    private func unlockADB() throws -> Bool {
        guard let session else { throw SetupError.atRequired }

        // 先看位。是 1 就别碰 `usbcfg`，更别重启 —— 白等二十秒，还把刚建好的
        // 声卡和桥一起拆掉。
        let current = try session.send("AT+QCFG=\"usbcfg\"", timeout: 8)
        guard let line = current.firstValue(for: "+QCFG") else {
            throw SetupError.usbcfgUnreadable(current.rawText)
        }
        let needsFlip = Self.adbBit(inUsbcfg: line) != 1

        // 口令这一步不重启，所以位是 1 的时候也照样要交。**失败不当错误抛**：
        // 位是 1 时连不上 adbd 的原因未必是口令，把判断留给后面的「等 ADB」，
        // 别在这里给一句客户看不懂的「挑战值形状不对」就断了整条安装流程。
        do {
            try handOverADBKey(session)
        } catch {
            guard needsFlip else { return false }
            throw error
        }

        guard needsFlip else { return false }

        // 只翻 adb 这一位，别的一律原样保留 —— 客户手里可能是改过 VID/PID 的
        // 模块，整串覆盖会把那些改动一起抹掉。
        //
        // 注意 `usbcfg(_:settingAdbBit:)` 返回的**已经是完整字段表**（含开头
        // 那一段引号包着的 "usbcfg"），所以这里只能接在 `AT+QCFG=` 后面。
        // 早先多拼了一次 `"usbcfg",`，模块回 ERROR，出厂模块的第一次安装
        // 就卡在「解锁 ADB」这一步 —— 位是 0 的模块全都装不上。
        guard let command = Self.usbcfgCommand(line, settingAdbBit: 1) else {
            throw SetupError.usbcfgUnreadable(line)
        }
        let applied = try session.send(command, timeout: 8)
        guard applied.isOK else {
            throw SetupError.usbcfgRejected(applied.rawText)
        }

        // 重启让新的 USB 组态生效。
        try rebootModule()
        return true
    }

    /// 读挑战值 → 算口令 → 交回去。
    ///
    /// 口令必须是**按挑战值算**出来的，不能写死：客户那台的挑战值未必和这台
    /// 一样，写死的话客户机永远解不开，而且报错里看不出为什么。
    private func handOverADBKey(_ session: ATSession) throws {
        let challengeResponse = try session.send("AT+QADBKEY?", timeout: 8)
        let challenge = challengeResponse.firstValue(for: "+QADBKEY")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard QADBKey.isChallenge(challenge) else {
            throw SetupError.challengeUnreadable(challenge.isEmpty
                ? challengeResponse.rawText
                : challenge)
        }
        guard let password = QADBKey.derive(challenge: challenge) else {
            throw SetupError.challengeRejected(challenge)
        }

        // 交口令
        let unlock = try session.send("AT+QADBKEY=\"\(password)\"", timeout: 8)
        guard unlock.isOK else {
            throw SetupError.unlockRejected(unlock.rawText)
        }
    }

    /// `AT+CFUN=1,1`，模块软重启。AT 会话跟着断，重连由 App 那边负责。
    private func rebootModule() throws {
        guard let session else { throw SetupError.atRequired }
        try session.send("AT+CFUN=1,1", timeout: 8)
    }

    /// 静静等一轮：`adb devices` 里出现模块就 true，到点还没有就 false。
    /// 不抛错 —— 调用方通常还要接着试别的办法。
    private func adbAppears(within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if (try? adb.run(["devices"]))?.contains("\tdevice") == true { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    /// 等 adb 看到模块，等不到就抛错。重启期间 `adb devices` 会先空一阵。
    private func waitForADB(timeout: TimeInterval) throws {
        if adbAppears(within: timeout) { return }
        // 设备可能还停在「未授权/离线」，这时先重启一次 adb server 再给一轮机会。
        _ = try? adb.run(["kill-server"])
        _ = try? adb.run(["start-server"])
        if adbAppears(within: 20) { return }
        let listing = (try? adb.run(["devices"])) ?? "(adb devices 没输出)"
        throw SetupError.moduleNotReachable(listing.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - 第 2 步：驱动

    private func pushResources() throws {
        guard let resources else { throw SetupError.resourceMissing("ModuleVoice 目录") }
        for name in [Self.aprv3Module, Self.voiceModule, Self.bridgeBinary] {
            let source = resources.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw SetupError.resourceMissing(name)
            }
            let dest = "\(Self.stagingDirectory)/\(name)"
            guard let output = try? adb.run(["push", source.path, dest]),
                  !output.lowercased().contains("error") else {
                throw SetupError.pushFailed(name)
            }
        }
        // 桥要可执行位。
        _ = try? adb.shell("chmod 755 \(Self.stagingDirectory)/\(Self.bridgeBinary)")
    }

    private func loadDrivers() throws {
        // 先看有没有已经加载的，重复 insmod 会失败但那是无害的，这里直接跳过。
        let loaded = (try? adb.shell("cat /proc/modules")) ?? ""
        for name in [Self.aprv3Module, Self.voiceModule] {
            let bare = name.replacingOccurrences(of: ".ko", with: "")
            if loaded.contains(bare) { continue }
            _ = try? adb.shell("insmod \(Self.stagingDirectory)/\(name)")
            // insmod 的成败看 /proc/modules，不看返回值：内核里已经在跑的模块
            // 再 insmod 会报 File exists，但那其实说明它好好的。
            let after = (try? adb.shell("cat /proc/modules")) ?? ""
            if !after.contains(bare) {
                let detail = (try? adb.shell("dmesg | tail -5")) ?? ""
                throw SetupError.insmodFailed(bare, detail.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    // MARK: - 第 3 步：校准

    /// 完全照搬 `quectel_daemon` 的出厂序列：起 `alsaucm_test`，等它建好 FIFO，
    /// 再把 Voice Call 那四条命令写进 FIFO。顺序不能改 —— 先 `open` 声卡，
    /// 再选 `Voice Call` 这个 verb，最后挂 Auxpcm 的收发端点。
    ///
    /// 整个过程塞在**一次** `adb shell` 里，中间不能让会话断。真机上踩过：
    /// 把「起守护」和「等 FIFO」拆成两次调用时，adb 会话一结束刚 fork 出来的
    /// 守护进程就被带走，日志停在 `ACPH init success`、FIFO 永远不出现 ——
    /// 报出来的却是「校准失败」，看着像模块的问题，其实是启动方式的问题。
    /// `nohup` + `setsid` 是双保险：前者挡会话结束的信号，后者脱离会话，
    /// 之后 USB 重枚举也不会把它带走。
    private func calibrate() throws {
        let script = """
        FIFO=\(Self.calibrationFIFO)
        # 老的 FIFO 挪走而不是删掉，保留现场（出问题时还能看）。
        [ -e "$FIFO" ] && mv "$FIFO" "$FIFO.stale-$(date +%s)"
        nohup setsid /usr/bin/alsaucm_test >/var/tmp/alsaucm.out 2>&1 </dev/null &
        i=0
        while [ $i -lt 60 ]; do
          [ -p "$FIFO" ] && break
          sleep 0.25
          i=$((i+1))
        done
        if [ ! -p "$FIFO" ]; then echo "FIFO_MISS"; exit 1; fi
        {
          echo "open \(Self.soundCard)"
          echo "set _verb Voice Call"
          echo "set _enadev Auxpcm Rx"
          echo "set _enadev Auxpcm Tx"
        } > "$FIFO"
        echo "FIFO_OK"
        """

        let output = (try? adb.shell(script, timeout: 40)) ?? ""
        guard output.contains("FIFO_OK") else {
            let log = (try? adb.shell("tail -20 /var/tmp/alsaucm.out")) ?? ""
            throw SetupError.calibrateFailed(
                "FIFO 未出现：" + log.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        Thread.sleep(forTimeInterval: 3)

        // 确认它真的认了：输出里会有一句 Sent VocProc Cal!。
        let log = (try? adb.shell("tail -30 /var/tmp/alsaucm.out")) ?? ""
        guard log.contains("Sent VocProc Cal") || log.contains("Voice Call") else {
            throw SetupError.calibrateFailed(log.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - 每一通都重挂一次语音通路

    /// 把出厂那四条语音命令**再下发一遍**（幂等）。返回 true 表示确实写进去了。
    ///
    /// 为什么每通电话都要来这一下：`inspect()` 只能证明 `alsaucm_test` 进程
    /// 还在、FIFO 还在，**证明不了 `Voice Call` 这个 verb 还挂在混音器上**。
    /// 而模块在通话结束、USB 重配、休眠回来这些时刻都可能把混音器状态收掉；
    /// 那时候五个前置条件一条不差、界面上写着「已就绪」，接起来就是一声没有，
    /// 而且全程不报错 —— 这正是 2026-09-28 那几通电话的形状。
    ///
    /// 写之前先确认读者活着、而且**不是 D 状态**：进程卡在 D 状态时写 FIFO
    /// 会把调用方一起拖住，那种卡死连 `kill -9` 都解不开，只能重启模块。
    /// 写本身也带兜底：万一没人读，最多等两秒就放弃 —— 绝不让一通电话卡在
    /// 这一步上。写成功（或明确失败）各echo一行，调用方按行判断。
    @discardableResult
    public func rearmVoiceCall(timeout: TimeInterval = 8) -> Bool {
        guard adb.binary != nil else { return false }
        let script = """
        FIFO=\(Self.calibrationFIFO)
        REARM_OUT=/var/tmp/rearm.out
        rm -f "$REARM_OUT" 2>/dev/null
        [ -p "$FIFO" ] || { echo "NO_FIFO"; exit 0; }
        state=""
        for d in /proc/[0-9]*; do
          [ "$(cat $d/comm 2>/dev/null)" = "alsaucm_test" ] || continue
          s=$(sed 's/^[^)]*) //' $d/stat 2>/dev/null | cut -c1)
          [ "$s" = "Z" ] && continue
          state="$s"
        done
        [ -n "$state" ] || { echo "NO_READER"; exit 0; }
        [ "$state" = "D" ] && { echo "READER_STUCK"; exit 0; }
        (
          {
            echo "set _verb Voice Call"
            echo "set _enadev Auxpcm Rx"
            echo "set _enadev Auxpcm Tx"
          } > "$FIFO" 2>/dev/null && echo "WROTE" > "$REARM_OUT"
        ) &
        w=$!
        i=0
        while [ $i -lt 20 ]; do
          kill -0 $w 2>/dev/null || break
          sleep 0.1
          i=$((i+1))
        done
        if kill -0 $w 2>/dev/null; then
          kill -9 $w 2>/dev/null
          echo "WRITE_TIMEOUT"
        else
          cat "$REARM_OUT" 2>/dev/null || echo "WRITE_UNKNOWN"
        fi
        """
        let output = (try? adb.shell(script, timeout: timeout)) ?? ""
        return Self.lines(in: output).contains("WROTE")
    }

    /// 停掉 PCM 桥。校准必须在**没有桥占着语音通路**的时候做：桥在跑的时候
    /// `alsaucm_test` 会卡在初始化里，进程进 D 状态 —— 那种状态下连 `kill -9`
    /// 都杀不掉，只能重启模块。所以补校准之前先把桥请走，第 4 步再起回来。
    private func stopBridge() {
        _ = try? adb.shell(Self.killScript(named: "mavo-pcm-bridge"))
    }

    /// 按进程名干掉活着的实例（僵尸本来就不占资源，跳过）。
    static func killScript(named name: String) -> String {
        """
        for d in /proc/[0-9]*; do
          [ "$(cat $d/comm 2>/dev/null)" = "\(name)" ] || continue
          [ "$(sed 's/^[^)]*) //' $d/stat 2>/dev/null | cut -c1)" = Z ] && continue
          kill -9 "$(basename $d)" 2>/dev/null
        done
        true
        """
    }

    // MARK: - 第 4 步：PCM 桥

    private func startBridge() throws {
        _ = try? adb.shell("echo 1 > \(Self.audioEnableSwitch)")

        // 起桥和等它就绪放同一次会话里（理由见 calibrate 的注释）；nohup + setsid
        // 让它在会话结束、乃至后面的 USB 重枚举之后都还在。
        _ = try? adb.shell("nohup setsid \(Self.stagingDirectory)/\(Self.bridgeBinary) "
                           + "--voice-route-session --verbose >>/var/tmp/bridge.log 2>&1 </dev/null & "
                           + "sleep 4",
                           timeout: 30)

        // 复查直接调 inspect()，和界面上显示的是同一套判断 —— 两处各写一份
        // 迟早会出现「界面说好了、实际没好」这种最难查的分歧。
        let after = inspect()
        guard after.audioEnabled else {
            let raw = (try? adb.shell("cat \(Self.audioEnableSwitch)"))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SetupError.bridgeFailed("audio_enable 写不进去（读到 \(raw ?? "空")）")
        }
        guard after.bridgeRunning else {
            let log = (try? adb.shell("tail -20 /var/tmp/bridge.log")) ?? ""
            throw SetupError.bridgeFailed(log.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// 等声卡在 `/proc/asound/cards` 里出现。insmod 之后要一两秒。
    private func waitForSoundCard(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let cards = (try? adb.shell("cat /proc/asound/cards")) ?? ""
            if cards.contains("mdm9607") { return }
            Thread.sleep(forTimeInterval: 1)
        }
        // 声卡没出来不算致命：`inspect()` 会把 `soundCardPresent` 报成 false，
        // 界面照实说。这里不抛，免得把一个「差点就好」的状态说成失败。
    }

    // MARK: - 解析

    /// 体检脚本读回来的那些计数。
    ///
    /// 公开是为了让自检能直接盯住它 —— 这里出过一次「全读成 0」的错
    /// （CRLF 切行），光看界面只会以为模块没好，看不出是解析坏了。
    public struct ProbeCounts: Equatable {
        /// `/proc/modules` 里 qdc507_aprv3 的行数（>0 就是加载了）。
        public var aprv3 = 0
        /// 同上，qdc507_voice。
        public var voice = 0
        /// `audio_enable` 的原文（`1` / `0` / 读不到时的 `none`）。
        public var audioEnable = "none"
        /// `/proc/asound/cards` 里 mdm9607 的行数（>0 就是声卡在）。
        public var cards = 0
        /// PCM 桥进程数。
        public var bridge = 0
        /// 语音校准守护进程数。
        public var alsaucm = 0
        /// 校准 FIFO 在不在。
        public var fifo = false

        public init() {}
    }

    /// 把那段 `probe` 脚本的输出按 `##` 分节读回来。
    ///
    /// 切行必须用 ``lines(in:)``：`adb shell` 回来的是 CRLF，而 Swift 把
    /// `"\r\n"` 当成**一个** Character，`split(separator: "\n")` 切不开它 ——
    /// 整段会被当成一行，于是每个计数都读成 0，体检就报「全部未就绪」。
    public func parse(probe output: String) -> ProbeCounts {
        var counts = ProbeCounts()
        var section = ""
        for raw in Self.lines(in: output) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("##") { section = String(line.dropFirst(2)); continue }
            guard !line.isEmpty else { continue }
            switch section {
            case "modules":
                if counts.aprv3 == 0 { counts.aprv3 = Int(line) ?? 0 }
                else if counts.voice == 0 { counts.voice = Int(line) ?? 0 }
            case "audio": counts.audioEnable = line
            case "cards": counts.cards = Int(line) ?? 0
            case "procs":
                if counts.bridge == 0 { counts.bridge = Int(line) ?? 0 }
                else if counts.alsaucm == 0 { counts.alsaucm = Int(line) ?? 0 }
            case "fifo": counts.fifo = line == "yes"
            default: break
            }
        }
        return counts
    }

    /// 按换行切行，`\n`、`\r\n`、`\r` 都认。
    ///
    /// 别改成 `split(separator: "\n")`：Swift 的 `Character` 是把 CRLF 当成
    /// 单个字素的，那种写法遇到 adb / 串口的 CRLF 输出会一行都切不出来。
    /// 行尾残留的 `\r` 也会让 `Int(line)` 返回 nil。
    public static func lines(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 体检脚本。一次 shell 把要问的都问回来，省得来来回回好几趟。
    ///
    /// 进程数**不数僵尸**：这个固件的 init 不收尸，被杀掉的进程会以 `[名字]`
    /// 的僵尸形态一直留在 `ps` 里。早先这里用 `ps -A | grep -c` 数，僵尸照样
    /// 计入 —— 表现就是校准守护进程明明已经死了、FIFO 也没了，体检却报「已
    /// 下发」，于是客户那边接通了没声音，界面上还什么都看不出来。
    /// 现在按 `/proc/<pid>/comm` 认名字、按 `/proc/<pid>/stat` 的状态位排掉 Z，
    /// 顺便也不会像 `grep` 那样把跑 `ps` 的自己数进去。
    static let probe = """
    echo "##modules"; cat /proc/modules 2>/dev/null | grep -c qdc507_aprv3; cat /proc/modules 2>/dev/null | grep -c qdc507_voice
    echo "##audio"; cat /sys/class/android_usb/f_audio/audio_enable 2>/dev/null || echo none
    echo "##cards"; cat /proc/asound/cards 2>/dev/null | grep -c mdm9607
    echo "##procs"
    b=0; a=0
    for d in /proc/[0-9]*; do
      c=$(cat $d/comm 2>/dev/null)
      [ "$c" = mavo-pcm-bridge ] || [ "$c" = alsaucm_test ] || continue
      [ "$(sed 's/^[^)]*) //' $d/stat 2>/dev/null | cut -c1)" = Z ] && continue
      if [ "$c" = alsaucm_test ]; then a=$((a+1)); else b=$((b+1)); fi
    done
    echo $b; echo $a
    echo "##fifo"; [ -p /run/alsaucm_test ] && echo yes || echo no
    """

    /// `usbcfg` 里 adb 那一位的下标（和 `ATParsers.qcfgComposite` 用同一张表）。
    ///
    /// 模块回的整行是 `+QCFG: "usbcfg",0x2CA3,0x4006,1,1,1,1,1,1,1`，字段顺序
    /// 固定：`name, vid, pid, diag, nmea, at, modem, network, adb, audio`。
    /// 所以 adb 是**整行下标 8**（第 8 个功能位）。以前这里写的是 7 —— 那是
    /// network，而这台模块的 network 位恰好是 1，于是「adb 位是 0」会被读成 1。
    static let adbFlagIndex = 8

    /// 把 `+QCFG: "usbcfg",…` 切成字段。
    ///
    /// 两种形状都要吃：命令行那边直接把**原始返回行**传进来（带 `+QCFG:`），
    /// 而 `ATResponse.firstValue(for:)` 的返回值已经把冒号及之前的部分掐掉了
    /// （`"usbcfg",0x2CA3,…`）。真机上踩过一次：这里原先写死「必须先找到
    /// 冒号」，`firstValue` 的返回值一进来就返回 nil，界面报「读不到 usbcfg」
    /// 而值就在报错里摆着 —— 和 `firstValue` 那个行首 `+` 的坑是同一类错。
    public static func usbcfgFields(in line: String) -> [String]? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只有冒号出现在第一个引号**之前**时，才当它是 `+QCFG:` 这种前缀。
        // 双引号里面也可能有冒号（客户改过的 usb 名称），不能乱切。
        if let colon = text.firstIndex(of: ":"),
           text[text.startIndex..<colon].firstIndex(of: "\"") == nil {
            text = String(text[text.index(after: colon)...])
        }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // 字段不够就返回 nil，别猜一个位出来 —— 猜错一位的后果是「解锁」整段
        // 被跳过，客户那边看到的却是一句「ADB 里看不到模块」。
        guard parts.count > adbFlagIndex else { return nil }
        return parts
    }

    /// 从 `+QCFG: "usbcfg",0x2CA3,0x4006,1,1,1,1,1,0,1` 里把 adb 位抠出来。
    public static func adbBit(inUsbcfg line: String) -> Int? {
        guard let parts = usbcfgFields(in: line) else { return nil }
        return Int(parts[adbFlagIndex])
    }

    /// 把 adb 位改成 `value`，其余字段原样保留。
    ///
    /// 返回的是**完整字段表**（含开头带引号的 `"usbcfg"`），本身不是一条
    /// 能直接发出去的 AT 命令。要发命令用 `usbcfgCommand(_:settingAdbBit:)`。
    public static func usbcfg(_ line: String, settingAdbBit value: Int) -> String? {
        guard var parts = usbcfgFields(in: line) else { return nil }
        // 第一个字段是带引号的 "usbcfg"，转成命令时要连引号一起带上。
        parts[0] = "\"usbcfg\""
        parts[adbFlagIndex] = String(value)
        return parts.joined(separator: ",")
    }

    /// 组装出真正要发给模块的那条命令。
    ///
    /// 单独抽出来是为了能被自检覆盖：名字那一段**只能出现一次**。之前
    /// 调用处直接写 `"AT+QCFG=\"usbcfg\",\(updated)"`，把名字拼了两遍，
    /// 模块回 `ERROR`，于是「出厂模块第一次装语音」永远卡在解锁 ADB。
    public static func usbcfgCommand(_ line: String, settingAdbBit value: Int) -> String? {
        guard let fields = usbcfg(line, settingAdbBit: value) else { return nil }
        return "AT+QCFG=\(fields)"
    }

    // MARK: - 常量

    static let aprv3Module = "qdc507_aprv3.ko"
    static let voiceModule = "qdc507_voice.ko"
    static let bridgeBinary = "mavo-pcm-bridge.armv7"
    static let stagingDirectory = "/data/local/tmp"
    static let calibrationFIFO = "/run/alsaucm_test"
    static let audioEnableSwitch = "/sys/class/android_usb/f_audio/audio_enable"
    /// 声卡名，来自 manifest.json 的 `cardName`。
    static let soundCard = "snd_soc_msm_9x07_Tomtom_I2S"
}

// MARK: - adb 执行

/// 跑 adb 命令的一层薄封装。
///
/// 用**独立端口**（默认 5039，`DJI4G_ADB_PORT` 可改）：客户机上很可能已经有
/// 一个 adb server 占着默认的 5037 在调别的设备，抢过来会把人家正在做的事
/// 打断。分开端口互不影响。
public final class ADBRunner {

    /// adb 可执行文件的位置，找不到就是 nil。
    public let binary: String?
    private let port: String

    public init() {
        self.binary = Self.locate()
        self.port = ProcessInfo.processInfo.environment["DJI4G_ADB_PORT"] ?? "5039"
    }

    /// 依次找：环境变量 → 随包资源 → 常见安装位置 → PATH。
    ///
    /// 随包优先，是因为客户机上不该要求他先自己装 platform-tools；而且自带
    /// 的那一份是 universal 二进制，M 系列和 Intel 都能跑。
    static func locate() -> String? {
        let fm = FileManager.default

        if let explicit = ProcessInfo.processInfo.environment["DJI4G_ADB"], !explicit.isEmpty,
           fm.isExecutableFile(atPath: explicit) {
            return explicit
        }

        if let dir = ModuleVoiceSetup.defaultResourceDirectory() {
            let bundled = dir.appendingPathComponent("adb").path
            if fm.isExecutableFile(atPath: bundled) { return bundled }
        }

        let homes = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb",
                     "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"]
        for path in homes where fm.isExecutableFile(atPath: path) { return path }

        // PATH
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let path = "\(dir)/adb"
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// 跑一条 adb 命令，返回合并后的输出。非零退出码不算失败 —— adb 经常
    /// 用有意义的输出配一个非零码，由调用方自己判断。
    @discardableResult
    public func run(_ arguments: [String], timeout: TimeInterval = 60) throws -> String {
        guard let binary else { throw ModuleVoiceSetup.SetupError.adbMissing }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["ANDROID_ADB_SERVER_PORT"] = port
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        try process.run()

        // 超时就杀掉，别把界面卡死。
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw ModuleVoiceSetup.SetupError.adbFailed(arguments.joined(separator: " "), "超时")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 在模块上跑一条 shell 命令。
    @discardableResult
    public func shell(_ command: String, timeout: TimeInterval = 60) throws -> String {
        try run(["shell", command], timeout: timeout)
    }
}
