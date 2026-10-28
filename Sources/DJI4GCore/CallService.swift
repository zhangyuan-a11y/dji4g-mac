import Foundation

public enum CallDirection: String, Equatable {
    case outgoing
    case incoming
    case unknown

    public var label: String {
        switch self {
        case .outgoing: return "呼出"
        case .incoming: return "来电"
        case .unknown: return "通话"
        }
    }
}

public enum CallState: Equatable {
    case idle
    case dialing
    case alerting
    case ringing
    case active
    case held
    case waiting
    case ended

    public var isBusy: Bool {
        switch self {
        case .idle, .ended: return false
        default: return true
        }
    }

    public var label: String {
        switch self {
        case .idle: return "空闲"
        case .dialing: return "拨号中"
        case .alerting: return "对方振铃"
        case .ringing: return "来电响铃"
        case .active: return "通话中"
        case .held: return "保持中"
        case .waiting: return "等待接听"
        case .ended: return "已结束"
        }
    }

    /// TP-STAT from `AT+CLCC`.
    static func fromCLCC(_ code: Int) -> CallState {
        switch code {
        case 0: return .active
        case 1: return .held
        case 2: return .dialing
        case 3: return .alerting
        case 4: return .ringing
        case 5: return .waiting
        default: return .idle
        }
    }
}

public struct CallInfo: Equatable {
    public var index: Int
    public var direction: CallDirection
    public var state: CallState
    public var number: String
    public var startedAt: Date?
    /// 单调时钟起点（`systemUptime`）。墙钟可能被改时间/NTP 调跳，通话时长
    /// 必须用单调时钟算，进程内才不会忽长忽短。
    public var startedUptime: TimeInterval?

    public init(index: Int = 0, direction: CallDirection = .unknown,
                state: CallState = .idle, number: String = "", startedAt: Date? = nil,
                startedUptime: TimeInterval? = nil) {
        self.index = index
        self.direction = direction
        self.state = state
        self.number = number
        self.startedAt = startedAt
        self.startedUptime = startedUptime
    }

    public var duration: TimeInterval? {
        guard state == .active else { return nil }
        if let startedUptime {
            return ProcessInfo.processInfo.systemUptime - startedUptime
        }
        guard let startedAt else { return nil }
        return Date().timeIntervalSince(startedAt)
    }

    public var durationLabel: String {
        guard let duration else { return "--:--" }
        let total = Int(duration)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

public enum CallError: Error, CustomStringConvertible {
    /// Carries why the card is unusable, so the panel can name the real cause
    /// instead of repeating "SIM 未就绪" for a card that is simply not there.
    case noSIM(String)
    case rejected(ATFinal)

    public var description: String {
        switch self {
        case .noSIM(let reason): return "打不了电话：\(reason)"
        case .rejected(let final):
            let reason = ATFailure.explain(final) ?? "模块拒绝了这个操作"
            return "\(reason)（模块原话：\(final.text)）"
        }
    }
}

/// Voice call control over AT.
///
/// 这个类只管信令：拨号、接听、挂断、来电号码、通话等待。通话语音**不在
/// 这里**，也不在任何地方 —— 2026-09-25 的真机实测（三组，81920 个采样点
/// 全 0）证明一代模块的语音不进 USB 声卡。`VoiceService` 只是给换固件 /
/// 换模块的客户留的手动兜底，别指望它能把声音接上。
public final class CallService {
    private let session: ATSession
    private let lock = NSLock()

    public private(set) var current = CallInfo()
    public private(set) var log: [CallInfo] = []
    public var onStateChange: ((CallInfo) -> Void)?

    /// Last `+CLIP:` number seen while ringing.
    private var pendingCallerNumber: String = ""
    private var ringStartedAt: Date?
    /// The call that was up when a second caller got parked. Turning the
    /// waiting call away has to put the panel back on this one; the waiting
    /// caller's number is what `current` holds at that moment.
    private var callBeforeWaiting: CallInfo?

    public init(session: ATSession) {
        self.session = session
    }

    // MARK: - Configuration

    public func configure() throws {
        // Present the calling number to us when someone rings.
        _ = try session.send("AT+CLIP=1", timeout: 3)
        // Use the device as the audio source when the module supports it.
        _ = try session.send("AT+QAUDCH=0", timeout: 3)
        // Without this the module never emits `+CCWA`, so a second call
        // arriving during a conversation is silently dropped by the network.
        _ = try session.send("AT+CCWA=1", timeout: 3)
        // 按下去那一声有多长。出厂默认短得只剩一个响指，人工听着像没按下
        // 去，对方的自动接线台（「查话费请按 1」那一类）更认不出来 —— 按了
        // 没反应，客户只会以为键盘坏了。拉到 0.3 秒，跟手指按在电话机上
        // 差不多。
        //
        // 这一条不是所有厂家都收（`AT+VTD` 是 3GPP 的写法，单位十分之一
        // 秒）。配置阶段用 `try?` 安静过掉：不认的模块就当没这一条，绝不
        // 能因为一句「设时长」把前面三条好用的配置一起带沟里。
        _ = try? session.send("AT+VTD=3", timeout: 3)
    }

    // MARK: - Actions

    public func dial(_ number: String) throws {
        let cleaned = Self.sanitise(number)
        guard !cleaned.isEmpty else { throw CallError.rejected(.error) }
        // The trailing semicolon keeps the modem in voice mode.
        let response = try session.send("ATD\(cleaned);", timeout: 20)
        switch response.final {
        case .ok, .other("CONNECT"):
            update(state: .dialing, direction: .outgoing, number: cleaned)
        case .other(let value) where value == "NO CARRIER":
            update(state: .ended, direction: .outgoing, number: cleaned)
        default:
            if case .cme = response.final { throw CallError.rejected(response.final) }
            if case .error = response.final { throw CallError.rejected(response.final) }
            update(state: .dialing, direction: .outgoing, number: cleaned)
        }
    }

    public func answer() throws {
        // A waiting call is not ringing on its own — it is queued behind a call
        // that is already up, so `ATA` has nothing to answer. 3GPP exposes that
        // case through `AT+CHLD`, where 2 holds the current call and takes the
        // new one. Holding is the default because it is the reversible choice:
        // the caller on hold can be swapped back, a dropped one cannot.
        if current.state == .waiting {
            try acceptWaiting(holdCurrent: true)
            return
        }
        let response = try session.send("ATA", timeout: 20)
        guard response.final == .ok || response.final == .other("CONNECT") else {
            throw CallError.rejected(response.final)
        }
        update(state: .active, direction: .incoming, number: current.number)
    }

    /// Takes the waiting call. `holdCurrent` keeps the existing call on hold
    /// (`AT+CHLD=2`); passing false drops it instead (`AT+CHLD=1`).
    public func acceptWaiting(holdCurrent: Bool = true) throws {
        let response = try session.send("AT+CHLD=\(holdCurrent ? 2 : 1)", timeout: 15)
        guard response.final == .ok else { throw CallError.rejected(response.final) }
        callBeforeWaiting = nil
        update(state: .active, direction: .incoming, number: current.number)
    }

    /// Turns a waiting call away without touching the call in progress.
    /// `AT+CHUP` would hang up *everything*, including the conversation.
    public func releaseWaiting() throws {
        let response = try session.send("AT+CHLD=0", timeout: 15)
        guard response.final == .ok else { throw CallError.rejected(response.final) }
        // `current` still names the caller we just turned away. Restoring the
        // interrupted conversation from memory beats leaving the rejected
        // number on screen labelled "通话中".
        if var previous = callBeforeWaiting {
            if previous.state == .held { previous.state = .active }
            previous.startedAt = previous.startedAt ?? Date()
            previous.startedUptime = previous.startedUptime ?? ProcessInfo.processInfo.systemUptime
            update(info: previous)
        } else {
            _ = try? refresh()
        }
        callBeforeWaiting = nil
    }

    public func hangup() throws {
        let response = try session.send("AT+CHUP", timeout: 15)
        if response.final != .ok {
            let fallback = try session.send("ATH", timeout: 15)
            guard fallback.final == .ok || fallback.final == .error else {
                throw CallError.rejected(response.final)
            }
        }
        update(state: .idle, direction: current.direction, number: "")
    }

    /// 模块整个不在了（客户拔线、模块自己重启、AT 口被别的程序抢走）。
    ///
    /// 这种时候电话不可能还接着 —— 可这个类里没有第二处会说出这件事：
    /// `refresh()` 要一个还能答话的会话，其余的每一次状态变化都由模块那头
    /// 驱动。不补这一下，`current` 会停在「通话中」、时长接着走、通话窗一直
    /// 挂着，而断线那条路（`ModemController.handleTransportLoss`）跟
    /// `AppModel.disconnect()` 不是同一条，后者清 `call` 的那一行也轮不到它。
    /// 客户看到的是一通永远挂不断的电话，只能退出 App 才收得回来。
    ///
    /// 不发 AT，也不报错：链路已经没了，发出去只会再撞一次「通道已关闭」。
    /// 返回真表示刚才确实有一通在走。
    @discardableResult
    public func abandonLostLink() -> Bool {
        lock.lock()
        let wasBusy = current.state.isBusy
        let direction = current.direction
        let number = current.number
        lock.unlock()
        guard wasBusy else { return false }
        // 停在「已结束」而不是直接回「空闲」：客户眼前多半正开着通话窗，
        // 「已结束」说得清刚才那一通是怎么没的；回「空闲」像是从来没打过。
        // 通话记录那边两条路都收得掉（见 `CallHistory.observe`）。
        update(state: .ended, direction: direction, number: number)
        return true
    }

    public func reject() throws {
        // Rejecting a waiting call must not end the call already in progress.
        if current.state == .waiting {
            try releaseWaiting()
            return
        }
        try hangup()
    }

    /// `AT+VTS` sends one DTMF tone; a string sends them in sequence.
    public func sendDTMF(_ digits: String) throws {
        let allowed = Set("0123456789*#ABCD")
        let cleaned = digits.uppercased().filter { allowed.contains($0) }
        guard !cleaned.isEmpty else { return }
        for digit in cleaned {
            _ = try session.send("AT+VTS=\"\(digit)\"", timeout: 5)
            Thread.sleep(forTimeInterval: 0.12)
        }
    }

    /// `AT+CLCC` is the reliable way to learn the real state, including calls
    /// that were answered or hung up on the other side.
    @discardableResult
    public func refresh() throws -> CallInfo {
        let response = try session.send("AT+CLCC", timeout: 5)
        let calls = Self.parseCLCC(response)
        guard let first = Self.preferred(calls) else {
            callBeforeWaiting = nil
            if current.state.isBusy {
                update(state: .idle, direction: current.direction, number: "")
            }
            return current
        }
        if first.state != .waiting { callBeforeWaiting = nil }
        var info = first
        if info.state == .active {
            info.startedAt = current.startedAt ?? Date()
            info.startedUptime = current.startedUptime ?? ProcessInfo.processInfo.systemUptime
        } else {
            info.startedAt = current.startedAt
            info.startedUptime = current.startedUptime
        }
        if info.number.isEmpty { info.number = current.number }
        update(info: info)
        return current
    }

    /// Picks the call the panel should be showing.
    ///
    /// A second incoming call during a conversation makes `AT+CLCC` report two
    /// entries. Taking the first would show the call that is already up and
    /// silently erase the waiting one on the very next poll — the ringer would
    /// appear to die on its own. The waiting call wins because it is the one
    /// that needs a decision; the active call needs nothing.
    public static func preferred(_ calls: [CallInfo]) -> CallInfo? {
        guard !calls.isEmpty else { return nil }
        // Lower rank wins. A call that needs a decision beats one that does
        // not, and the conversation you are actually in beats one on hold —
        // after a call-waiting swap both are in the table, and showing the
        // held one would label a live conversation "保持中".
        func rank(_ state: CallState) -> Int {
            switch state {
            case .waiting: return 0
            case .ringing: return 1
            case .active: return 2
            case .dialing: return 3
            case .alerting: return 4
            case .held: return 5
            default: return 6
            }
        }
        // `min(by:)` keeps the first of equal elements, so ties stay stable.
        return calls.min { rank($0.state) < rank($1.state) }
    }

    // MARK: - URC handling

    /// Feeds one unsolicited line; returns true when it described a call.
    @discardableResult
    public func handle(urc line: String) -> Bool {
        let upper = line.uppercased()
        if upper == "RING" || upper.hasPrefix("+CRING") {
            if ringStartedAt == nil { ringStartedAt = Date() }
            if !current.state.isBusy || current.state == .ended {
                update(state: .ringing, direction: .incoming, number: pendingCallerNumber)
            }
            return true
        }
        if upper.hasPrefix("+CLIP:") {
            let fields = ATParsers.splitQuoted(String(line.dropFirst("+CLIP:".count)))
            if let first = fields.first {
                pendingCallerNumber = first.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                update(state: current.state == .active ? .active : .ringing,
                       direction: .incoming, number: pendingCallerNumber)
            }
            return true
        }
        if upper.hasPrefix("+CCWA:") {
            let fields = ATParsers.splitQuoted(String(line.dropFirst("+CCWA:".count)))
            if let first = fields.first {
                if current.state != .waiting { callBeforeWaiting = current }
                update(state: .waiting, direction: .incoming,
                       number: first.trimmingCharacters(in: CharacterSet(charactersIn: " \"")))
            }
            return true
        }
        if upper == "NO CARRIER" || upper == "BUSY" || upper == "NO ANSWER" || upper == "NO DIALTONE" {
            // A failed outgoing attempt should not be reported as a finished call.
            if current.state.isBusy {
                appendLog(current)
            }
            ringStartedAt = nil
            pendingCallerNumber = ""
            update(state: .idle, direction: current.direction, number: "")
            return true
        }
        if upper.hasPrefix("+CALLSTAT") {
            return true
        }
        return false
    }

    // MARK: - Parsing

    public static func parseCLCC(_ response: ATResponse) -> [CallInfo] {
        var calls: [CallInfo] = []
        for line in response.lines where line.uppercased().hasPrefix("+CLCC:") {
            let fields = ATParsers.splitQuoted(String(line.dropFirst("+CLCC:".count)))
            guard fields.count >= 4,
                  let index = Int(fields[0]),
                  let directionCode = Int(fields[1]),
                  let stateCode = Int(fields[2]) else { continue }
            // 第 4 个字段是 `<mode>`：0 = 语音，1 = 数据。这版 DJI 固件把 ECM
            // 数据链路常驻报成两路「通话」——`+CLCC: 1,1,0,1,0,"",128`，
            // stat=0 就是「通话中」——而且 CHUP 清不掉。把它们当成通话收下，
            // 面板会一直显示通话中，更糟的是 `RING` 那条 URC 会被
            // `current.state.isBusy` 挡在门外：来电一声不响，客户只看到一部
            // 永远占线的电话。数据链路不是通话，这里就不该有它的位置。
            let mode = Int(fields[3]) ?? 0
            guard mode == 0 else { continue }
            let direction: CallDirection = directionCode == 0 ? .outgoing
                : (directionCode == 1 ? .incoming : .unknown)
            var number = ""
            if fields.count >= 6 {
                number = fields[5].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            }
            if number.isEmpty, fields.count >= 5 {
                let candidate = fields[4].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                if candidate.filter({ $0.isNumber }).count >= 5, Int(candidate) != nil {
                    number = candidate
                }
            }
            calls.append(CallInfo(index: index,
                                  direction: direction,
                                  state: CallState.fromCLCC(stateCode),
                                  number: number))
        }
        return calls
    }

    static func sanitise(_ number: String) -> String {
        var cleaned = number.trimmingCharacters(in: .whitespaces)
        let allowed = Set("0123456789+*#ABC")
        cleaned = cleaned.uppercased().filter { allowed.contains($0) }
        // `ATD` cannot take a second '+' beyond the international prefix.
        if let first = cleaned.first, first == "+" {
            cleaned = "+" + cleaned.dropFirst().replacingOccurrences(of: "+", with: "")
        } else {
            cleaned = cleaned.replacingOccurrences(of: "+", with: "")
        }
        return cleaned
    }

    // MARK: - State

    private func update(state: CallState, direction: CallDirection, number: String) {
        var info = current
        info.state = state
        info.direction = direction
        info.number = number
        if state == .active, info.startedUptime == nil {
            info.startedUptime = ProcessInfo.processInfo.systemUptime
            info.startedAt = info.startedAt ?? Date()
        }
        if state == .idle || state == .ended {
            info.startedAt = nil
            info.startedUptime = nil
        }
        update(info: info)
    }

    private func update(info: CallInfo) {
        lock.lock()
        current = info
        lock.unlock()
        onStateChange?(info)
    }

    private func appendLog(_ info: CallInfo) {
        lock.lock()
        log.append(info)
        if log.count > 100 { log.removeFirst(log.count - 100) }
        lock.unlock()
    }
}
