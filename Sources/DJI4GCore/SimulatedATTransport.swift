import Foundation

/// An EG25-G that lives in memory.
///
/// The point is not to fake success: every response below is the shape this
/// firmware family actually returns, so the parsing layer, the SMS assembly and
/// the call state machine can all be exercised end to end without a module
/// plugged in. It is also what drives the offline demo.
public final class SimulatedATTransport: ATTransport {
    public enum Scenario {
        case ready
        case noSIM
        case notRegistered
        case storageFull
    }

    private let lock = NSLock()
    /// Guards `pending` only. Command handling runs while `lock` is held, and
    /// every handler writes its answer through `emit`, so the output buffer
    /// needs a lock of its own — re-entering `lock` from the same thread would
    /// deadlock.
    private let outputLock = NSLock()
    private var pending: [UInt8] = []
    private var commandBuffer: [UInt8] = []
    private var smsBody: [UInt8] = []
    private var awaitingSMSBody = false
    private var messageReference = 100

    public private(set) var scenario: Scenario
    public private(set) var simInserted: Bool
    public private(set) var registrationCode = 1
    public private(set) var rssiIndex = 22
    public private(set) var usbnetMode = 1
    public private(set) var audioFlag = false
    public private(set) var apn = ""

    public var model = "EG25-G"
    public var revision = "EG25GGBR07A08M2G"
    public var imei = "860123456789012"
    public var imsi = "460001234567890"
    public var iccid = "89860012345678901234"
    public var ownNumber = "+8613800138000"
    public var carrierMCCMNC = "46000"
    public var carrierName = "CHINA MOBILE"
    /// USSD 查询会被回的那句话。真模块回的是**十六进制写的 UCS2**
    /// （`60A8` 就是「您」），这里照那个形状给一串 —— 解码那一段必须真的
    /// 被走到，不然它在模拟器上永远是死代码，坏掉也没人知道。
    public var ussdAnswer = "60A876844F59989D4E3A00310032002E003300305143"
    public var band = "LTE BAND 3"
    public var earfcn = 1650

    /// Storage slots, mirroring the 23-segment area the firmware exposes.
    /// `stat` follows the AT+CMGL numbering: 0 unread, 1 read, 3 sent.
    private var storage: [(index: Int, pdu: String, stat: Int)] = []
    private var nextIndex = 1
    public var storageCapacity = 23

    /// Byte counters the firmware reports for `AT+QGDCNT?`, in the order the
    /// command answers them. Raw bytes, not the KB some firmware revisions use.
    public var sentBytes: UInt64 = 12_345_678
    public var receivedBytes: UInt64 = 87_654_321

    /// One row of the module's call table. A real EG25-G keeps several at once —
    /// an active conversation plus a second caller parked behind it — which is
    /// exactly what `AT+CLCC` reports as multiple lines.
    public struct SimCall: Equatable {
        public var index: Int
        public var number: String
        public var direction: CallDirection
        public var state: CallState

        public init(index: Int, number: String, direction: CallDirection, state: CallState) {
            self.index = index
            self.number = number
            self.direction = direction
            self.state = state
        }
    }

    private var calls: [SimCall] = []
    private var nextCallIndex = 1

    /// Emitted for every command the simulator accepted; handy in the CLI's
    /// verbose mode.
    public var onCommand: ((String) -> Void)?
    /// Bytes handed back to the host, for `DJI4G_TRACE=1` style debugging.
    public var onEmit: ((String) -> Void)?

    public init(scenario: Scenario = .ready) {
        self.scenario = scenario
        self.simInserted = scenario != .noSIM
        if scenario == .notRegistered { registrationCode = 2 }
        // 卡都没有就谈不上注册 —— 真机在这个状态下也是未注册。
        if scenario == .noSIM { registrationCode = 0 }
        seedStorage()
    }

    // MARK: - ATTransport

    public var isOpen = false
    public var describe: String { "模拟器 \(model)（\(scenario)）" }

    public func open() throws {
        isOpen = true
        outputLock.lock()
        pending.removeAll()
        outputLock.unlock()
        lock.lock()
        commandBuffer.removeAll()
        lock.unlock()
    }

    public func close() {
        isOpen = false
    }

    /// 把卡座从「空」翻到「有卡 / 无卡」。
    ///
    /// 真机上这一步是客户自己做的：卡推进去，卡座检测置位，轮询线程几秒内
    /// 读到 `+CPIN: READY`，面板自己变好 —— 不重启 App，也不重启模块。模拟器
    /// 要能重演这一下，这条路径才不至于等客户插卡那天才第一次被执行。
    ///
    /// 返回是否真的发生了变化，方便调用方区分「卡本来就是这张状态」。
    @discardableResult
    public func setSIMInserted(_ inserted: Bool) -> Bool {
        lock.lock()
        let changed = simInserted != inserted
        simInserted = inserted
        // 空卡座时真机报的是未注册；插上之后先落到「已注册」，剩下的等网络
        // 的真实结果 —— 否则插卡后的那一轮刷新会读出一个「没有卡却已注册」
        // 的中间态。
        registrationCode = inserted ? 1 : 0
        lock.unlock()
        return changed
    }

    public func write(_ bytes: [UInt8]) throws {
        guard isOpen else { throw ATTransportError.closed }

        // Split the incoming bytes into work under the lock, then run the
        // handlers outside it: a handler answers by locking state of its own,
        // and re-entering `lock` from the same thread would deadlock.
        enum Work {
            case command(String)
            case smsCommit([UInt8])
            case cancelSMS
        }
        var queue: [Work] = []

        lock.lock()
        if awaitingSMSBody {
            for byte in bytes {
                if byte == 0x1A {
                    awaitingSMSBody = false
                    queue.append(.smsCommit(Array(smsBody)))
                    smsBody.removeAll()
                } else if byte == 0x1B {
                    awaitingSMSBody = false
                    smsBody.removeAll()
                    queue.append(.cancelSMS)
                } else {
                    smsBody.append(byte)
                }
            }
        } else {
            for byte in bytes {
                if byte == 0x0D || byte == 0x0A {
                    if !commandBuffer.isEmpty {
                        let command = String(decoding: commandBuffer, as: UTF8.self)
                        commandBuffer.removeAll()
                        queue.append(.command(command.trimmingCharacters(in: .whitespaces)))
                    }
                    continue
                }
                commandBuffer.append(byte)
            }
        }
        lock.unlock()

        for item in queue {
            switch item {
            case .command(let command):
                handle(command: command)
            case .smsCommit(let body):
                handleSMSCommit(body)
            case .cancelSMS:
                emit("\r\nERROR\r\n")
            }
        }
    }

    public func read(maxLength: Int, timeoutMs: Int) throws -> [UInt8] {
        guard isOpen else { throw ATTransportError.closed }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            outputLock.lock()
            if !pending.isEmpty {
                let count = min(maxLength, pending.count)
                let slice = Array(pending.prefix(count))
                pending.removeFirst(count)
                outputLock.unlock()
                return slice
            }
            outputLock.unlock()
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw ATTransportError.timeout
    }

    // MARK: - Injection

    /// Pushes an inbound message and announces it the way the firmware does.
    @discardableResult
    /// `notify: false` 时只把短信放进模块，不推 `+CMTI` —— 真机上对应的
    /// 是「短信早就在模块里，只是没人读过」：换了一张卡、别的机器先读过、
    /// 或者模块里本来躺着历史短信。这条路只有「重读一遍」才能看见。
    public func injectIncomingSMS(text: String, from sender: String, timestamp: Date = Date(),
                                  notify: Bool = true) -> Int {
        let pdu = (try? PDUDeliver.encode(text: text, from: sender, timestamp: timestamp)) ?? ""
        lock.lock()
        let index = nextIndex
        nextIndex += 1
        storage.append((index, pdu, 0))
        let slotName = "ME"
        lock.unlock()
        if notify {
            dispatch { self.emit("\r\n+CMTI: \"\(slotName)\",\(index)\r\n") }
        }
        return index
    }

    /// Injects a multi-part message so concatenation can be verified.
    public func injectMultipartSMS(parts: [String], from sender: String, reference: UInt8 = 0x21) {
        for (offset, text) in parts.enumerated() {
            let pdu = (try? PDUDeliver.encode(text: text, from: sender,
                                              reference: reference,
                                              total: UInt8(parts.count),
                                              part: UInt8(offset + 1))) ?? ""
            lock.lock()
            let index = nextIndex
            nextIndex += 1
            storage.append((index, pdu, 0))
            lock.unlock()
            dispatch { self.emit("\r\n+CMTI: \"ME\",\(index)\r\n") }
        }
    }

    /// A second caller arriving while a conversation is already up does not
    /// ring the phone again — the network parks it and the module announces it
    /// with `+CCWA`. That is the only way call waiting ever reaches the host.
    public func simulateIncomingCall(from number: String) {
        lock.lock()
        let busy = calls.contains { $0.state == .active || $0.state == .held }
        if busy {
            calls.append(SimCall(index: nextCallIndex, number: number,
                                 direction: .incoming, state: .waiting))
            nextCallIndex += 1
            lock.unlock()
            dispatch { self.emit("\r\n+CCWA: \"\(number)\",129,,,,0\r\n") }
            return
        }
        calls = [SimCall(index: 1, number: number, direction: .incoming, state: .ringing)]
        nextCallIndex = 2
        lock.unlock()
        dispatch { self.emit("\r\nRING\r\n\r\n+CLIP: \"\(number)\",129,,,,0\r\n") }
    }

    /// A ring the network never names.
    ///
    /// `+CLIP` is a subscription, not a guarantee — some calls arrive as a bare
    /// `RING`. What matters for the harness is that this ring is *registered*
    /// like any other: a hand-pushed `RING` leaves `+CLCC` reporting no call at
    /// all, so the very next poll (every two seconds) takes the ringing state
    /// back down and the announcement never gets to happen. That made the
    /// 「未知号码」check flip on poll timing rather than on the behaviour it is
    /// there to pin.
    public func simulateIncomingCallWithoutNumber() {
        lock.lock()
        calls = [SimCall(index: 1, number: "", direction: .incoming, state: .ringing)]
        nextCallIndex = 2
        lock.unlock()
        dispatch { self.emit("\r\nRING\r\n") }
    }

    public func simulateRemoteHangup() {
        lock.lock()
        calls.removeAll()
        nextCallIndex = 1
        lock.unlock()
        dispatch { self.emit("\r\nNO CARRIER\r\n") }
    }

    public func setRegistration(_ code: Int) {
        lock.lock(); registrationCode = code; lock.unlock()
        if code != 1 && code != 5 {
            dispatch { self.emit("\r\n+CEREG: 0,\(code)\r\n") }
        }
    }

    /// Feed an arbitrary response; used by the CLI's `sim` command.
    public func pushURC(_ text: String) {
        dispatch { self.emit("\r\n\(text)\r\n") }
    }

    // MARK: - Command handling

    private func handle(command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        onCommand?(trimmed)
        let upper = trimmed.uppercased()

        // Every command is echoed first.
        echo(trimmed)

        switch true {
        case upper == "AT" || upper == "AT&F" || upper == "ATE0" || upper == "AT+CMEE=2":
            ok()
        case upper == "ATI":
            emit("\r\n\(model)\r\nRevision: \(revision)\r\n\r\nOK\r\n")
        case upper == "AT+QGMR":
            emit("\r\n\(revision)_30.007.30.007\r\n\r\nOK\r\n")
        case upper == "AT+GSN":
            emit("\r\n\(imei)\r\n\r\nOK\r\n")
        case upper == "AT+QTEMP":
            emit("\r\n+QTEMP: 27,27,29,28\r\n\r\nOK\r\n")
        case upper.hasPrefix("AT+CPIN?"):
            if simInserted {
                emit("\r\n+CPIN: READY\r\n\r\nOK\r\n")
            } else {
                emit("\r\n+CME ERROR: 10\r\n")
            }
        case upper.hasPrefix("AT+QSIMSTAT?"):
            // The card-detect pin: `<enable>,<inserted>`.
            emit("\r\n+QSIMSTAT: 1,\(simInserted ? 1 : 0)\r\n\r\nOK\r\n")
        case upper == "AT+CIMI" || upper.hasPrefix("AT+CIMI"):
            simInserted ? emit("\r\n\(imsi)\r\n\r\nOK\r\n") : cme(10)
        case upper.hasPrefix("AT+QCCID"), upper.hasPrefix("AT+CCID"):
            simInserted ? emit("\r\n+QCCID: \(iccid)\r\n\r\nOK\r\n") : cme(10)
        case upper.hasPrefix("AT+CNUM"):
            simInserted ? emit("\r\n+CNUM: ,\"\(ownNumber)\",145,,4\r\n\r\nOK\r\n") : ok()
        case upper.hasPrefix("AT+CSQ"):
            emit("\r\n+CSQ: \(rssiIndex),99\r\n\r\nOK\r\n")
        case upper.hasPrefix("AT+QCSQ"):
            let rsrp = -140 + rssiIndex * 2
            emit("\r\n+QCSQ: \"LTE\",\(-113 + rssiIndex * 2),\(rsrp),138,-11\r\n\r\nOK\r\n")
        case upper.hasPrefix("AT+CREG?"):
            emit("\r\n+CREG: 0,\(registrationCode)\r\n\r\nOK\r\n")
        case upper.hasPrefix("AT+CEREG?"):
            emit("\r\n+CEREG: 0,\(registrationCode)\r\n\r\nOK\r\n")
        case upper.hasPrefix("AT+COPS?"):
            emit("\r\n+COPS: 0,0,\"\(carrierName)\",7\r\n\r\nOK\r\n")
        case upper.hasPrefix("AT+COPS=?"):
            // 尾巴上那两对括号（支持的频段、支持的制式）是真的，扫网解析
            // 必须把它们挡掉 —— 少挡一次，客户列表里就会多两条假运营商。
            emit("\r\n+COPS: (2,\"\(carrierName)\",\"CMCC\",\"\(carrierMCCMNC)\",7),(1,\"CHINA UNICOM\",\"CU\",\"46001\"),(1,\"CHINA TELECOM\",\"CT\",\"46011\"),,(0-1),(0,2)\r\n\r\nOK\r\n")
        case upper.hasPrefix("AT+COPS=0"), upper.hasPrefix("AT+COPS=1"):
            ok()
        case upper.hasPrefix("AT+QNWINFO"):
            emit("\r\n+QNWINFO: \"FDD LTE\",\"\(carrierMCCMNC)\",\"\(band)\",\(earfcn)\r\n\r\nOK\r\n")
        case upper.hasPrefix("AT+QENG"):
            emit("\r\n+QENG: \"servingcell\",\"NOCONN\",\"LTE\",\"FDD\",\(carrierMCCMNC.prefix(3)),\(carrierMCCMNC.suffix(2)),1A2D303,214,\(earfcn),3,5,5,2F5E,\(-140 + rssiIndex * 2),-11,\(-113 + rssiIndex * 2),14,-\r\n\r\nOK\r\n")
        case upper.hasPrefix("AT+CESQ"):
            // 3GPP TS 27.007 §8.69：<rssi>,<ber>,<rscp>,<ecno>,<rsrq>,<rsrp>。
            // 各格按同一份 `rssiIndex` 反算，读出来的 dBm 和上面 QCSQ 那一条
            // 对得上 —— 两条命令报同一件事，对不上就说明有一条算错了。
            emit("\r\n+CESQ: \(rssiIndex),99,60,14,17,\(rssiIndex * 2)\r\n\r\nOK\r\n")
        case upper.hasPrefix("AT^HCSQ"):
            emit("\r\n^HCSQ: \"LTE\",\(rssiIndex),1,\(rssiIndex * 2),1\r\n\r\nOK\r\n")
        case upper.hasPrefix("AT^SYSINFOEX"):
            emit("\r\n^SYSINFOEX: 2,3,1,7,\"LTE\",\"LTE\",\(carrierMCCMNC)\r\n\r\nOK\r\n")
        case upper.hasPrefix("AT+CPSI"):
            emit("\r\n+CPSI: LTE,Online,\(carrierMCCMNC),0x1A2D,\(earfcn),214,\(band),3\r\n\r\nOK\r\n")
        case upper.hasPrefix("AT+CUSD=1"):
            // 真模块就是这个顺序：当场回 OK，网络那句话随后才以 `+CUSD`
            // 主动上报（TS 27.007 §7.15）。模拟器照抄这个先后，
            // 不然「异步那一段」只在真机上才走得通。
            ok()
            dispatch { self.emit("\r\n+CUSD: 0,\"\(self.ussdAnswer)\",72\r\n") }
        case upper.hasPrefix("AT+CUSD=2"), upper.hasPrefix("AT+CUSD=0"):
            ok()
        case upper.hasPrefix("AT+CSCS"), upper.hasPrefix("AT+CMGF"),
             upper.hasPrefix("AT+CNMI"), upper.hasPrefix("AT+CSMP"),
             upper.hasPrefix("AT+CLIP"), upper.hasPrefix("AT+QAUDCH"),
             upper.hasPrefix("AT+CMEE"), upper.hasPrefix("AT+CREG="),
             upper.hasPrefix("AT+CEREG="), upper.hasPrefix("AT+CSCA"),
             upper.hasPrefix("AT+QSCLK"), upper.hasPrefix("AT+QGPIO"):
            ok()
        case upper.hasPrefix("AT+CPMS?"):
            let used = scenario == .storageFull ? storageCapacity : storage.count
            emit("\r\n+CPMS: \"ME\",\(used),\(storageCapacity),\"ME\",\(used),\(storageCapacity),\"ME\",\(used),\(storageCapacity)\r\n\r\nOK\r\n")
        case upper.hasPrefix("AT+CMGL"):
            listMessages()
        case upper.hasPrefix("AT+CMGR="):
            readMessage(String(trimmed.dropFirst("AT+CMGR=".count)))
        case upper.hasPrefix("AT+CMGD="):
            deleteMessage(String(trimmed.dropFirst("AT+CMGD=".count)))
        case upper.hasPrefix("AT+CMGS="):
            // Without a card there is nothing to send through, and a real
            // module says so before showing the `>` prompt.
            guard simInserted else {
                cme(10)
                return
            }
            messageReference += 1
            lock.lock()
            awaitingSMSBody = true
            smsBody.removeAll()
            lock.unlock()
            emit("\r\n> ")
        case upper.hasPrefix("ATD"):
            dial(trimmed)
        case upper == "ATA" || upper.hasPrefix("ATA"):
            // Strict on purpose: a parked call is *not* ringing, so a real
            // module answers ERROR here. Letting the simulator be lenient
            // would hide a regression in the `AT+CHLD` branch.
            lock.lock()
            let ringing = calls.firstIndex { $0.state == .ringing }
            if let ringing { calls[ringing].state = .active }
            lock.unlock()
            emit(ringing == nil ? "\r\nERROR\r\n" : "\r\nOK\r\n")
        case upper.hasPrefix("AT+CHLD="):
            callHold(String(trimmed.dropFirst("AT+CHLD=".count)))
        case upper.hasPrefix("AT+CHUP"), upper.hasPrefix("ATH"):
            lock.lock()
            let wasBusy = !calls.isEmpty
            calls.removeAll()
            nextCallIndex = 1
            lock.unlock()
            emit("\r\nOK\r\n")
            if wasBusy { dispatch { self.emit("\r\nNO CARRIER\r\n") } }
        case upper.hasPrefix("AT+CLCC"):
            listCalls()
        case upper.hasPrefix("AT+VTS"):
            ok()
        case upper.hasPrefix("AT+VTD"):
            ok()
        case upper.hasPrefix("AT+QCFG=\"USBNET\""):
            if trimmed.uppercased().hasSuffix("?") || trimmed.hasSuffix("\"usbnet\"") {
                emit("\r\n+QCFG: \"usbnet\",\(usbnetMode)\r\n\r\nOK\r\n")
            } else {
                if let value = Int(trimmed.split(separator: ",").last ?? "") { usbnetMode = value }
                ok()
            }
        case upper.hasPrefix("AT+QCFG=\"USBCFG\""):
            if trimmed.uppercased().hasSuffix("?") || trimmed.hasSuffix("\"usbcfg\"") {
                emit(String(format: "\r\n+QCFG: \"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,0,%d\r\n\r\nOK\r\n", audioFlag ? 1 : 0))
            } else {
                let fields = trimmed.split(separator: ",").map(String.init)
                if let last = fields.last?.trimmingCharacters(in: .whitespaces) {
                    audioFlag = last == "1"
                }
                ok()
            }
        case upper.hasPrefix("AT+QICSGP"):
            if trimmed.uppercased().hasSuffix("?") || trimmed.split(separator: ",").count <= 2 {
                emit("\r\n+QICSGP: 1,\"IP\",\"\(apn)\",\"\",\"\",0\r\n\r\nOK\r\n")
            } else {
                let fields = trimmed.split(separator: ",").map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                }
                if fields.count >= 3 { apn = fields[2] }
                ok()
            }
        case upper.hasPrefix("AT+QIACT"):
            trimmed.uppercased().hasSuffix("?") ? emit("\r\n+QIACT: 1,1,1,\"10.31.1.42\"\r\n\r\nOK\r\n") : ok()
        case upper.hasPrefix("AT+CGPADDR"):
            // 模拟 NAT 场景：蜂窝侧 IP（100.69.150.192）与主机 ECM DHCP 拿到的
            // 地址（10.31.1.42）不同 —— 两者不一致不是故障。
            emit("\r\n+CGPADDR: 1,\"100.69.150.192\"\r\n\r\nOK\r\n")
        case upper.hasPrefix("AT+QIDEACT"):
            ok()
        case upper.hasPrefix("AT+QGDCNT"):
            emit("\r\n+QGDCNT: \(sentBytes),\(receivedBytes)\r\n\r\nOK\r\n")
        case upper.hasPrefix("AT+CFUN=1,1"), upper.hasPrefix("AT+CFUN=1"):
            ok()
        case upper.hasPrefix("AT+QGPS"):
            // This firmware answers CME 501 for GPS commands.
            cme(501)
        default:
            emit("\r\nERROR\r\n")
        }
    }

    private func dial(_ command: String) {
        var number = String(command.dropFirst(3))
        let hasSemicolon = number.hasSuffix(";")
        if hasSemicolon { number.removeLast() }
        guard !number.isEmpty else {
            emit("\r\nERROR\r\n")
            return
        }
        // Dialling is a card-bound operation: no card, no call, and the module
        // reports it with the SIM code rather than a generic ERROR.
        guard simInserted else {
            cme(10)
            return
        }
        lock.lock()
        calls = [SimCall(index: 1, number: number, direction: .outgoing, state: .dialing)]
        nextCallIndex = 2
        lock.unlock()
        emit("\r\nOK\r\n")
        // Mimic a network that needs a moment before the far end rings.
        dispatch(after: 0.4) {
            self.lock.lock()
            if let index = self.calls.firstIndex(where: { $0.state == .dialing }) {
                self.calls[index].state = .alerting
            }
            self.lock.unlock()
        }
        dispatch(after: 2.2) {
            self.lock.lock()
            let stillDialing = self.calls.contains { $0.state == .dialing || $0.state == .alerting }
            if let index = self.calls.firstIndex(where: { $0.state == .dialing || $0.state == .alerting }) {
                self.calls[index].state = .active
            }
            self.lock.unlock()
            if stillDialing { self.emit("\r\nOK\r\n") }
        }
    }

    /// 3GPP 22.030 call-hold handling, limited to the values this project uses.
    private func callHold(_ argument: String) {
        let raw = argument.trimmingCharacters(in: .whitespaces)
        let value = Int(raw)
        lock.lock()
        var droppedActive = false
        switch value {
        case 0:
            // Release the parked call; the conversation stays up.
            calls.removeAll { $0.state == .waiting }
        case 1:
            // Drop the current call, then take the parked one.
            if let index = calls.firstIndex(where: { $0.state == .active || $0.state == .held }) {
                calls.remove(at: index)
                droppedActive = true
            }
            if let index = calls.firstIndex(where: { $0.state == .waiting }) {
                calls[index].state = .active
            }
        case 2:
            // Hold the current call, then take the parked one. Both stay in
            // the table, which is what makes `AT+CLCC` report two rows.
            if let index = calls.firstIndex(where: { $0.state == .active || $0.state == .held }) {
                calls[index].state = .held
            }
            if let index = calls.firstIndex(where: { $0.state == .waiting }) {
                calls[index].state = .active
            }
        default:
            break
        }
        lock.unlock()
        emit(value == nil ? "\r\nERROR\r\n" : "\r\nOK\r\n")
        if droppedActive { dispatch { self.emit("\r\nNO CARRIER\r\n") } }
    }

    private func listCalls() {
        lock.lock()
        let snapshot = calls
        lock.unlock()
        guard !snapshot.isEmpty else {
            emit("\r\nOK\r\n")
            return
        }
        var text = "\r\n"
        for call in snapshot {
            let stat: Int
            switch call.state {
            case .active: stat = 0
            case .held: stat = 1
            case .dialing: stat = 2
            case .alerting: stat = 3
            case .ringing: stat = 4
            case .waiting: stat = 5
            default: stat = 0
            }
            let dir = call.direction == .outgoing ? 0 : 1
            text += "+CLCC: \(call.index),\(dir),\(stat),0,0,\"\(call.number)\",129\r\n"
        }
        emit(text + "\r\nOK\r\n")
    }

    private func listMessages() {
        lock.lock()
        let snapshot = storage
        lock.unlock()
        if snapshot.isEmpty {
            emit("\r\nOK\r\n")
            return
        }
        var text = "\r\n"
        for item in snapshot {
            text += "+CMGL: \(item.index),\(item.stat),,\(item.pdu.count / 2)\r\n\(item.pdu)\r\n"
        }
        text += "\r\nOK\r\n"
        emit(text)
    }

    private func readMessage(_ argument: String) {
        let index = Int(argument.split(separator: ",").first.map(String.init) ?? "") ?? -1
        lock.lock()
        let match = storage.first { $0.index == index }
        // Reading a slot clears its unread flag, as the firmware does.
        if let position = storage.firstIndex(where: { $0.index == index }), storage[position].stat == 0 {
            storage[position].stat = 1
        }
        lock.unlock()
        guard let match else {
            cme(21)
            return
        }
        emit("\r\n+CMGR: \(match.stat),,\(match.pdu.count / 2)\r\n\(match.pdu)\r\n\r\nOK\r\n")
    }

    private func deleteMessage(_ argument: String) {
        let fields = argument.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        lock.lock()
        if fields.count >= 2, fields[0] == 1, fields[1] == 4 {
            storage.removeAll()
        } else if let index = fields.first ?? nil {
            storage.removeAll { $0.index == index }
        }
        lock.unlock()
        ok()
    }

    private func handleSMSCommit(_ body: [UInt8]) {
        let raw = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            cms(304)
            return
        }
        // The host may prepend whitespace; the PDU itself is hex.
        let hex = raw.filter { $0.isHexDigit }
        guard let bytes = try? PDUCodec.bytes(fromHex: hex), bytes.count > 1 else {
            cms(304)
            return
        }
        if scenario == .storageFull {
            cms(322)
            return
        }
        // Sent messages land in the same mailbox, exactly as AT+CMGL=4 reports
        // them on this firmware family.
        lock.lock()
        let index = nextIndex
        nextIndex += 1
        storage.append((index, hex, 3))
        lock.unlock()
        messageReference += 1
        emit("\r\n+CMGS: \((messageReference - 1) % 256)\r\n\r\nOK\r\n")
    }

    // MARK: - Emission

    private func echo(_ command: String) {
        emit("\r\n\(command)\r\n")
    }

    private func ok() {
        emit("\r\nOK\r\n")
    }

    private func cme(_ code: Int) {
        emit("\r\n+CME ERROR: \(code)\r\n")
    }

    private func cms(_ code: Int) {
        emit("\r\n+CMS ERROR: \(code)\r\n")
    }

    private func emit(_ text: String) {
        outputLock.lock()
        pending.append(contentsOf: Array(text.utf8))
        outputLock.unlock()
        onEmit?(text)
    }

    private func dispatch(after delay: TimeInterval = 0, _ body: @escaping () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: body)
    }

    private func seedStorage() {
        // One unread message, so a fresh session has something to show.
        if let pdu = try? PDUDeliver.encode(text: "模块就绪，这是一条模拟短信。",
                                            from: "10086",
                                            timestamp: Date().addingTimeInterval(-3600)) {
            storage.append((1, pdu, 0))
            nextIndex = 2
        }
    }
}
