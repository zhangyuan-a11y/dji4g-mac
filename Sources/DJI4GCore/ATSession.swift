import Foundation

public enum ATFinal: Equatable {
    case ok
    case error
    case cme(Int)
    case cms(Int)
    case other(String)
    case timeout
    case closed
    case prompt

    public var isOK: Bool { self == .ok }

    public var text: String {
        switch self {
        case .ok: return "OK"
        case .error: return "ERROR"
        case .cme(let code): return "+CME ERROR: \(code)"
        case .cms(let code): return "+CMS ERROR: \(code)"
        case .other(let value): return value
        case .timeout: return "TIMEOUT"
        case .closed: return "CLOSED"
        case .prompt: return "PROMPT"
        }
    }
}

public struct ATResponse {
    public init(command: String, lines: [String], final: ATFinal, unsolicited: [String]) {
        self.command = command
        self.lines = lines
        self.final = final
        self.unsolicited = unsolicited
    }

    public let command: String
    /// Informational lines returned between the echo and the final result.
    public let lines: [String]
    public let final: ATFinal
    /// Unsolicited lines that arrived while this command was in flight.
    public let unsolicited: [String]

    public var isOK: Bool { final.isOK }

    /// Everything the module said, in order, excluding the echoed command.
    public var rawText: String { lines.joined(separator: "\n") }

    public func firstValue(for prefix: String) -> String? {
        let lowered = prefix.lowercased()
        for line in lines where Self.matches(line, lowered) {
            if let colon = line.firstIndex(of: ":") {
                return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            return line
        }
        return nil
    }

    public func values(for prefix: String) -> [String] {
        let lowered = prefix.lowercased()
        return lines.filter { Self.matches($0, lowered) }.map {
            if let colon = $0.firstIndex(of: ":") {
                return String($0[$0.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            return $0
        }
    }

    /// 前缀匹配时**允许行首多一个 `+`**。
    ///
    /// 模块回的信息行形状是 `+QADBKEY: 27454934`、`+QCFG: "usbcfg",…`，
    /// 而调用方有的写 `"+QCFG"`、有的写 `"QCFG"`。以前只认前者，于是
    /// `AT+QADBKEY?` 明明回了挑战值，`firstValue(for: "QADBKEY")` 照样返回
    /// nil，界面报「读不到 ADB 挑战值：+QADBKEY: 27454934」—— 值就在报错里
    /// 摆着。这里放宽一步，两种写法都算命中。
    static func matches(_ line: String, _ loweredPrefix: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix(loweredPrefix) { return true }
        guard lowered.hasPrefix("+") else { return false }
        return lowered.dropFirst().hasPrefix(loweredPrefix)
    }

    /// A single line matching `prefix` exactly, ignoring case.
    public func line(equalTo text: String) -> String? {
        let upper = text.uppercased()
        return lines.first { $0.uppercased() == upper }
    }
}

/// Serializes AT traffic over a transport, waits for final results, and routes
/// unsolicited result codes (incoming SMS, incoming call, network changes) to
/// the owner.
///
/// - Note: every callback fires *after* the internal lock is released, so a
///   handler may safely call back into the session (for example `close()`).
public final class ATSession {
    public typealias TransportFactory = () throws -> ATTransport

    private let lock = NSLock()
    private let factory: TransportFactory
    private var transport: ATTransport?
    private var buffer: [UInt8] = []

    /// 这条会话**曾经真的开通过**吗。只用来回答一个问题：「断开」这两个字
    /// 该不该说出口。
    ///
    /// 以前只要一次发送撞上关着的通道就报 `onTransportLost`，于是**从头到尾
    /// 没插模块**的机器也会在日志和活动列表里刷「模块断开：通道已关闭」——
    /// 2026-09-29 一整天一次都没连上，却记了 20 次「断开」，客户翻到只会以为
    /// 它一直在掉线。没开通过就谈不上断开，那是「没连上」，调用方手上那条抛错
    /// 已经把它说得清清楚楚了。
    private var hadOpenChannel = false

    /// How long an idle line may sit in the buffer before it is treated as a
    /// complete line anyway. Some firmware omits the trailing CR of the last
    /// line of a multi-line response when the host drains it in one read.
    private var idleFlushInterval: TimeInterval = 0.12
    private var lastChunkAt = Date.distantPast

    private static let urcPrefixes = [
        "RING", "NO CARRIER", "BUSY", "NO ANSWER", "+CLIP", "+CCWA", "+CCFC",
        "+CMTI", "+CMT:", "+CRING", "+CUSD", "+CDS", "+QIND", "+QUSIM",
        "+CPIN:", "+CGREG:", "+CEREG:", "+CREG:", "+QNETSTATUS", "+QMTSTAT",
        "+QUSIM:", "^SYSINFO", "+CIEV", "+CALLSTAT", "+QLTS", "+QSIMSTAT",
        "+QUSIM", "+QCFG", "+QCSQ", "+QNWINFO", "RDY", "+QENG"
    ]

    public var onUnsolicited: (([String]) -> Void)?
    public var onTransportLost: ((Error) -> Void)?

    public init(factory: @escaping TransportFactory) {
        self.factory = factory
    }

    public var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return transport?.isOpen ?? false
    }

    public var channelDescription: String {
        lock.lock(); defer { lock.unlock() }
        return transport?.describe ?? "未连接"
    }

    public func open() throws {
        lock.lock(); defer { lock.unlock() }
        if transport?.isOpen == true { return }
        let fresh = try factory()
        try fresh.open()
        transport = fresh
        hadOpenChannel = true
        buffer.removeAll()
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        transport?.close()
        transport = nil
        // 自己关的不算断开：调用方（重启模块、收摊）本来就知道自己在干什么。
        hadOpenChannel = false
        buffer.removeAll()
    }

    // MARK: - Sending

    @discardableResult
    public func send(_ command: String,
                     timeout: TimeInterval = 5,
                     stopOnPrompt: Bool = false,
                     expects: [String] = []) throws -> ATResponse {
        lock.lock()
        var lost: Error?
        // 发这条命令之前通道是活的吗 —— 见 `hadOpenChannel`。
        let wasLive = hadOpenChannel
        do {
            let response = try sendLocked(command, timeout: timeout,
                                          stopOnPrompt: stopOnPrompt, expects: expects)
            let alive = transport?.isOpen ?? false
            if alive { hadOpenChannel = true }
            lock.unlock()
            if alive {
                dispatch(response.unsolicited)
            } else if wasLive {
                onTransportLost?(ATTransportError.closed)
            }
            return response
        } catch {
            if wasLive, transport?.isOpen != true { lost = error }
            lock.unlock()
            if let lost { onTransportLost?(lost) }
            throw error
        }
    }

    /// Sends raw bytes without appending CR — used to terminate a text-mode SMS
    /// body with Ctrl-Z after the module answered with a prompt.
    @discardableResult
    public func sendRaw(_ bytes: [UInt8], timeout: TimeInterval = 30) throws -> ATResponse {
        lock.lock()
        let wasLive = hadOpenChannel
        do {
            let response = try sendRawLocked(bytes, timeout: timeout)
            let alive = transport?.isOpen ?? false
            if alive { hadOpenChannel = true }
            lock.unlock()
            if alive {
                dispatch(response.unsolicited)
            } else if wasLive {
                onTransportLost?(ATTransportError.closed)
            }
            return response
        } catch {
            let lost: Error? = (wasLive && transport?.isOpen != true) ? error : nil
            lock.unlock()
            if let lost { onTransportLost?(lost) }
            throw error
        }
    }

    /// 把模块从「正在收短信正文」的状态里拉出来。
    ///
    /// `AT+CMGS=…` 之后模块回一个 `>`，在拿到 Ctrl-Z 之前它把随后的每个
    /// 字节都当短信正文 —— 包括我们发的 `AT`。所以只要有一次发送在中途
    /// 失败（USB 读超时最常见），这个端口就「看起来死了」：之后发什么都
    /// 换不到 OK，客户只能把模块拔下来重插，还会以为自己弄坏了它。
    /// ESC 是那个提示符的正当出口。
    ///
    /// 这里不用 `send`：那条路会给命令补一个 CR，而此刻多一个 CR 就是多
    /// 一行短信正文。写完顺手把模块回的那行 ERROR 读掉，免得它污染下一
    /// 条命令的应答。
    public func abortDataEntry() {
        lock.lock()
        defer { lock.unlock() }
        guard let transport, transport.isOpen else { return }
        _ = try? transport.write([0x1B])
        _ = try? transport.read(maxLength: 256, timeoutMs: 400)
    }

    /// Reads whatever the module pushed without sending a command.
    public func pollUnsolicited(timeout: TimeInterval = 0.3) -> [String] {
        lock.lock()
        guard let transport, transport.isOpen else {
            lock.unlock()
            return []
        }

        var collected: [String] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            let slice = Int(max(0.05, min(0.25, remaining)) * 1000)
            do {
                let chunk = try transport.read(maxLength: 4096, timeoutMs: slice)
                guard !chunk.isEmpty else { continue }
                buffer.append(contentsOf: chunk)
                lastChunkAt = Date()
            } catch ATTransportError.timeout {
                continue
            } catch {
                break
            }
        }
        var drained = Self.drainLines(&buffer)
        if let stale = Self.flushPartial(&buffer) { drained.append(stale) }
        for line in drained {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { collected.append(trimmed) }
        }
        lock.unlock()

        if !collected.isEmpty { dispatch(collected) }
        return collected
    }

    private func dispatch(_ lines: [String]) {
        guard !lines.isEmpty, let handler = onUnsolicited else { return }
        handler(lines)
    }

    // MARK: - Locked internals

    private func sendLocked(_ command: String,
                            timeout: TimeInterval,
                            stopOnPrompt: Bool,
                            expects: [String]) throws -> ATResponse {
        guard let transport, transport.isOpen else {
            throw ATTransportError.closed
        }

        buffer.removeAll()
        var payload = Array(command.utf8)
        payload.append(0x0D)
        try transport.write(payload)

        let deadline = Date().addingTimeInterval(timeout)
        var informational: [String] = []
        var urcs: [String] = []
        var sawEcho = false
        lastChunkAt = Date()

        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            let slice = Int(max(0.15, min(0.5, remaining)) * 1000)

            let chunk: [UInt8]
            do {
                chunk = try transport.read(maxLength: 4096, timeoutMs: slice)
            } catch ATTransportError.timeout {
                guard Date().timeIntervalSince(lastChunkAt) >= idleFlushInterval,
                      !buffer.isEmpty,
                      let stale = Self.flushPartial(&buffer) else { continue }
                let trimmed = stale.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if let final = Self.finalResult(for: trimmed, stopOnPrompt: stopOnPrompt) {
                    return ATResponse(command: command, lines: informational,
                                      final: final, unsolicited: urcs)
                }
                if Self.isUnsolicited(trimmed, prefixes: Self.urcPrefixes,
                                      expects: expects, command: command) {
                    urcs.append(trimmed)
                } else {
                    informational.append(trimmed)
                }
                continue
            } catch {
                throw error
            }

            guard !chunk.isEmpty else { continue }
            buffer.append(contentsOf: chunk)
            lastChunkAt = Date()

            for line in Self.drainLines(&buffer) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if !sawEcho {
                    sawEcho = true
                    // The module echoes the command back first; drop it.
                    if trimmed.uppercased() == command.uppercased() { continue }
                }
                if let final = Self.finalResult(for: trimmed, stopOnPrompt: stopOnPrompt) {
                    return ATResponse(command: command, lines: informational,
                                      final: final, unsolicited: urcs)
                }
                if Self.isUnsolicited(trimmed, prefixes: Self.urcPrefixes,
                                      expects: expects, command: command) {
                    urcs.append(trimmed)
                    continue
                }
                informational.append(trimmed)
            }
        }

        return ATResponse(command: command, lines: informational, final: .timeout, unsolicited: urcs)
    }

    private func sendRawLocked(_ bytes: [UInt8], timeout: TimeInterval) throws -> ATResponse {
        guard let transport, transport.isOpen else { throw ATTransportError.closed }
        try transport.write(bytes)

        let deadline = Date().addingTimeInterval(timeout)
        var informational: [String] = []
        var urcs: [String] = []
        var sawEcho = false
        lastChunkAt = Date()

        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            let slice = Int(max(0.15, min(0.5, remaining)) * 1000)
            let chunk: [UInt8]
            do {
                chunk = try transport.read(maxLength: 4096, timeoutMs: slice)
            } catch ATTransportError.timeout {
                continue
            }
            guard !chunk.isEmpty else { continue }
            buffer.append(contentsOf: chunk)
            lastChunkAt = Date()

            for line in Self.drainLines(&buffer) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if !sawEcho {
                    sawEcho = true
                    continue
                }
                if let final = Self.finalResult(for: trimmed, stopOnPrompt: false) {
                    return ATResponse(command: "<raw>", lines: informational,
                                      final: final, unsolicited: urcs)
                }
                if Self.isUnsolicited(trimmed, prefixes: Self.urcPrefixes, expects: []) {
                    urcs.append(trimmed)
                    continue
                }
                informational.append(trimmed)
            }
        }

        return ATResponse(command: "<raw>", lines: informational, final: .timeout, unsolicited: urcs)
    }

    // MARK: - Parsing helpers

    /// Splits complete CR/LF-terminated lines out of the buffer; a trailing
    /// partial line stays buffered so it can join the rest of its bytes.
    private static func drainLines(_ buffer: inout [UInt8]) -> [String] {
        var lines: [String] = []
        var current: [UInt8] = []
        var index = 0
        while index < buffer.count {
            let byte = buffer[index]
            if byte == 0x0D || byte == 0x0A {
                if !current.isEmpty {
                    lines.append(String(decoding: current, as: UTF8.self))
                    current.removeAll()
                }
                index += 1
                continue
            }
            current.append(byte)
            index += 1
        }
        buffer = current
        return lines
    }

    /// Emits a line that never received its CR/LF. Some firmware releases the
    /// last line of a response without a terminator; without this it would sit
    /// in the buffer and corrupt the next command's reply.
    private static func flushPartial(_ buffer: inout [UInt8]) -> String? {
        guard !buffer.isEmpty else { return nil }
        let text = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        return text
    }

    /// Exposed so the self-test can replay recorded answers through the same
    /// classifier the live session uses.
    public static func finalResult(for line: String, stopOnPrompt: Bool) -> ATFinal? {
        if stopOnPrompt && line == ">" { return .prompt }
        let upper = line.uppercased()
        if upper == "OK" { return .ok }
        if upper.hasPrefix("ERROR") { return .error }
        if upper.hasPrefix("+CME ERROR") {
            return .cme(Self.trailingCode(upper))
        }
        if upper.hasPrefix("+CMS ERROR") {
            return .cms(Self.trailingCode(upper))
        }
        for value in ["NO CARRIER", "BUSY", "NO ANSWER", "NO DIALTONE", "CONNECT"] {
            if upper == value { return .other(value) }
        }
        return nil
    }

    private static func trailingCode(_ line: String) -> Int {
        let tail = line.split(separator: ":").last.map(String.init) ?? ""
        let cleaned = tail.trimmingCharacters(in: .whitespaces)
        if let code = Int(cleaned) { return code }
        // `AT+CMEE=2` makes the module spell the error out instead of numbering
        // it ("SIM not inserted"). Folding the words back onto the 3GPP numbers
        // keeps one code path, and stops a known condition from being reported
        // as an unknown one.
        let words = cleaned.uppercased()
        if words.contains("NOT INSERTED") || words.contains("ABSENT") { return 10 }
        if words.contains("PUK") { return 12 }
        if words.contains("PIN") { return 11 }
        if words.contains("SIM FAILURE") || words.contains("SIM WRONG") { return 13 }
        if words.contains("SIM BUSY") { return 14 }
        if words.contains("OPERATION NOT ALLOWED") { return 3 }
        return -1
    }

    /// The AT token a line belongs to: "+CPIN" in "+CPIN: READY", "+QCFG" in
    /// `+QCFG: "usbcfg",...`.
    static func token(ofLine line: String) -> String? {
        let upper = line.uppercased()
        guard let start = upper.firstIndex(of: "+") else { return nil }
        let rest = upper[upper.index(after: start)...]
        let end = rest.firstIndex { $0 == ":" || $0 == "?" || $0 == "=" || $0 == " " } ?? rest.endIndex
        let token = String(rest[rest.startIndex..<end])
        return token.isEmpty ? nil : "+" + token
    }

    /// The AT token a command addresses: "AT+CPIN?" → "+CPIN",
    /// `AT+QCFG="usbcfg"` → "+QCFG". Basic commands like "ATI" have none.
    static func token(ofCommand command: String) -> String? {
        let upper = command.uppercased()
        guard upper.hasPrefix("AT") else { return nil }
        return token(ofLine: String(upper.dropFirst(2)))
    }

    /// A line is unsolicited only when it belongs to a *different* AT command
    /// than the one in flight. Without that check the answer to `AT+CPIN?`
    /// ("+CPIN: READY") looks exactly like the "+CPIN:" URC and re-enters the
    /// controller, which loops forever.
    private static func isUnsolicited(_ line: String,
                                      prefixes: [String],
                                      expects: [String],
                                      command: String? = nil) -> Bool {
        let upper = line.uppercased()
        for expected in expects where upper.hasPrefix(expected.uppercased()) {
            return false
        }
        guard prefixes.contains(where: { upper.hasPrefix($0.uppercased()) }) else {
            return false
        }
        if let command, let own = token(ofCommand: command), token(ofLine: line) == own {
            return false
        }
        return true
    }
}
