import Foundation
import AppKit
import SwiftUI
import Combine
import Darwin
import Network
import SystemConfiguration
import DJI4GCore

// MARK: - 这台机器

/// 客户机上和排查有关的三样：系统、机型、芯片。
///
/// 这三样在诊断报告里各占一行、隔着几百行日志，问起来还得让客户自己去
/// 「关于本机」里抄一遍。放在最上面，这边第一眼就看得到 —— 而 M4 和 Intel
/// 上能出的问题本来就不是同一批。
struct MachineInfo: Equatable {
    var macOS: String
    var build: String
    var model: String
    var chip: String
    var architecture: String

    static func current() -> MachineInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return MachineInfo(
            macOS: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            build: sysctl("kern.osversion") ?? "—",
            model: sysctl("hw.model") ?? "—",
            chip: sysctl("machdep.cpu.brand_string") ?? architectureName,
            architecture: architectureName)
    }

    private static var architectureName: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// MARK: - 日志尾巴

/// `~/Library/Logs/DJI4G/app.log` 的最后几行。
///
/// 只从文件末尾往前读一段：这份日志是给「客户用了几个月之后」看的，
/// 那时候它可能已经几兆，整份读进内存只为了最后几十行不值得。
enum LogTail {
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DJI4G/app.log")
    }

    static func read(lines: Int, maxBytes: Int = 262_144) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        var text = String(decoding: data, as: UTF8.self)
        // 从中间截的那一段，第一行多半是半截句子 —— 留着会被当成一条真日志。
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return Array(all.suffix(lines))
    }
}

// MARK: - 现场快照

/// 只读查看页上那些行。
///
/// 这是一条**临时**的远程调试通道：客户开着页面，这边在浏览器里看这台机器现在
/// 是什么状态、日志尾巴是什么。所以它只收**能公开的**东西 —— IMEI、本机号码、
/// 短信内容压根不在下面这张表里。少写一行过滤，比多写一行过滤可靠。
@MainActor
enum DebugSnapshot {
    static var version: String {
        if let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !short.isEmpty { return short }
        return "1.0"
    }

    static func stamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func rows(model: AppModel) -> [(key: String, value: String)] {
        var rows: [(key: String, value: String)] = []
        rows.append(("连接", model.isConnected
                     ? "已连接（\(model.transport)）" : "未连接（\(model.transport)）"))
        rows.append(("型号", model.identity.model.isEmpty ? "未识别" : model.identity.model))
        rows.append(("版本", model.identity.revision.isEmpty ? "—" : model.identity.revision))
        rows.append(("构建", model.identity.firmwareBuild.isEmpty
                     ? "—" : model.identity.firmwareBuild))
        rows.append(("SIM", model.sim.ready ? "\(model.sim.shortLabel)（已就绪）" : model.sim.shortLabel))
        rows.append(("运营商", model.network.carrier.name.isEmpty
                     ? "—" : model.network.carrier.name))
        let technology = model.network.accessTechnology.isEmpty
            ? (model.isConnected ? "—" : "离线") : model.network.accessTechnology
        rows.append(("网络", model.network.band.isEmpty
                     ? technology : "\(technology) · \(model.network.band)"))
        let rssi = model.signal.rssiDBm.map { "\($0) dBm" } ?? "—"
        let csq = model.signal.rssiIndex == 99 ? "—" : "\(model.signal.rssiIndex)"
        rows.append(("信号", "\(rssi)（CSQ \(csq)）"))
        var data = model.data.apn.isEmpty ? "APN 未设置" : "APN \(model.data.apn)"
        if !model.data.interfaceName.isEmpty { data += " · 网卡 \(model.data.interfaceName)" }
        data += model.data.pdpActive ? " · PDP 已激活" : " · PDP 未激活"
        rows.append(("数据", data))
        // 通话只报状态，不报号码；短信只报条数，不报内容。这两条也是
        // 「页面可以给任何人看」的前提。
        rows.append(("通话", model.call.state.label))
        rows.append(("短信", "收到 \(model.messages.count) 条（未读 \(model.unreadCount)）"))
        rows.append(("最近动作", AppLog.milestone))
        return rows
    }

    static func status(model: AppModel, machine: MachineInfo, now: Date = Date()) -> String {
        var lines = [
            "时间：\(stamp(now))",
            "工具：\(version) · macOS \(machine.macOS) · \(machine.chip) · \(machine.architecture)",
            ""
        ]
        for row in rows(model: model) { lines.append("\(row.key)：\(row.value)") }
        return lines.joined(separator: "\n")
    }

    static func log(_ tail: [String]) -> String {
        tail.isEmpty ? "（还没有日志）" : tail.joined(separator: "\n")
    }
}

// MARK: - 只读查看页

/// 一个**只读**的临时网页：这台机器现在什么状态、日志尾巴是什么。
///
/// 它是远程排障用的临时通道，用完就删，所以刻意做得很小很窄 ——
///
/// - **只读**：只认 GET / HEAD，别的动词一律 405。没有第二个写入口。
/// - **认钥匙**：地址里那 16 位随机码不对就是 404，根路径什么都不给 ——
///   同一张 Wi-Fi 上有人扫端口，扫到的是一堵墙。
/// - **会自己关**：`lifetime` 到点自己停，客户也可以随时关掉。
/// - **没有敏感信息**：页面上的行来自 `DebugSnapshot`，那里面根本没有
///   IMEI、号码和短信内容。
final class ReadOnlyPage: @unchecked Sendable {
    /// 页面自己活多久。够这边看完一眼，又不至于开着过夜。
    static let lifetime: TimeInterval = 600
    /// 页面上放多少行日志。
    static let logLines = 60

    static let shared = ReadOnlyPage()

    /// 一张网卡对「别人连不连得过来」的分类。
    enum Reach: Equatable {
        /// Wi-Fi、以太网：同一个网络里的另一台机器打得开。
        case wifi
        /// Tailscale 发的那种地址：异地也打得开。
        case tailscale
        /// 模块自己的 USB 网卡、雷雳桥接、iPhone USB 共享：只有本机打得开。
        case local
    }

    struct Address: Identifiable {
        var label: String
        var note: String
        var url: String
        var isTailscale: Bool
        /// 只有本机打得开的那一类。列出来纯粹是没别的可列了。
        var isLocalOnly: Bool
        var id: String { url }
    }

    enum PageError: LocalizedError {
        case timeout
        case listener(String)

        var errorDescription: String? {
            switch self {
            case .timeout: return "查看页没能起来（端口没开成）"
            case .listener(let text): return "查看页没能起来：\(text)"
            }
        }
    }

    let token: String

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "local.dji4g.readonly-page")
    private var listener: NWListener?
    private var stopTimer: DispatchSourceTimer?
    private var portValue: UInt16?
    private var deadlineValue: Date?
    private var status = "正在读取…"
    private var log = "正在读取…"

    init(token: String = ReadOnlyPage.newToken()) {
        self.token = token
    }

    /// 要念给对方听的那串码：去掉了 `0 o 1 l i`，剩下的打出来不会认错。
    static func newToken() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0 ..< 16).map { _ in
            alphabet[Int.random(in: 0 ..< alphabet.count, using: &generator)]
        })
    }

    // MARK: 状态

    var isRunning: Bool { port != nil }

    var port: UInt16? {
        lock.lock(); defer { lock.unlock() }
        return portValue
    }

    var deadline: Date? {
        lock.lock(); defer { lock.unlock() }
        return deadlineValue
    }

    /// 页面上那两段文字。主线程每秒推一次，看的人那边只是读。
    func update(status: String, log: String) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
        self.log = log
    }

    // MARK: 开 / 关

    /// 起监听，等它真的开起来，返回端口号。
    ///
    /// 会阻塞最多 `timeout` 秒，调用方放在后台队列上等（见 `RemoteDebugModel`），
    /// 别在主线程上叫它。
    @discardableResult
    func startAndWait(timeout: TimeInterval = 3) throws -> UInt16 {
        stop()

        let parameters = NWParameters.tcp
        // 上一次关掉之后端口还可能在 TIME_WAIT 里；不然客户连点两下就会失败。
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)

        let ready = DispatchSemaphore(value: 0)
        var opened: UInt16?
        var failure: String?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // 端口只在 `.ready` 这一刻是准的，而且必须在这个回调里读走。
                opened = listener.port?.rawValue
                ready.signal()
            case .failed(let error):
                failure = error.localizedDescription
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + timeout) == .success else {
            discard(listener)
            throw PageError.timeout
        }
        guard let port = opened else {
            discard(listener)
            throw PageError.listener(failure ?? "端口没开成")
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.lifetime)
        timer.setEventHandler { [weak self] in self?.stop() }
        timer.resume()

        lock.lock()
        self.listener = listener
        self.stopTimer = timer
        self.portValue = port
        self.deadlineValue = Date().addingTimeInterval(Self.lifetime)
        lock.unlock()
        return port
    }

    func stop() {
        lock.lock()
        let listener = self.listener
        let timer = self.stopTimer
        self.listener = nil
        self.stopTimer = nil
        self.portValue = nil
        self.deadlineValue = nil
        lock.unlock()

        timer?.cancel()
        guard let listener else { return }
        discard(listener)
    }

    private func discard(_ listener: NWListener) {
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        listener.cancel()
    }

    // MARK: 地址

    /// 客户机器上的可用地址。
    ///
    /// 只列**别人也连得过来**的那些：Wi-Fi／以太网，以及 Tailscale。模块自己那张
    /// USB 网卡（这台机器上系统管它叫 `Baiwang`，地址 192.168.225.x）和雷雳桥接
    /// 只有本机打得开，混在里面会被照着敲一遍然后打不开 —— 一开始就是这么错的。
    /// 真的一条能连的都没有（Wi-Fi 关着、也没装 Tailscale）才退回列全部，
    /// 免得那一栏空着，反而不知道端口是不是起来了。
    static func addresses(port: UInt16, token: String) -> [Address] {
        let cards = interfaces()
        let connectable = cards.filter { $0.reach != .local }
        let shown = connectable.isEmpty ? cards : connectable

        func make(_ card: (name: String, port: String, ip: String, reach: Reach)) -> Address {
            let url = "http://\(card.ip):\(port)/\(token)/"
            switch card.reach {
            case .wifi:
                return Address(label: "\(card.port)（\(card.ip)）", note: "同一个 Wi-Fi 可用",
                               url: url, isTailscale: false, isLocalOnly: false)
            case .tailscale:
                return Address(label: "Tailscale（\(card.ip)）", note: "异地可用",
                               url: url, isTailscale: true, isLocalOnly: false)
            case .local:
                return Address(label: "\(card.port)（\(card.ip)）", note: "只有本机打得开",
                               url: url, isTailscale: false, isLocalOnly: true)
            }
        }

        // 同一张网里的排在前面，异地那条是备选。
        return shown.filter { $0.reach != .tailscale }.map(make)
             + shown.filter { $0.reach == .tailscale }.map(make)
    }

    /// 这张网卡别人连不连得过来。写成纯函数是为了能在自检里钉死：
    /// 模块自己的 USB 网卡绝不能再被报成「同一个 Wi-Fi 可用」。
    static func reach(port: String, type: String, ip: String) -> Reach {
        if isTailscale(ip) { return .tailscale }
        if type == "IEEE80211" || port == "Wi-Fi" || port == "AirPort" { return .wifi }
        // 有线以太网也是同一张网，Mac mini 那种机器上就是靠它。
        if port == "Ethernet" || port == "以太网" { return .wifi }
        return .local
    }

    /// Tailscale 发给每台机器的是 `100.64.0.0/10` 里的地址。
    static func isTailscale(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64 ... 127).contains(parts[1])
    }

    /// 本机所有上着的、非回环的 IPv4 地址。
    private static func interfaces() -> [(name: String, port: String, ip: String, reach: Reach)] {
        let ports = hardwarePorts()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [(name: String, port: String, ip: String, reach: Reach)] = []
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = node {
            let entry = pointer.pointee
            node = entry.ifa_next
            guard let address = entry.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            // 169.254 是「网线插着但没谈成」的自分配地址，换台机器也打不开。
            guard !ip.isEmpty, !ip.hasPrefix("127."), !ip.hasPrefix("169.254.") else { continue }

            let name = String(cString: entry.ifa_name)
            let hardware = ports[name] ?? (port: name, type: "")
            found.append((name: name, port: hardware.port, ip: ip,
                          reach: reach(port: hardware.port, type: hardware.type, ip: ip)))
        }
        return found
    }

    /// BSD 名字（`en0`）到「系统里这个口叫什么」的对照表。
    ///
    /// 光看 `en0`/`en59` 分不清哪张网卡是 Wi-Fi —— 而 Wi-Fi 和别人连不过来的
    /// 模块 USB 网卡都得靠这个区分。系统自己的名字很直白：这台机器上 `en0` 是
    /// `Wi-Fi`，模块那张是模块厂商 `Baiwang`。
    private static func hardwarePorts() -> [String: (port: String, type: String)] {
        var table: [String: (port: String, type: String)] = [:]
        let cards = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        for card in cards {
            guard let bsd = SCNetworkInterfaceGetBSDName(card) as String? else { continue }
            let port = SCNetworkInterfaceGetLocalizedDisplayName(card) as String? ?? bsd
            let type = SCNetworkInterfaceGetInterfaceType(card) as String? ?? ""
            table[bsd] = (port: port, type: type)
        }
        return table
    }

    // MARK: 收发

    private func handle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak connection] state in
            guard let connection, case .ready = state else { return }
            connection.stateUpdateHandler = nil
            self.collect(connection, collected: Data())
        }
        connection.start(queue: queue)
    }

    /// 收请求头。
    ///
    /// TCP 会把一个请求切成几段，所以这里攒到头部那个空行再开口 —— 按第一段
    /// 就回话，会随请求大小偶发地回出 400，而且只在某些浏览器上出现。
    private func collect(_ connection: NWConnection, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, _ in
            var buffer = collected
            if let data { buffer.append(data) }
            let text = String(decoding: buffer, as: UTF8.self)
            guard text.contains("\r\n\r\n") || text.contains("\n\n")
                    || complete || buffer.count >= 16_384 else {
                self.collect(connection, collected: buffer)
                return
            }
            connection.send(content: self.response(for: text),
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// 请求 → 应答。这份功能里唯一的判断，四件事按顺序问：是谁（路径里的码
    /// 对不对）、用什么动词（只准读）、要哪一段、其余一律 404。
    private func response(for request: String) -> Data {
        // 请求行是 CRLF 结尾，而 Swift 把 `\r\n` 当成**一个** Character：
        // `split(separator: "\n")` 切不开它，会连整段一起当成一行。按
        // `isNewline` 判才认得出 CRLF / LF / CR 三种写法。
        let head = request.split(whereSeparator: { $0.isNewline })
            .first.map(String.init) ?? ""
        let parts = head.split(separator: " ").map(String.init)
        guard parts.count >= 2 else {
            return reply(400, "text/plain; charset=utf-8", "看不懂的请求。")
        }

        let method = parts[0].uppercased()
        guard method == "GET" || method == "HEAD" else {
            return reply(405, "text/plain; charset=utf-8",
                         "本页只读：用浏览器打开就行。")
        }

        let base = "/\(token)"
        let path = parts[1]
        // 没带钥匙的请求连「这个端口上有人」都不告诉它：根路径和错码一样 404。
        guard path == base || path.hasPrefix(base + "/") else {
            return reply(404, "text/plain; charset=utf-8", "404")
        }

        lock.lock()
        let (status, log) = (self.status, self.log)
        lock.unlock()

        switch String(path.dropFirst(base.count)) {
        case "", "/":
            return reply(200, "text/html; charset=utf-8",
                         page(status: status, log: log), headOnly: method == "HEAD")
        case "/status":
            return reply(200, "text/plain; charset=utf-8", status, headOnly: method == "HEAD")
        case "/log":
            return reply(200, "text/plain; charset=utf-8", log, headOnly: method == "HEAD")
        default:
            return reply(404, "text/plain; charset=utf-8", "404")
        }
    }

    private func reply(_ code: Int, _ type: String, _ body: String,
                       headOnly: Bool = false) -> Data {
        let phrase: String
        switch code {
        case 200: phrase = "OK"
        case 400: phrase = "Bad Request"
        case 404: phrase = "Not Found"
        case 405: phrase = "Method Not Allowed"
        default: phrase = "Error"
        }
        let payload = Data(body.utf8)
        var head = "HTTP/1.1 \(code) \(phrase)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return headOnly ? Data(head.utf8) : Data(head.utf8) + payload
    }

    private func page(status: String, log: String) -> String {
        """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>DJI 4G · 只读查看</title>
        <style>
        :root { color-scheme: dark; }
        body { margin: 0; padding: 20px 16px 36px; background: #0d1210; color: #cfe8d8;
               font: 13px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; }
        h1 { margin: 0 0 4px; font-size: 14px; letter-spacing: .06em; color: #5ef287; }
        h2 { margin: 20px 0 7px; font-size: 11px; letter-spacing: .12em; color: #5ef287; }
        pre { margin: 0; padding: 11px 13px; background: #0a0f0d; border: 1px solid #1c2a22;
              border-radius: 10px; white-space: pre-wrap; word-break: break-word; color: #b9d8c6; }
        p { margin: 0; font-size: 11px; color: #6f8c7c; }
        #at { margin-top: 22px; }
        </style>
        </head>
        <body>
        <h1>DJI 4G · 只读查看</h1>
        <p>每 3 秒自动刷新 · 只读 · 关掉开关或 \(Int(Self.lifetime / 60)) 分钟到点就失效</p>
        <h2>模块状态</h2>
        <pre id="status">\(escape(status))</pre>
        <h2>运行日志</h2>
        <pre id="log">\(escape(log))</pre>
        <p id="at"></p>
        <script>
        (function () {
          var base = location.pathname;
          if (base.slice(-1) !== "/") { base += "/"; }
          function pull(name, node) {
            fetch(base + name, { cache: "no-store" })
              .then(function (r) { return r.ok ? r.text() : Promise.reject(r.status); })
              .then(function (t) { node.textContent = t; })
              .catch(function (e) { node.textContent = "读取失败（" + e + "）"; });
          }
          function tick() {
            pull("status", document.getElementById("status"));
            pull("log", document.getElementById("log"));
            document.getElementById("at").textContent =
              "最后刷新 " + new Date().toLocaleTimeString("zh-CN", { hour12: false });
          }
          tick();
          setInterval(tick, 3000);
        })();
        </script>
        </body>
        </html>
        """
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: 自检用

    /// 无头自检里打一次本机 HTTP，只看状态码。
    ///
    /// 用裸 socket 而不是 `URLSession`：这一段跑在 `init()` 里，AppKit 的 run
    /// loop 还没转起来，而这里要的只是「服务器会不会按那三条规矩回话」。
    static func probe(port: UInt16, request: String) -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        let outbound = Array(request.utf8)
        guard outbound.withUnsafeBufferPointer({ write(fd, $0.baseAddress, $0.count) }) > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: 4_096)
        let got = read(fd, &buffer, buffer.count)
        guard got > 0 else { return nil }
        let parts = String(decoding: buffer[0 ..< got], as: UTF8.self)
            .split(separator: " ").map(String.init)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/") else { return nil }
        return Int(parts[1])
    }
}

// MARK: - 那一行界面

/// 「远程调试」的状态：地址表、报错、以及每秒往页面上推的现场。
@MainActor
final class RemoteDebugModel: ObservableObject {
    @Published private(set) var addresses: [ReadOnlyPage.Address] = []
    @Published private(set) var failure: String?

    var isRunning: Bool { ReadOnlyPage.shared.isRunning }

    var deadline: Date? { ReadOnlyPage.shared.deadline }

    func toggle() {
        let page = ReadOnlyPage.shared
        if page.isRunning {
            page.stop()
            addresses = []
            failure = nil
            return
        }
        failure = nil
        Task {
            do {
                let port = try await Self.open(page)
                addresses = ReadOnlyPage.addresses(port: port, token: page.token)
            } catch {
                failure = error.localizedDescription
                addresses = []
            }
        }
    }

    /// 每秒一次。页面关着就什么都不做 —— 日志尾巴是「实时」的代价所在，
    /// 没必要在没人看的时候每秒读一遍文件。
    func refresh(model: AppModel, machine: MachineInfo) {
        let page = ReadOnlyPage.shared
        guard let port = page.port else {
            if !addresses.isEmpty { addresses = [] }
            return
        }
        if addresses.isEmpty {
            addresses = ReadOnlyPage.addresses(port: port, token: page.token)
        }
        page.update(
            status: DebugSnapshot.status(model: model, machine: machine),
            log: DebugSnapshot.log(LogTail.read(lines: ReadOnlyPage.logLines,
                                                maxBytes: 65_536)))
    }

    /// `startAndWait` 会阻塞最多几秒，不能压在主线程上。
    private static func open(_ page: ReadOnlyPage) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try page.startAndWait()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// 「远程调试」那一行。
///
/// 这是整份功能唯一的入口，也是刻意做得最小的一处：默认收成一行，点开才有
/// 一个开关和几条地址。它是一段**临时**通道，用来把方案打磨到位，不需要了
/// 就把这一行和 `RemoteDebug.swift` 一起删掉，别处没有牵连。
struct RemoteDebugSection: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var debug = RemoteDebugModel()
    @State private var expanded = false
    @State private var now = Date()
    @State private var machine = MachineInfo.current()

    /// 只有截图会传展开态 —— 收起来是客户看到的样子，摊开的样子也得有人过目。
    init(expanded: Bool = false) {
        _expanded = State(initialValue: expanded)
    }

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("远程调试").label(10).foregroundStyle(Theme.ink)
                    // 开着才写「还剩多久」；没开就一个字都不写 ——
                    // 「关着」这种口语状态词不该占客户的地方。
                    if !caption.isEmpty {
                        Text(caption).label(9).foregroundStyle(Theme.inkNote)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    Button(debug.isRunning ? "关掉查看页" : "开启只读查看页") { debug.toggle() }
                        .label(10)
                        .buttonStyle(.plain)
                        .foregroundStyle(debug.isRunning ? Theme.alertInk : Theme.ink)
                        // 摊在页面上的那段说明收进悬停：只读、看不到什么、
                        // 多少分钟自己关，还有第一次开时系统会问的那一句。
                        .help("开一个只能看的临时网页：状态 + 日志最后 \(ReadOnlyPage.logLines) 行。"
                              + "不改任何设置，看不到 IMEI、号码和短信；"
                              + "\(Int(ReadOnlyPage.lifetime / 60)) 分钟自己关。"
                              + "第一次开的时候 macOS 可能会问「是否允许接受传入连接」，点允许。")

                    if debug.isRunning {
                        ForEach(debug.addresses) { address in
                            Button { copy(address.url) } label: {
                                HStack(spacing: 6) {
                                    Text(address.label).label(9).foregroundStyle(Theme.ink)
                                    Text(address.note).label(9).foregroundStyle(Theme.inkNote)
                                    Spacer()
                                    Text("复制").label(9).foregroundStyle(Theme.phosphorInk)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(address.url)
                        }
                    }

                    if let failure = debug.failure {
                        Text(failure).label(9).foregroundStyle(Theme.alertInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onReceive(tick) { moment in
            now = moment
            debug.refresh(model: model, machine: machine)
        }
        .onAppear { debug.refresh(model: model, machine: machine) }
    }

    private var caption: String {
        guard let deadline = debug.deadline else { return "" }
        let left = max(0, Int(deadline.timeIntervalSince(now).rounded()))
        return String(format: "只读查看页开着 · 还剩 %d:%02d", left / 60, left % 60)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
