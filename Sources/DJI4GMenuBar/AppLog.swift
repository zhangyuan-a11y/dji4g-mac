import Foundation
import CoreGraphics

/// 真机上的现场记录。
///
/// 2026-09-25，客户报「菜单栏图标点得动，菜单面板不弹」。本机（macOS 15）
/// 连点八次全都正常，客户那台大概率是 macOS 26 —— 这个 bug 只在**别人的
/// 机器**上发生，而我们手里连一行现场都没有：App 当时不写任何日志，于是
/// 「点了没反应」和「压根没点上」在日志里长得一模一样，都是空的。
///
/// 这个文件补的就是那一格。三条硬要求，写任何一行代码前都先满足它们：
///   1. 绝不在主线程做 I/O —— 日志不能变成新的卡顿来源；
///   2. 绝不让日志把自己搞崩 —— 任何一步失败就放弃，静默，不回退；
///   3. 无头路径（`--render` / `--sim-check` / `--ring-check`）**不装**，
///      截图和自检的输出不会因为多写一行日志而变。
///
/// 记下来的东西是给「客户的 Mac」用的，不是给这台开发机用的：进程什么时候
/// 起、菜单面板有没有真的打开、上一次运行是不是没退干净、主线程有没有卡住。
enum AppLog {
    private static let queue = DispatchQueue(label: "local.dji4g.applog")
    private static let lock = NSLock()
    private static var installed = false
    private static var handle: FileHandle?
    private static var folder: URL?
    private static var lastMilestone = "（还没有动作）"
    private static var panelOpenCount = 0

    private static let markerName = "running.marker"
    private static let crashName = "crash.signal"

    /// 文件长到这么大就清一遍重来。
    ///
    /// 2026-09-25 之前只有「启动 / 断开 / 面板打开」那几行，文件长不起来；
    /// 现在活动列表里的每一句都会镜像进来，客户那台机器会开着好几周。日志是
    /// 给「最近一次问题」用的，不是存档 —— 无限长下去占的是客户自己的磁盘，
    /// 真出事时翻起来也更慢。
    private static let maxBytes: UInt64 = 2 * 1024 * 1024
    /// 写满这么多行才去问一次文件多大。问大小是一次 stat，不值得每行都做。
    private static var writesSinceSizeCheck = 0

    // MARK: - 装

    /// 只开一次。装完之后 `log` 才有意义；没装的时候 `log` 是空操作，
    /// 所以调用点不用到处判断自己是不是在无头路径里。
    static func install() {
        guard !installed else { return }
        installed = true

        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DJI4G", isDirectory: true)
        // LaunchAgent 已经把这个目录指成了 stdout/stderr 的去处，正常它就在；
        // 不在就建一个，建不出来就到此为止。
        guard (try? FileManager.default.createDirectory(at: base,
                                                       withIntermediateDirectories: true)) != nil
        else { installed = false; return }
        folder = base

        let url = base.appendingPathComponent("app.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        guard handle != nil else { installed = false; return }
        _ = try? handle?.seekToEnd()
        // `FileHandle` 建出来是不带 `O_APPEND` 的，写之前得自己 `seekToEnd`。
        // 本进程里那条后台队列保证了顺序，可另一个进程（下面 `note` 那一份）
        // 也在写同一个文件：两边各自 seek 到同一个位置再写，后写的那一行就会
        // 盖住前一行，日志里留下半截句子 —— 2026-09-25 实测踩到过。把定位交给
        // 内核，一次写完，两个进程就再也盖不着了。
        markAppendOnly(handle)

        reportPreviousRun(base)
        writeMarker(base)
        installCrashMarkers(base)
        MainThreadWatchdog().start()

        log("启动 pid=\(ProcessInfo.processInfo.processIdentifier)"
            + " 系统=\(ProcessInfo.processInfo.operatingSystemVersionString)"
            + " 参数=\(CommandLine.arguments.dropFirst().joined(separator: " "))")
    }

    // MARK: - 写

    /// 追加一行。时间戳在这里取（调用线程），真正落盘在后台队列上排队。
    static func log(_ text: String) {
        guard installed else { return }
        lock.lock()
        lastMilestone = text
        lock.unlock()

        let line = "\(stamp()) \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            guard let handle else { return }
            try? handle.write(contentsOf: data)
            rotateIfNeeded(handle)
        }
    }

    /// 超过 `maxBytes` 就从零开始。只在日志队列上调，所以不用另加锁。
    private static func rotateIfNeeded(_ handle: FileHandle) {
        writesSinceSizeCheck += 1
        guard writesSinceSizeCheck >= 64 else { return }
        writesSinceSizeCheck = 0
        guard let end = try? handle.seekToEnd(), end > maxBytes else { return }
        try? handle.truncate(atOffset: 0)
        try? handle.seek(toOffset: 0)
        let line = "\(stamp()) 日志已超过 \(maxBytes / 1024 / 1024) MB，从这里重新开始记\n"
        if let data = line.data(using: .utf8) { try? handle.write(contentsOf: data) }
    }

    /// 只往日志里补一行，**不接管这个进程**。
    ///
    /// 给「又双击了一下 App 图标」起的那一份用：它马上就退，所以连 `install()`
    /// 都不能走 —— 一 `install()` 就会把 marker 改成自己的 pid，而它又不会走到
    /// `markCleanExit`，下一次启动就会把它报成「上一次运行没有正常收尾」，在
    /// 客户那台机器上凭空造一个崩溃现场。那正是这份日志最不能有的东西。
    static func note(_ text: String) {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DJI4G", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let data = "\(stamp()) \(text)\n".data(using: .utf8) else { return }
        // 走 POSIX 的 `O_APPEND`：这一份和还在跑的那一份是同时写的，`O_CREAT`
        // 顺便把「日志还不存在」那一步也包了，不用再分两种情况。
        append(data, to: base.appendingPathComponent("app.log"))
    }

    /// 把已经在手上的那个 fd 改成追加模式（`F_SETFL` 是就地的，不用重开）。
    private static func markAppendOnly(_ handle: FileHandle?) {
        guard let fd = handle?.fileDescriptor else { return }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, flags | O_APPEND)
    }

    /// 追加一段字节。内核负责「定位 + 写」，多进程并发时不会互相覆盖。
    private static func append(_ data: Data, to url: URL) {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        // 一次写不完就接着写；正常几个字节到几百字节都是一次到位，这里只是
        // 不想在信号或者磁盘满的边上留下半行。
        data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let wrote = write(fd, base, left)
                guard wrote > 0 else { break }
                base = base.advanced(by: wrote)
                left -= wrote
            }
        }
    }

    /// 给「主线程卡住」那一行用：卡住的时候卡在哪个动作上。
    static var milestone: String {
        lock.lock(); defer { lock.unlock() }
        return lastMilestone
    }

    /// 菜单面板真的被画出来了才会走这里。
    ///
    /// 这一行是整件事的分水岭：客户再报「点不开」的时候，日志里
    ///   有「菜单面板打开」→ 面板弹出来了，问题在别处（比如弹在了屏幕外）；
    ///   没有这一行、而进程一直活着 → 点击根本没走到 SwiftUI，就是没弹。
    static func panelOpened() {
        guard installed else { return }
        panelOpenCount += 1
        log("菜单面板打开（第 \(panelOpenCount) 次）")
    }

    /// 从 `AppDelegate.applicationWillTerminate` 进来。走得到这里，说明这次
    /// 运行是自己收的尾，下次启动就不会把上一次当成崩溃。
    static func markCleanExit(_ reason: String) {
        guard installed, let folder else { return }
        log("退出：\(reason)")
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(markerName))
    }

    // MARK: - 上一次是怎么结束的

    /// 上一次启动留下的标记还在，就说明上一次没走到 `markCleanExit`。
    ///
    /// 比逐个信号判断更管用的地方在于：崩溃、被 `kill -9`、卡死之后被用户
    /// 强退，这几种在标记文件眼里是同一件事 —— 而它们对客户都是「刚才还好
    /// 好的，突然没了」。
    private static func reportPreviousRun(_ base: URL) {
        let marker = base.appendingPathComponent(markerName)
        guard let previous = try? String(contentsOf: marker, encoding: .utf8) else { return }
        let owner = previous.split(separator: " ").first.map(String.init) ?? previous
        let crash = base.appendingPathComponent(crashName)
        if let raw = try? Data(contentsOf: crash), let byte = raw.first {
            log("上一次运行是崩溃退出的：pid=\(owner) 信号=\(crashSignalName(byte))")
            try? FileManager.default.removeItem(at: crash)
        } else {
            log("上一次运行没有正常收尾：pid=\(owner)"
                + "（崩溃、被强制退出，或者关机时被带走，日志里分不出来）")
        }
    }

    private static func writeMarker(_ base: URL) {
        let text = "\(ProcessInfo.processInfo.processIdentifier) \(stamp())\n"
        try? text.write(to: base.appendingPathComponent(markerName),
                        atomically: true, encoding: .utf8)
    }

    // MARK: - 崩溃

    /// 崩溃标记：先把一个 fd 开好，信号处理器里**只**往它写一个字节。
    ///
    /// `write` 是 async-signal-safe 的，格式化字符串不是 —— 所以信号号不做
    /// 十进制转换，直接原样写一个字节（SIGSEGV=11 这些全都小于 128），读的
    /// 时候再翻回来。写完把处理方式交还给系统再重新抛一次，这样 `.ips`
    /// 崩溃报告照样生成：我们只是多加一行「上次是崩的」，不抢系统的现场。
    private static func installCrashMarkers(_ base: URL) {
        let path = base.appendingPathComponent(crashName).path
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        crashFD = fd
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP] {
            signal(sig) { received in
                if crashFD >= 0 {
                    var byte = UInt8(truncatingIfNeeded: received)
                    _ = withUnsafePointer(to: &byte) { write(crashFD, $0, 1) }
                    close(crashFD)
                    crashFD = -1
                }
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    private static func crashSignalName(_ byte: UInt8) -> String {
        switch Int32(byte) {
        case SIGSEGV: return "SIGSEGV（访问了不该访问的内存）"
        case SIGBUS:  return "SIGBUS"
        case SIGILL:  return "SIGILL"
        case SIGABRT: return "SIGABRT（自己中断的，通常是断言或未捕获的异常）"
        case SIGFPE:  return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        default:      return "signal \(byte)"
        }
    }

    // MARK: - 主线程卡死

    /// 每 3 秒从后台探一次主线程。
    ///
    /// 「点了没反应」在客户眼里只有一个样子，在我们这边有两种完全不同的
    /// 原因：面板压根没弹，或者面板要弹的时候主线程正卡着。这一行能把两种
    /// 分开 —— 而且它记的是**卡住前最后一个动作**，不用再猜卡在哪儿。
    ///
    /// 2026-09-29 把这天攒下的 5 份现场（`stall-*.txt`）逐份数过一遍：**主线程
    /// 一次也没真卡过** —— 每一份里 100% 的采样点都停在 `mach_msg2_trap`，也就是
    /// 空在事件循环里等消息。假警只有两个来源，下面各堵一个（睡觉用 `uptime()`
    /// 量、按住菜单栏图标用 `mouseIsHeld()` 挡）。真卡住的判定逻辑一个字没动。
    private final class MainThreadWatchdog: @unchecked Sendable {
        private let lock = NSLock()
        private var lastAck = MainThreadWatchdog.uptime()
        private var reported = false

        /// 卡到这个秒数才值得留一份现场 —— 代价见下面调用处那段。
        private static let deepTraceSeconds = 15

        func start() {
            let thread = Thread { [self] in loop() }
            thread.name = "dji4g.main-thread-watch"
            thread.stackSize = 256 * 1024
            thread.start()
        }

        /// 主线程还有多久没应过声 —— **必须走 `mach_absolute_time` 这一路的钟**。
        ///
        /// `Date()` 是墙上时间，把合盖睡觉那几个小时原样算进去。日志里的
        /// 「主线程卡住：3653 秒」就是这么来的：3653 秒不多不少正好一小时，
        /// 机器睡多久、醒来就报多久，和主线程没有一点关系（2423 秒、810 秒
        /// 那两条同理）。`systemUptime` 是「系统醒着的时间」，睡眠期间不走字，
        /// 这一类假警从此不会再有。
        private static func uptime() -> TimeInterval {
            ProcessInfo.processInfo.systemUptime
        }

        /// 鼠标左键 / 右键现在还按着吗。
        ///
        /// 这是「4 秒」那一批假警的解药。5 次告警里每一次的上一行都是
        /// 「菜单面板打开」，也就是用户正按着菜单栏图标。AppKit 处理这个按下
        /// 动作走的是**跟踪循环**（现场里的 `NSStatusBarButtonCell trackMouse:`
        /// 和 `NSDragEventTracker`），那个循环只从事件队列取事件、不排空主队列，
        /// 压进去的探针块自然落不了地；可主线程好好的，抓下来的栈全在等事件。
        /// 手指按多久，它就能误报多久。问 WindowServer 一句就够，而且从后台
        /// 线程问是安全的。
        private static func mouseIsHeld() -> Bool {
            CGEventSource.buttonState(.combinedSessionState, button: .left)
                || CGEventSource.buttonState(.combinedSessionState, button: .right)
        }

        private func ack() {
            lock.lock(); lastAck = MainThreadWatchdog.uptime(); lock.unlock()
        }

        /// 这一轮量到的「没应声」有多久。
        private func state() -> (reported: Bool, silence: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            return (reported, MainThreadWatchdog.uptime() - lastAck)
        }

        private func setReported(_ value: Bool) {
            lock.lock(); reported = value; lock.unlock()
        }

        private func loop() {
            ack()
            while true {
                Thread.sleep(forTimeInterval: 2)
                DispatchQueue.main.async { [weak self] in self?.ack() }
                // 醒来再量：主线程要是在这 1 秒里把上面的块跑掉了，说明它活着。
                Thread.sleep(forTimeInterval: 1)

                // 手正按着菜单栏图标：跟踪循环不排空主队列，探针必然落不了地。
                // 这不是卡顿 —— 把基线挪到现在（这一轮量出来就是 0 秒），上一次
                // 误报也会顺着下面那条 `recovered` 收掉。
                if MainThreadWatchdog.mouseIsHeld() { ack() }

                let (wasReported, silence) = state()
                let suspect = silence > 5 && !wasReported
                let recovered = silence < 2.5 && wasReported
                if recovered { setReported(false) }

                // 量出来「好几秒没动静」还不算数 —— 这台机器上负载一高（编译、
                // 截图、自动化点按都在跑），探针块晚到一两轮是常事，主线程其实
                // 一直空在事件循环里等消息。所以先复核再开口。
                if suspect, confirmStillSilent() {
                    // 复核又花掉 1 秒，报出去的秒数按复核后的时刻算。
                    setReported(true)
                    let seconds = Int(state().silence)
                    AppLog.log("主线程卡住：\(seconds) 秒没有响应"
                               + "（卡住前的最后一个动作：\(AppLog.milestone)）")
                    // 抓栈要跑 `sample`，它采样期间会把整个进程按住 3～8 秒，
                    // 模块那条连接会因此掉线（日志里「主线程卡住」后面紧跟一行
                    // 「模块断开：通道已关闭」就是这么来的）。只有拖过
                    // `deepTraceSeconds` 还没缓过来的才值得付这个代价：按住图标、
                    // 被负载挤晚那一类几秒就过去了，犯不上为它把客户的网掐一次。
                    if seconds >= MainThreadWatchdog.deepTraceSeconds,
                       let name = AppLog.captureStallStack() {
                        AppLog.log("已抓栈：\(name)")
                    }
                }
                if recovered {
                    AppLog.log("主线程恢复响应")
                }
            }
        }

        /// 复核：主线程是真卡住了，还是这一轮探针只是晚到了。
        ///
        /// 做法还是同一个探针 —— 再往主队列压一块，然后等 1 秒看它跑不跑。
        /// 真卡住的主线程连事件循环都转不动，这一块照样落不了地；只是被负载
        /// 挤晚了的，这一秒里一定跑得掉。返回 `true` 表示**确认还卡着**。
        private func confirmStillSilent() -> Bool {
            lock.lock(); let before = lastAck; lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.ack() }
            Thread.sleep(forTimeInterval: 1)
            lock.lock(); let after = lastAck; lock.unlock()
            return after == before
        }
    }

    // MARK: - 卡住时的现场

    /// 主线程卡住时抓一份调用栈。
    ///
    /// 「卡了 4 秒」只说明有东西堵着，不说明是谁堵的。这种卡顿在客户那台机器上
    /// 几天才撞上一次，靠猜改代码改不准 —— 而 `sample` 能把卡住那一刻主线程
    /// 正在跑的函数，连同文件、行号，原样抄下来，抓一次就够定位。
    ///
    /// 几条约束，和这个文件开头那三条是同一套：
    ///   1. 在**看门狗自己那条后台线程**上同步跑（实测 3～6 秒），主线程该卡
    ///      还卡，但抓栈本身不会让卡顿变长；
    ///   2. 界面上不出现任何东西 —— 只是日志目录里多一个文件，诊断脚本会
    ///      自动把它装进报告；
    ///   3. 最多留 `keep` 份，多的删最旧，不占客户磁盘。
    ///
    /// 返回文件名给日志对上号；抓不到（没有 `sample`、写不进去）就返回 `nil`。
    private static func captureStallStack() -> String? {
        let tool = "/usr/bin/sample"
        guard FileManager.default.isExecutableFile(atPath: tool),
              let folder else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "stall-\(formatter.string(from: Date())).txt"
        let url = folder.appendingPathComponent(name)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        // 1 秒的采样窗：够抓到一个卡了 4 秒的主线程，又不用把看门狗按太久。
        process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "1",
                             "-file", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // 兜底：正常 3～6 秒回来，超过 20 秒就收掉 —— 抓不到栈，也比把看门狗
        // 永远卡在这条命令上强。
        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()

        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        trimStallFiles()
        return name
    }

    /// 只留最近的几份。名字里带的是 `yyyyMMdd-HHmmss`，按名字排就是按时间排。
    private static func trimStallFiles(keep: Int = 5) {
        guard let folder else { return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return }
        let stalls = names.filter { $0.hasPrefix("stall-") && $0.hasSuffix(".txt") }.sorted()
        guard stalls.count > keep else { return }
        for name in stalls.dropLast(keep) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: - 小工具

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}

/// 信号处理器要用的全局量：文件作用域的存储比类型上的静态属性更省心，
/// 而且在这里只是「读一个已知地址、写一个字节」，不做任何分配。
private var crashFD: Int32 = -1
