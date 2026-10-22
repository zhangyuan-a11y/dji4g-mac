import Foundation

public struct SMSStorage: Equatable {
    public var used: Int = 0
    public var total: Int = 0
    public var raw: String = ""
    public init() {}
    public var isFull: Bool { total > 0 && used >= total }
    public var label: String { total > 0 ? "\(used)/\(total)" : "未知" }
}

public enum SMSError: Error, CustomStringConvertible {
    /// Carries why the card is unusable, so the panel can name the real cause
    /// instead of repeating "SIM 未就绪" for a card that is simply not there.
    case notReady(String)
    case storageFull
    case rejected(ATFinal)
    case encodeFailed(String)

    public var description: String {
        switch self {
        case .notReady(let reason): return "短信发不出去：\(reason)"
        case .storageFull: return "模块短信存储已满，请先删除旧短信"
        case .rejected(let final):
            let reason = ATFailure.explain(final) ?? "模块拒绝发送这条短信"
            return "\(reason)（模块原话：\(final.text)）"
        case .encodeFailed(let detail): return detail
        }
    }
}

/// SMS over the Quectel AT channel.
///
/// Two modes are supported and both are needed in practice: PDU mode
/// (`AT+CMGF=0`) carries Chinese text and concatenated messages, while text
/// mode (`AT+CMGF=1`) is the fallback for firmware that mishandles routing.
public final class SMSService {
    private let session: ATSession
    private let lock = NSLock()

    /// Messages already announced through `+CMTI:`, newest last.
    private var assembled: [SMSMessage] = []
    public private(set) var storage = SMSStorage()

    /// 上一次 `refresh()` 里解析不出来的格子：slot 号 → 模块原话。
    ///
    /// 以前这里是 `try?`，解不开就 `continue` —— 收件箱少一条，界面上没有任何
    /// 痕迹，存储数还是 7/40，客户只会觉得「短信丢了一条」而查无对证
    /// （2026-09-26 真机排查 6 条 vs 7 格时就先怀疑到这里）。解不开不是不可能：
    /// 状态报告、运营商专用格式、截断的长短信都能make出这种 PDU。现在留下来，
    /// 由 `SMSDetail.storageNote` 在存储那一行说出来。
    public private(set) var decodeFailures: [Int: String] = [:]

    /// Fired on the session's polling thread whenever a message becomes
    /// available — either from `+CMTI:` or from an explicit refresh.
    public var onMessage: ((SMSMessage) -> Void)?

    public init(session: ATSession) {
        self.session = session
    }

    public var messages: [SMSMessage] {
        lock.lock(); defer { lock.unlock() }
        return assembled
    }

    // MARK: - Configuration

    public func configure() throws {
        _ = try session.send("AT+CSCS=\"GSM\"", timeout: 3)
        _ = try session.send("AT+CMGF=0", timeout: 3)
        // Route new messages to the module's own storage and let the host know
        // about them with an index instead of the full PDU.
        _ = try session.send("AT+CNMI=2,1,0,2,0", timeout: 3)
        _ = try session.send("AT+CSMP=17,167,0,0", timeout: 3)
        try refreshStorage()
    }

    /// 换一个短信接收存储。
    ///
    /// 模块把新短信默认存进 `ME`（它自己的 23 个格子）。存满之后网络投递
    /// 过来的短信会被**直接丢掉**：发的人那边一切正常，这边一条都收不到，
    /// 屏幕上也没有任何提示。SIM 卡上通常还有几十个空格，而且它跟着卡走，
    /// 换模块也还在。这台机器上真机遇到的就是这个：`ME 23/23` 满了，
    /// `SM` 还有 40 个空位。
    @discardableResult
    public func setStorage(_ name: String) throws -> SMSStorage {
        let wanted = name.uppercased()
        guard ["SM", "ME", "MT", "SR"].contains(wanted) else {
            throw SMSError.encodeFailed("存储名要是 SM / ME / MT / SR 中的一个，收到的是「\(name)」")
        }
        let command = "AT+CPMS=\"\(wanted)\",\"\(wanted)\",\"\(wanted)\""
        let response = try session.send(command, timeout: 8)
        guard response.final == .ok else { throw SMSError.rejected(response.final) }
        return try refreshStorage()
    }

    @discardableResult
    public func refreshStorage() throws -> SMSStorage {
        let response = try session.send("AT+CPMS?", timeout: 5)
        var parsed = SMSStorage()
        parsed.raw = response.rawText.replacingOccurrences(of: "\n", with: " ")
        if let value = response.firstValue(for: "+CPMS") {
            let fields = ATParsers.splitQuoted(value)
            // <mem1>,<used1>,<total1>,<mem2>,<used2>,<total2>,...
            if fields.count >= 3, let used = Int(fields[1]), let total = Int(fields[2]) {
                parsed.used = used
                parsed.total = total
            }
        }
        lock.lock()
        storage = parsed
        lock.unlock()
        return parsed
    }

    // MARK: - Reading

    /// Lists every stored message in PDU mode. Concatenated segments are merged
    /// before they reach the caller.
    @discardableResult
    public func refresh() throws -> [SMSMessage] {
        let response = try session.send("AT+CMGL=4", timeout: 20)
        var decoded: [SMSMessage] = []
        var failed: [Int: String] = [:]
        var header: (index: Int, status: String)?
        for line in response.lines {
            let upper = line.uppercased()
            if upper.hasPrefix("+CMGL:") {
                let fields = ATParsers.splitQuoted(String(line.dropFirst("+CMGL:".count)))
                let slot = fields.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                header = slot.map { ($0, Self.status(fromCMGLField: fields.count > 1 ? fields[1] : "")) }
                continue
            }
            guard let pending = header else { continue }
            header = nil
            if line.isEmpty { continue }
            // `AT+CMGL=4` returns the whole mailbox, and sent messages are
            // stored as SMS-SUBMIT PDUs, so let the codec pick the direction.
            do {
                decoded.append(try PDUCodec.decode(line, storageIndex: pending.index,
                                                   status: pending.status))
            } catch {
                failed[pending.index] = "\(error)"
            }
        }
        let merged = Self.assemble(decoded)
        lock.lock()
        assembled = merged
        decodeFailures = failed
        lock.unlock()
        for message in merged { onMessage?(message) }
        return merged
    }

    /// Reads one slot. The stored message stays on the module either way; the
    /// read itself clears its UNREAD flag.
    @discardableResult
    public func read(index: Int) throws -> SMSMessage? {
        let response = try session.send("AT+CMGR=\(index)", timeout: 10)
        // `+CMGR: <stat>,,<length>` — text mode spells the status out, PDU mode
        // reports the same numbers AT+CMGL uses.
        var status = "REC READ"
        for line in response.lines {
            let upper = line.uppercased()
            if upper.hasPrefix("+CMGR:") {
                let fields = ATParsers.splitQuoted(String(line.dropFirst("+CMGR:".count)))
                if let first = fields.first, !first.trimmingCharacters(in: .whitespaces).isEmpty {
                    status = Self.status(fromCMGLField: first)
                }
                continue
            }
            if line.isEmpty { continue }
            do {
                let message = try PDUCodec.decode(line, storageIndex: index, status: status)
                // 这一格这次读出来了，之前记下的失败就得撤掉，否则存储那行会一直
                // 挂着一条早就不存在的问题。
                lock.lock(); decodeFailures[index] = nil; lock.unlock()
                return message
            } catch {
                // `+CMTI` 只说「第 5 格有新短信」，读不出来的话这条就永远不会进
                // 收件箱。以前这里返回 nil 就完了，界面上一点痕迹都没有 ——
                // 和 `refresh()` 里那个 `try?` 是同一个毛病，一起堵上。
                lock.lock(); decodeFailures[index] = "\(error)"; lock.unlock()
                return nil
            }
        }
        return nil
    }

    /// Called for `+CMTI: "SM",5`. Fetches the new slot and merges it into the
    /// cached list.
    @discardableResult
    public func handleIncoming(index: Int) -> SMSMessage? {
        guard let message = try? read(index: index) else { return nil }
        lock.lock()
        let existing = assembled.filter { $0.storageIndex != message.storageIndex }
        let merged = Self.assemble(existing + [message])
        assembled = merged
        lock.unlock()
        // An arriving message changes how full the mailbox is. `AT+CPMS?` is
        // the only way to learn that, and without this the panel keeps showing
        // the count from whenever the mailbox was last opened.
        _ = try? refreshStorage()
        onMessage?(message)
        return message
    }

    /// `+CMGL:` reports status either as the PDU-mode number or as text.
    static func status(fromCMGLField field: String) -> String {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        switch Int(trimmed) {
        case 0: return "REC UNREAD"
        case 1: return "REC READ"
        case 2: return "STO UNSENT"
        case 3: return "STO SENT"
        default: return trimmed.isEmpty ? "REC UNREAD" : trimmed
        }
    }

    /// Parses `+CMTI: "SM",5` / `+CMT: ...` and returns the storage index.
    public static func storageIndex(fromURC line: String) -> Int? {
        let upper = line.uppercased()
        guard upper.hasPrefix("+CMTI:") else { return nil }
        let fields = ATParsers.splitQuoted(String(line.dropFirst("+CMTI:".count)))
        guard let last = fields.last else { return nil }
        return Int(last.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Deleting

    public func delete(index: Int) throws {
        _ = try session.send("AT+CMGD=\(index)", timeout: 10)
        lock.lock()
        assembled.removeAll { $0.storageIndex == index }
        lock.unlock()
        _ = try? refreshStorage()
    }

    public func deleteAll() throws {
        // 4 = delete all messages including those already read and unsent.
        _ = try session.send("AT+CMGD=1,4", timeout: 30)
        lock.lock()
        assembled.removeAll()
        lock.unlock()
        _ = try? refreshStorage()
    }

    // MARK: - Sending

    /// Sends `text` to `number`, splitting into concatenated segments when it
    /// exceeds the single-PDU limit. Returns the number of PDUs the module took.
    @discardableResult
    public func send(text: String, to number: String, statusReport: Bool = false) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { throw SMSError.encodeFailed("短信内容为空") }

        let pdus: [String]
        do {
            pdus = try PDUSubmit.encode(text: trimmed, to: number, requestStatusReport: statusReport)
        } catch {
            throw SMSError.encodeFailed("\(error)")
        }

        try refreshStorage()
        if storage.isFull, storage.total > 0 {
            throw SMSError.storageFull
        }

        for (offset, pdu) in pdus.enumerated() {
            let length = Self.tpduLength(of: pdu)
            let prompt = try session.send("AT+CMGS=\(length)", timeout: 15, stopOnPrompt: true)
            guard prompt.final == .prompt else {
                // 没有提示符也可能已经进了输入态（模块先回 ERROR 再挂起之类），
                // 所以这条失败路径同样先退出再抛。
                // Some firmware skips the prompt and answers straight away —
                // that one did not enter the entry state, so leave it alone.
                if prompt.final == .ok { continue }
                session.abortDataEntry()
                throw SMSError.rejected(prompt.final)
            }
            var payload = Array(pdu.utf8)
            payload.append(0x1A)                     // Ctrl-Z commits the message
            // 从这里到拿到 OK 之间，模块随时可能因为一次读超时而把我们挂
            // 在那个 `>` 提示符上。任何一条失败路径都要显式退出输入态，否
            // 则下一个 `AT` 会被当成短信正文吃掉，端口一直到断电都救不回
            // 来 —— 一次没发出去的短信不该有这种代价。
            let result: ATResponse
            do {
                result = try session.sendRaw(payload, timeout: 60)
            } catch {
                session.abortDataEntry()
                throw error
            }
            guard result.final == .ok else {
                session.abortDataEntry()
                throw SMSError.rejected(result.final)
            }
            if offset < pdus.count - 1 {
                Thread.sleep(forTimeInterval: 0.35)
            }
        }
        _ = try? refreshStorage()
        return pdus.count
    }

    /// `AT+CMGS` wants the TPDU length, i.e. the PDU minus the service-centre
    /// address prefix.
    public static func tpduLength(of pduHex: String) -> Int {
        guard let bytes = try? PDUCodec.bytes(fromHex: pduHex), !bytes.isEmpty else { return pduHex.count / 2 }
        let scaLength = Int(bytes[0])
        return max(0, bytes.count - 1 - scaLength)
    }

    // MARK: - Concatenation

    /// Merges multi-part segments. Each group is keyed by sender, the
    /// concatenation reference and the declared part count.
    public static func assemble(_ messages: [SMSMessage]) -> [SMSMessage] {
        var singles: [SMSMessage] = []
        var groups: [String: [SMSMessage]] = [:]

        for message in messages {
            guard let reference = message.reference,
                  let total = message.totalParts, total > 1,
                  let part = message.partIndex else {
                singles.append(message)
                continue
            }
            _ = part
            let key = "\(message.sender)|\(reference)|\(total)"
            // The mailbox can be re-scanned while a message is still arriving;
            // never fold the same slot in twice.
            if message.storageIndex >= 0,
               groups[key, default: []].contains(where: { $0.storageIndex == message.storageIndex }) {
                // 同一个格子被扫到两次。格子数不叠加 —— 重复的那份和已收下的那份
                // 指的是同一个 slot，`AT+CPMS?` 也只按一个格子算。
                continue
            }
            groups[key, default: []].append(message)
        }

        var result = singles
        for (_, segments) in groups {
            let sorted = segments.sorted { ($0.partIndex ?? 0) < ($1.partIndex ?? 0) }
            let declared = sorted.first?.totalParts ?? 0
            guard sorted.count >= declared else {
                // Parts are still missing. Pass the segments through untouched
                // so their reference survives; a later call can then complete
                // the group instead of seeing orphaned fragments.
                result.append(contentsOf: sorted)
                continue
            }
            var merged = sorted[0]
            merged.text = sorted.map(\.text).joined()
            // 合并后这一条占的格子数是段数，不是 1 —— 见 `SMSMessage.segmentCount`。
            merged.segmentCount = sorted.count
            merged.timestamp = sorted.compactMap(\.timestamp).min() ?? merged.timestamp
            merged.partIndex = nil
            merged.reference = nil
            merged.storageIndex = sorted.map(\.storageIndex).min() ?? merged.storageIndex
            merged.status = sorted.contains(where: { $0.isUnread }) ? "REC UNREAD" : "REC READ"
            result.append(merged)
        }

        return result.sorted { left, right in
            switch (left.timestamp, right.timestamp) {
            case let (l?, r?): return l < r
            case (nil, _?): return true
            case (_?, nil): return false
            default: return left.storageIndex < right.storageIndex
            }
        }
    }
}
