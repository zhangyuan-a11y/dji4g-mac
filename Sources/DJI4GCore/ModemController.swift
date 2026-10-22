import Foundation

public enum ModemEvent {
    case transport(String)
    case transportLost(String)
    case identity(ModuleIdentity)
    case sim(SIMStatus)
    case network(NetworkStatus)
    case signal(SignalStatus)
    case messages([SMSMessage])
    case incomingSMS(SMSMessage)
    case call(CallInfo)
    case data(DataStatus)
    case note(String)
    /// 一条 USSD 答复（查话费 / 查流量那一类）。
    case ussd(ATParsers.USSDReply)
}

/// Everything the UI needs, in one place: transport lifecycle, the AT session,
/// and the SMS / call / data / voice services built on top of it.
public final class ModemController {
    public let session: ATSession
    public let sms: SMSService
    public let calls: CallService
    public let voice: VoiceService
    public let data: DataService

    public private(set) var identity = ModuleIdentity()
    public private(set) var sim = SIMStatus()
    public private(set) var network = NetworkStatus()
    public private(set) var signal = SignalStatus()
    public private(set) var isConnected = false

    /// 手上这块模块是哪一家、该问哪些命令。握手时定一次，之后只读。
    ///
    /// 定成属性而不是每次去问：认厂家要看 `ATI`，而 `ATI` 本身就是一条 AT
    /// 命令 —— 信号是几秒一拍的东西，不能每拍都为了知道自己是谁去占用 AT 口。
    /// 模块换掉（拔了重插另一块）会走一次新的握手，那时重新认。
    public private(set) var profile = VendorCatalog.generic

    /// 最近一条 USSD 答复。
    ///
    /// 为什么要存一份：`AT+CUSD=1,…` 当场只回一个 `OK`，网络那句话是**随后**
    /// 以 `+CUSD` 主动上报来的（TS 27.007 §7.15）。没轮询线程的调用方
    /// （`dji4gctl ussd`）没法从 `send` 的返回值里拿到它，只能回头读这里。
    /// 写入在 URC 那条线程上，App 和命令行两个方向都在读，所以带一把锁。
    private let ussdLock = NSLock()
    private var lastUSSD: (reply: ATParsers.USSDReply, at: Date)?

    /// URC work queue — see `handle(urc:)`.
    private let urcLock = NSLock()
    private var urcQueue: [String] = []
    private var isDrainingURC = false

    /// Set once the first successful handshake completes.
    public private(set) var activeIdentity: USBModuleIdentity?

    public var onEvent: ((ModemEvent) -> Void)?
    public var preferredIdentity: USBModuleIdentity?

    private var pollThread: Thread?
    private var shouldPoll = false
    private let stateLock = NSLock()

    /// Called when the module is gone and the controller wants the owner to
    /// schedule a reconnect attempt.
    public var onTransportLost: (() -> Void)?

    public init(preferredIdentity: USBModuleIdentity? = nil) {
        self.preferredIdentity = preferredIdentity
        self.session = ATSession(factory: {
            if let path = ProcessInfo.processInfo.environment["DJI4G_SERIAL"], !path.isEmpty {
                return SerialATTransport(path: path)
            }
            return USBATTransport(identity: preferredIdentity)
        })
        self.sms = SMSService(session: session)
        self.calls = CallService(session: session)
        self.voice = VoiceService(session: session)
        self.data = DataService(session: session, identity: { [weak session] in
            _ = session
            return preferredIdentity ?? .dji
        })

        session.onUnsolicited = { [weak self] lines in
            self?.handle(urc: lines)
        }
        session.onTransportLost = { [weak self] error in
            self?.handleTransportLoss(error)
        }
        wireCallStateChanges()
    }

    public init(session: ATSession) {
        self.session = session
        self.sms = SMSService(session: session)
        self.calls = CallService(session: session)
        self.voice = VoiceService(session: session)
        self.data = DataService(session: session, identity: { .dji })
        session.onUnsolicited = { [weak self] lines in
            self?.handle(urc: lines)
        }
        session.onTransportLost = { [weak self] error in
            self?.handleTransportLoss(error)
        }
        wireCallStateChanges()
    }

    /// Pipes every call-state change to the UI as it happens.
    ///
    /// Answering, hanging up, dialling and swapping calls all mutate
    /// `CallService` directly; only `refreshCalls()` used to emit, and the poll
    /// that drives it runs every thirty seconds. Without this the panel goes on
    /// showing 「来电响铃」 for half a minute after the user has picked the
    /// call up — long enough that the natural reading is "the button is
    /// broken". Also covers the simulated transport, which has no poll-backed
    /// URCs to notice with.
    private func wireCallStateChanges() {
        calls.onStateChange = { [weak self] info in self?.emit(.call(info)) }
    }

    // MARK: - Lifecycle

    public func connect() throws {
        if let path = ProcessInfo.processInfo.environment["DJI4G_SERIAL"], !path.isEmpty {
            emit(.transport("串口 \(path)"))
        }
        try session.open()
        emit(.transport(session.channelDescription))
        for candidate in USBModuleIdentity.attached() where
            USBATTransport.candidates(for: candidate).isEmpty == false {
            activeIdentity = candidate
            break
        }
        isConnected = true
        try handshake()
    }

    public func disconnect() {
        stopPolling()
        _ = voice.deactivate()
        session.close()
        isConnected = false
        emit(.transport("未连接"))
    }

    /// Identity, SIM, network and signal — everything the panel header shows.
    public func handshake() throws {
        let ati = try session.send("ATI", timeout: 5)
        // 先认厂家，再问剩下的一切 —— 后面每一条命令该不该发、发哪一条，
        // 都由这一格决定。
        profile = VendorCatalog.profile(
            for: VendorDetector.detect(vendorID: activeIdentity?.vendorID,
                                       atiText: ati.lines.joined(separator: " ")))
        // 数据那一路也要知道是哪一族：它那几条命令（读/写上网模式、流量计数器）
        // 同样是厂家私有的。
        data.profile = profile
        if profile.family == .quectel {
            let revision = try? session.send("AT+QGMR", timeout: 5)
            identity = ATParsers.identity(fromATI: ati, revision: revision)
        } else {
            // `AT+QGMR` 是 Quectel 的固件版本命令，别的厂家一律回 `ERROR`。
            // 那些模块的版本就在 `ATI` 正文里（`Revision: …`），上面那个
            // 解析器本来就认它。
            identity = ATParsers.identity(fromATI: ati, revision: nil)
        }
        if let imei = try? session.send("AT+GSN", timeout: 5) {
            identity.imei = ATParsers.imei(from: imei)
        }
        identity.temperatures = readTemperatures()
        emit(.identity(identity))

        _ = try refreshSIM()
        try refreshNetwork()
        try refreshSignal()
        // The USB composition decides whether call audio can exist at all, so
        // read it up front rather than on first use.
        _ = refreshData()

        // What the panel calls 「当前 APN」 is a fact about the module, and the
        // only two places that read it were the two write paths. A module that
        // already had CMNET in it therefore showed 「未设置」 for as long as the
        // app was open — and the operator buttons had nothing to light up.
        _ = try? data.readAPN()
        emit(.data(data.status))

        if sim.ready {
            try? sms.configure()
            try? calls.configure()
            _ = try? refreshMessages()
        }
    }

    // MARK: - Status refreshes

    /// 重读模块里的短信，并把整份列表推给界面。
    ///
    /// `sms.refresh()` 只更新服务自己那份副本；面板看见的是 `.messages` 事件。
    /// 少了这一步，「按下刷新不重读收件箱」「删掉的那行还在原地」两件事在真机
    /// 上都只会表现成客户以为按钮坏了 —— 而短信是最不容易自己恢复的一页。
    @discardableResult
    public func refreshMessages() throws -> [SMSMessage] {
        let list = try sms.refresh()
        emit(.messages(list))
        return list
    }

    /// 这块模块的「声音功能」能不能由我们改。
    ///
    /// 那一串组态（`AT+QCFG="usbcfg"`）是 Quectel 的私有写法：读得出来才谈得
    /// 上写。别的厂家读不出来，也就改不了 —— 那时候该说的是「这块模块没有
    /// 这一项」，而不是把客户支去拔插模块，那解决不了问题。
    public var canConfigureAudio: Bool { data.status.composition != nil }

    /// 温度 —— 不是每块模块都报得出来。
    ///
    /// `AT+QTEMP` 是 Quectel 的，华为换 `AT^CHIPTEMP?`，芯讯换 `AT+CPMUTEMP`，
    /// 别的厂家多半压根没有这一项。读不到就是空数组，面板上那格留空 ——
    /// 编一个数字出来比空着糟得多。
    func readTemperatures() -> [String] {
        for command in profile.temperatureCommands {
            if let response = try? session.send(command, timeout: 5) {
                let values = ATParsers.temperatures(from: response)
                if !values.isEmpty { return values }
            }
        }
        return []
    }

    public func refreshSIM() throws -> SIMStatus {
        let response = try session.send("AT+CPIN?", timeout: 5)
        // A negative `AT+CPIN?` does not always say which way it failed: some
        // firmware answers `+CME ERROR: 10` both for an empty slot and for a
        // card it cannot talk to. `AT+QSIMSTAT?` reports the card-detect pin,
        // which settles it. Only worth asking when the card is not ready, and
        // firmware without the command just answers ERROR, which drops the
        // probe rather than the refresh.
        var probe: ATResponse?
        if !response.isOK {
            probe = try? session.send("AT+QSIMSTAT?", timeout: 3)
        }
        var fresh = ATParsers.simStatus(fromCPIN: response, qsimstat: probe)

        if fresh.ready {
            // 上一次那两个编号先留一份：下面每一条读失败的时候，要靠它判断
            // 「这张卡到底换了没有」。
            let previous = sim
            if let cimi = try? session.send("AT+CIMI", timeout: 5) {
                fresh.imsi = ATParsers.subscriberID(from: cimi)
            }
            if let ccid = try? session.send("AT+QCCID", timeout: 5) {
                fresh.iccid = ATParsers.subscriberID(from: ccid)
            } else if let ccid = try? session.send("AT+CCID", timeout: 5) {
                fresh.iccid = ATParsers.subscriberID(from: ccid)
            }
            if let cnum = try? session.send("AT+CNUM", timeout: 5) {
                fresh.ownNumber = ATParsers.ownNumber(fromCNUM: cnum)
            }
            // 2026-09-26 加：一次读超时（USB 端点 `e00002d6`、被别的进程抢走
            // 那几拍、固件忙）不该把上一次读到的那张卡号一起抹掉。
            //
            // `fresh` 是一份全新的结构，读不到就是空串，而空串会一路传到
            // `currentSIMKey` 上 —— 这张卡的身份键当场从 20 位 ICCID 掉成 15 位
            // IMSI。同一个主人两个键来回跳，`moduleAPNIsForeign` 就会认成
            // 「换了张卡」，反手把客户手选的 APN 改写成运营商默认值，而那条路
            // 从头到尾没问过客户。真机上抓到过一次：18:44:41 的「换了张卡」，
            // 紧跟在 `AT+QCCID` 那一拍超时之后，模块里的值一个字没动 —— 纯误判。
            //
            // 沿用只在另一个编号能证明卡没换的时候发生：读到了、而且和上一次
            // 一模一样。真的换了卡，另一个编号必然跟着变，这里不会沿用（自检
            // 的 ③④ 两条盯着这件事）；两个都读不到就照旧交白卷，白卷等于
            // 「认不出来」，上面那条路自己会收手。
            if fresh.iccid.isEmpty, !fresh.imsi.isEmpty, fresh.imsi == previous.imsi {
                fresh.iccid = previous.iccid
            }
            if fresh.imsi.isEmpty, !fresh.iccid.isEmpty, fresh.iccid == previous.iccid {
                fresh.imsi = previous.imsi
            }
            // 归属运营商只跟 IMSI 走：漫游时驻留网络会变（见 `NetworkStatus.
            // carrier`），但卡是哪家的、APN 该配哪家的一辈子不变。
            fresh.homeCarrier = CarrierCatalog.carrier(forIMSI: fresh.imsi)
        }
        sim = fresh
        emit(.sim(fresh))
        return fresh
    }

    @discardableResult
    public func refreshNetwork() throws -> NetworkStatus {
        var fresh = network

        if let creg = try? session.send("AT+CREG?", timeout: 5),
           let state = ATParsers.registration(from: creg, prefix: "+CREG") {
            fresh.registration = state
        }
        var ceregResponse: ATResponse?
        if let cereg = try? session.send("AT+CEREG?", timeout: 5) {
            ceregResponse = cereg
            if let state = ATParsers.registration(from: cereg, prefix: "+CEREG") {
                fresh.packetRegistration = state
                // 这里以前会把分组域的结果盖进 `registration`，好让只看电路域
                // 的旧代码也能显示「已注册」。代价是电路域的真实状态被抹掉，
                // 之后再也分不清「没注册」和「被拒绝」，也就没法对客人解释
                // 通话为什么用不了。现在两个域各存各的，显示交给
                // `NetworkStatus.reportedRegistration` / `dataRegistered`。
            }
        }
        readNetworkInfo(into: &fresh, cereg: ceregResponse)
        if let cops = try? session.send("AT+COPS?", timeout: 8) {
            if let name = ATParsers.operatorName(from: cops), !name.isEmpty {
                if fresh.carrier.mccmnc.isEmpty {
                    // `+COPS?` only carries the name on some firmware revisions,
                    // and the name is enough to pick the APN if it is one we
                    // know. It used to be discarded here, which left the carrier
                    // holding an empty APN — i.e. AUTO did nothing on exactly
                    // the modules that had managed to register.
                    let known = CarrierCatalog.carrier(forOperatorName: name)
                    fresh.carrier = known
                        ?? Carrier(mccmnc: "", name: name, shortName: name, apns: [])
                }
            }
        }
        network = fresh
        emit(.network(fresh))
        return fresh
    }

    /// 只看「模块还在不在网」——比 `refreshNetwork()` 便宜得多的一条。
    ///
    /// 为什么单独开一条（2026-09-26 真机实测）：模块这条网络服务开着的时候，
    /// macOS 的默认路由就压在模块上，「它还在不在网」直接等于「客人的整台
    /// 电脑还有没有网」。而三十秒才跑一次的 `refreshNetwork()` 一次要发四条
    /// AT，其中 `AT+COPS?` 在模块掉网的时候要等满八秒超时 —— 想靠它变快，
    /// 只会把 AT 口占得更久，界面和通话跟着一起卡，而且**看见得更晚**。
    /// 这一条只发 `AT+CREG?` 和 `AT+CEREG?`：注册状态就藏在这两条里
    /// （见 `NetworkStatus.dataRegistered`），模块哪怕掉网了也答得飞快，
    /// 正好够 `guardDataRoute()` 判那一下。
    ///
    /// 不带 `AT+QNWINFO` / `AT+COPS?`：那两条管的是运营商名字、频段、制式，
    /// 面板显示要用，但和「这条路还能不能用」没有关系，留给三十秒那条。
    @discardableResult
    public func refreshRegistration() throws -> NetworkStatus {
        var fresh = network
        if let creg = try? session.send("AT+CREG?", timeout: 5),
           let state = ATParsers.registration(from: creg, prefix: "+CREG") {
            fresh.registration = state
        }
        if let cereg = try? session.send("AT+CEREG?", timeout: 5),
           let state = ATParsers.registration(from: cereg, prefix: "+CEREG") {
            fresh.packetRegistration = state
            // 制式就藏在这条命令的第五格里（TS 27.007 §7.2 的 `AcT`）。它是
            // 通用的：任何一块正经模块都答，不像 `AT+QNWINFO` 那样只有 Quectel
            // 认。白拿的一格，顺手补上。
            if fresh.accessTechnology.isEmpty,
               let act = ATParsers.accessTechnology(fromRegistration: cereg, prefix: "+CEREG") {
                fresh.accessTechnology = act
            }
        }
        let changed = fresh.registration != network.registration
            || fresh.packetRegistration != network.packetRegistration
        network = fresh
        // 只在真的翻页时出声。这一条几秒一问，每次都推一遍事件的话，面板和
        // 自动配 APN 那套判断会被同一份没变的状态反复叫醒。
        if changed { emit(.network(fresh)) }
        return fresh
    }

    /// 制式 / 频段 / 频点 —— 按本族的命令链读。
    ///
    /// 链尾永远留一条通用的：注册状态里那个 `AcT` 码（`cereg` 就是调用方刚
    /// 拿到的那一条，白借，不额外发命令）。频段和频点只有厂家命令给得出来，
    /// 给不出来就空着 —— 编一个数字出来比空着糟得多。
    func readNetworkInfo(into status: inout NetworkStatus, cereg: ATResponse?) {
        for command in profile.networkInfoCommands {
            guard let response = try? session.send(command, timeout: 8) else { continue }
            if command.hasPrefix("AT+QNWINFO") {
                ATParsers.networkInfo(from: response, into: &status)
            } else if command.hasPrefix("AT+QENG") {
                // 这条顺带带回来一份信号。这里只要它那半张网络表，信号由
                // `refreshSignal()` 那一头负责，别重复写。
                var scratch = SignalStatus()
                ATParsers.mergeQENG(response, into: &status, signal: &scratch)
            } else if command.hasPrefix("AT+CPSI") {
                ATParsers.mergeCPSI(response, into: &status)
            } else if command.hasPrefix("AT^SYSINFOEX") {
                ATParsers.mergeSYSINFOEX(response, into: &status)
            } else if command.hasPrefix("AT^HCSQ") {
                // 华为的 HCSQ 第一格就是制式（`"LTE"`）。这一条只借那一格。
                if status.accessTechnology.isEmpty,
                   let raw = response.firstValue(for: "^HCSQ"),
                   let rat = ATParsers.splitQuoted(raw).first, !rat.isEmpty {
                    status.accessTechnology = rat
                }
            }
            // 三格都齐了就不必再问后面的 —— 链子是按「细 → 粗」排的。
            if !status.accessTechnology.isEmpty, !status.band.isEmpty, status.channel != nil {
                break
            }
        }
        if status.accessTechnology.isEmpty, let cereg,
           let act = ATParsers.accessTechnology(fromRegistration: cereg, prefix: "+CEREG") {
            status.accessTechnology = act
        }
    }

    /// 信号 —— 按本族的命令链读。
    ///
    /// 和以前不一样的地方只有一处：链子是从 `profile` 里取的。Quectel 那一族
    /// 的链就是原来那三条命令、原来的顺序，所以大疆这块模块上的读数一个字节
    /// 都不会变；换一块别的厂家的模块，链子换成它认得的那几条，末尾永远有一条
    /// 3GPP 标准的 `AT+CESQ` 兜底。
    @discardableResult
    public func refreshSignal() throws -> SignalStatus {
        var fresh = SignalStatus()
        if let csq = try? session.send("AT+CSQ", timeout: 5) {
            fresh = ATParsers.signal(fromCSQ: csq)
        }
        for command in profile.signalCommands {
            // `AT+CSQ` 刚在上面问过，链里那条跳过，不白占 AT 口。
            if command == "AT+CSQ" { continue }
            guard let response = try? session.send(command, timeout: 8) else { continue }
            if command.hasPrefix("AT+QCSQ") {
                ATParsers.mergeQCSQ(response, into: &fresh)
            } else if command.hasPrefix("AT+QENG") {
                ATParsers.mergeQENG(response, into: &network, signal: &fresh)
            } else if command.hasPrefix("AT+CESQ") {
                ATParsers.mergeCESQ(response, into: &fresh)
            } else if command.hasPrefix("AT^HCSQ") {
                ATParsers.mergeHCSQ(response, into: &fresh)
            } else if command.hasPrefix("AT+CPSI") {
                ATParsers.mergeCPSI(response, into: &network)
            }
        }
        signal = fresh
        emit(.signal(fresh))
        return fresh
    }

    @discardableResult
    public func refreshData() -> DataStatus {
        let fresh = data.refreshStatus()
        emit(.data(fresh))
        return fresh
    }

    /// 高频、零 AT 的计数器刷新，专给面板上那个两秒一次的定时器用。
    ///
    /// 和 `refreshData()` 的分工是「完整」和「便宜」：`refreshData()` 会读
    /// USB 组态、会拉 `networksetup`，只适合打开面板、手动刷新、切换模式这些
    /// 一次性动作；这条路径只把 macOS 接口计数器和 IPv4 重新读一遍，本地系统
    /// 调用，所以通话期间也能照跑 —— 通话时 AT 口归语音链路，这条路上一条命令
    /// 都没有，抢不到它。
    ///
    /// 单独开一个入口而不是给 `refreshData()` 加参数：调用方是「每两秒」，它需要
    /// 一眼看出这条路径不碰 AT，而不是去记住某个默认参数。
    @discardableResult
    public func refreshHostCounters() -> DataStatus {
        let fresh = data.refreshCountersOnly()
        emit(.data(fresh))
        return fresh
    }

    @discardableResult
    public func refreshCalls() throws -> CallInfo {
        let info = try calls.refresh()
        emit(.call(info))
        return info
    }

    /// Writes an APN into PDP context 1.
    ///
    /// `carrier` nil is the automatic path: use whoever the module says the card
    /// belongs to. The settings window passes an operator explicitly, because a
    /// card that has not registered yet cannot be detected — and that is exactly
    /// the moment someone is standing there trying to make 4G work.
    ///
    /// Throws rather than returning nil. A caller that gets nil and does nothing
    /// is indistinguishable from a button that was never wired up, which is what
    /// the three operator buttons used to be.
    @discardableResult
    public func applyCarrierAPN(force: Bool = false, carrier chosen: Carrier? = nil) throws -> String {
        // APN 跟「卡的归属运营商」走，不跟「当前驻留网络」走。
        //
        // 手动按钮（chosen 非空）永远优先；自动路则先认 IMSI 推出的归属。
        // 香港卡在大陆漫游时，`network.carrier` 报的是中国移动（驻留网络），
        // 照它写 CMNET 等于把香港卡写坏 —— 归属是 CMHK 就该写 cmhk。
        let carrier: Carrier
        if let chosen {
            carrier = chosen
        } else {
            // 只看卡的归属。归属认不出来（IMSI 的 MCC/MNC 不在表里）时，
            // 不拿驻留网络去猜 —— 外卡漫游到移动网，猜成 CMNET 就是写坏。
            // 交给 `noOperator`：界面会引导客户去「自定义」里填 APN。
            carrier = sim.homeCarrier
        }
        let existing = (try? data.readAPN()) ?? nil

        // Nothing to go on. An APN already in the module is not made worse by
        // the fact that the operator could not be read, so keep it and say so
        // instead of blanking it.
        let candidates = carrier.apns.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !candidates.isEmpty else {
            if let existing, !existing.isEmpty {
                emit(.note("读不到运营商，沿用模块里已有的接入点：\(existing)"))
                return existing
            }
            throw APNError.noOperator
        }

        if !force, let existing, !existing.isEmpty, carrier.matches(apn: existing) {
            emit(.note("接入点已经是 \(existing)（\(carrier.name)），无需改动"))
            return existing
        }

        // 多个候选按优先级依次尝试：首选写不进就退到下一个，全部失败才报错。
        var lastError: Error?
        for candidate in candidates {
            do {
                try data.configureAPN(candidate)
                emit(.note("已设置接入点为 \(candidate)（\(carrier.name)）"))
                return candidate
            } catch {
                lastError = error
            }
        }
        // 全部候选都失败：把旧值写回去，别把模块留在半新不旧的状态里。
        if let existing, !existing.isEmpty, !carrier.matches(apn: existing) {
            _ = try? data.configureAPN(existing)
        }
        throw APNError.writeFailed(carrier: carrier.name,
                                   apn: candidates.joined(separator: "/"),
                                   reason: lastError ?? DataError.invalidParameter("未知错误"))
    }

    // MARK: - Unsolicited handling

    /// Reacting to a URC sends further AT commands, and their answers can come
    /// back through this same entry point. Lines are queued and drained by the
    /// outermost call, so re-entry never recurses or deadlocks.
    private func handle(urc lines: [String]) {
        urcLock.lock()
        urcQueue.append(contentsOf: lines)
        if isDrainingURC {
            urcLock.unlock()
            return
        }
        isDrainingURC = true
        urcLock.unlock()

        while true {
            urcLock.lock()
            if urcQueue.isEmpty {
                isDrainingURC = false
                urcLock.unlock()
                return
            }
            let line = urcQueue.removeFirst()
            urcLock.unlock()
            process(urc: line)
        }
    }

    private func process(urc line: String) {
        // USSD 的答案只能从这里进来 —— 命令那条路上只回一个 `OK`。
        // 判在最前面：`+CUSD` 是完整的一行，不会被下面任何一条吃掉。
        if let reply = ATParsers.ussdReply(from: line) {
            ussdLock.lock()
            lastUSSD = (reply, Date())
            ussdLock.unlock()
            emit(.ussd(reply))
            return
        }
        if calls.handle(urc: line) {
            emit(.call(calls.current))
            return
        }
        if let index = SMSService.storageIndex(fromURC: line) {
            if let message = sms.handleIncoming(index: index) {
                emit(.incomingSMS(message))
                emit(.messages(sms.messages))
            } else {
                emit(.note("收到短信通知（槽位 \(index)）但读取失败"))
            }
            return
        }
        let upper = line.uppercased()
        if upper.hasPrefix("+CMT:") {
            // Full PDU pushed directly on the URC line's following bytes.
            return
        }
        if upper.hasPrefix("+CREG:") || upper.hasPrefix("+CGREG:") || upper.hasPrefix("+CEREG:") {
            // 掉网这一下必须便宜。`refreshNetwork()` 里那条 `AT+COPS?` 在模块
            // 没在网的时候要等满八秒超时，而模块掉网的第一秒就是客人开始
            // 没网的第一秒 —— 拿一条要等八秒的命令去发现它，客人就得白等
            // 这八秒（2026-09-26 真机实测：从掉网到默认路由交回 Wi-Fi 一共
            // 三十一秒，其中二十四秒都花在「多久才看见」上）。注册状态只藏
            // 在 `AT+CREG?` / `AT+CEREG?` 里，先问这两条便宜的。
            let wasRegistered = network.dataRegistered
            _ = try? refreshRegistration()
            // 反过来，**刚注册上来**那一下要把运营商名字问全：自动配 APN 靠
            // 它认卡，认不出是哪一家，客户就会停在「卡就绪、APN 空着、上不了
            // 网」那一格。上来的时候问不心疼 —— 模块答得快，而且这条路一个
            // 注册周期只走一次。
            if network.dataRegistered, !wasRegistered { _ = try? refreshNetwork() }
            return
        }
        if upper.contains("SIM") || upper.hasPrefix("+CPIN:") || upper.hasPrefix("+QUSIM") {
            _ = try? refreshSIM()
            return
        }
        emit(.note(line))
    }

    private func handleTransportLoss(_ error: Error) {
        isConnected = false
        // 电话是最先没的那一个，而且只有这里会说出来。断线这条路不走
        // `AppModel.disconnect()`（客户不一定拔线：模块自己重启、AT 口被
        // 别的程序抢走都走这里），那一处清通话状态的行也就轮不到 —— 不补
        // 这一下，面板会停在「通话中」、时长接着走，一通永远挂不断的电话。
        calls.abandonLostLink()
        emit(.transportLost("\(error)"))
        onTransportLost?()
    }

    // MARK: - USSD 与选网

    /// 发一条 USSD：查话费、查流量、开业务那一类。
    ///
    /// 返回的是**命令有没有收下**，不是答案 —— 答案随后以 `+CUSD` 上报进来，
    /// 走 `onEvent` 的 `.ussd`，或者 `latestUSSD(since:)`。这是 3GPP 定死的流程
    /// （TS 27.007 §7.15），换哪家模块都一样，所以这一条不分厂家档案。
    @discardableResult
    public func sendUSSD(_ code: String, dcs: Int = 15) throws -> ATResponse {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        var response = try session.send("AT+CUSD=1,\"\(trimmed)\",\(dcs)", timeout: 12)
        // 少数固件只认两个参数，多给 `<dcs>` 就回 ERROR。退一步再试一次 ——
        // 这一步没在猜协议，只是把同一件事少说一个字。
        if !response.isOK {
            response = try session.send("AT+CUSD=1,\"\(trimmed)\"", timeout: 12)
        }
        return response
    }

    /// `since` 之后收到的第一条 USSD 答复。
    public func latestUSSD(since: Date) -> ATParsers.USSDReply? {
        ussdLock.lock(); defer { ussdLock.unlock() }
        guard let lastUSSD, lastUSSD.at >= since else { return nil }
        return lastUSSD.reply
    }

    /// 等到一条 USSD 答复，或者超时。
    ///
    /// 给**没有轮询线程**的调用方用（`dji4gctl ussd`）：App 里那条一秒一拍的
    /// 轮询本来就在读这条口，答案自己会到，谁都不用来等。命令行是一次性的，
    /// 不主动读那一口就永远等不到 `+CUSD`。
    public func waitForUSSD(since: Date, timeout: TimeInterval = 20) -> ATParsers.USSDReply? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let reply = latestUSSD(since: since) { return reply }
            _ = session.pollUnsolicited(timeout: 0.3)
        }
        return latestUSSD(since: since)
    }

    /// 扫一遍当前位置能看到的运营商（`AT+COPS=?`）。
    ///
    /// 按标准这条要等二十秒到一分钟：模块得把所有频段挨个搜一遍。**它整段
    /// 时间都占着 AT 口**，读数的轮询进不来 —— 只在「卡怎么都不注册」的时候
    /// 用它，别放进自动流程。
    public func scanOperators(timeout: TimeInterval = 60) throws -> [ATParsers.NetworkOperator] {
        let response = try session.send("AT+COPS=?", timeout: timeout)
        // 2026-09-28 真机（QDC507，电信卡）：这一条不止慢 —— 量过 90 秒都不回话，
        // 而且**回话之前整个 AT 口都醒不过来**，后面两分钟里连一句 `AT` 都没人
        // 应。所以超时和「空列表」必须分开报：空列表是「周围确实只有这些」，
        // 超时是「模块正占着口子在搜」。混成一句「没扫到」，客户只会以为是自己
        // 信号差，然后一遍遍重按。
        guard response.final != .timeout else {
            throw ATTransportError.ioFailed(
                "扫网没有在 \(Int(timeout)) 秒内回话。这一下模块要把周围的频段挨个搜一遍，"
                + "搜完之前它的 AT 口整个占着 —— 面板那几分钟会不回话，搜完自己就恢复。"
                + "不用它也行，手动选网在绝大多数情况下没有必要。")
        }
        return ATParsers.operators(fromCOPSScan: response)
    }

    /// 手动登记到某一家运营商。`numeric` 是五或六位 MCC+MNC（`46011` 这种）。
    ///
    /// 两套写法都合法，先按档案说的那套来：华为那几家吃三个参数，移远和
    /// 芯讯吃四个。第一条没成就换另一条 —— 客户在面板上按下这一下的时候，
    /// 分不出也管不着是哪一家固件。
    @discardableResult
    public func selectOperator(numeric: String) throws -> ATResponse {
        let digits = numeric.filter { $0.isNumber }
        let four = "AT+COPS=1,2,\"\(digits)\",7"
        let three = "AT+COPS=1,2,\"\(digits)\""
        var response = try session.send(profile.networkSelectAcceptsAct ? four : three, timeout: 60)
        if !response.isOK {
            response = try session.send(profile.networkSelectAcceptsAct ? three : four, timeout: 60)
        }
        return response
    }

    /// 交回自动选网。客户手动选过一家、后来又搬了地方，走这一条回来。
    @discardableResult
    public func selectOperatorAutomatic() throws -> ATResponse {
        try session.send("AT+COPS=0", timeout: 60)
    }

    // MARK: - Polling

    /// Reads unsolicited lines in the background so `RING` / `+CMTI:` are seen
    /// without a UI-driven refresh.
    /// 「模块还在不在网」要不要按快档问。见 `registrationWatchEvery()`。
    ///
    /// 主线程写、轮询线程读，和 `sim` / `data.status` 一样：它是条策略提示，
    /// 不是安全闸门，晚三秒生效没有任何后果。
    public var watchingRegistration = false

    /// 「模块还在不在网」多久问一次，按轮询的滴答数算（一滴答一秒）。
    /// 0 = 这一档不问，交给 `refreshNetwork()` 那条三十秒一次的整体刷新。
    ///
    /// 为什么只在这两个窗口快问（2026-09-26 真机实测）：默认路由在 Wi-Fi 上
    /// 的时候，模块在不在网跟客人没有任何关系，白问；只有「4G 那条服务开着、
    /// 默认路由押在模块上」和「刚把路由撤回来、正等着还给模块」才值得。
    ///
    /// 三秒也不是随便定的：判定那一步（`AppModel.guardDataRoute`）本来就跑在
    /// 三秒一拍的巡检上，问得比它更勤只是多占 AT 口，不会更早看见。
    public static func registrationWatchEvery(watching: Bool) -> Int {
        watching ? 3 : 0
    }

    public func startPolling(interval: TimeInterval = 1.0,
                             refreshStatusEvery: Int = 15) {
        stopPolling()
        shouldPoll = true
        let thread = Thread { [weak self] in
            guard let self else { return }
            var tick = 0
            while self.shouldPoll {
                if self.session.isOpen {
                    _ = self.session.pollUnsolicited(timeout: min(0.5, interval))
                    tick += 1
                    if tick % max(1, refreshStatusEvery) == 0 {
                        _ = try? self.refreshSignal()
                    }
                    if tick % max(1, refreshStatusEvery * 2) == 0 {
                        _ = try? self.refreshNetwork()
                        _ = try? self.refreshCalls()
                    }
                    // 「模块还在不在网」单独走快档：默认路由押在模块上的时候，
                    // 这一问直接等于「客人的整台电脑还有没有网」。这条路径的
                    // 价值全在**快**，而上面那条三十秒一次的整体刷新做不到 ——
                    // 它还会被 App 那边的长动作（模块断电后重装通话语音要二十
                    // 多秒）挤掉。见 `refreshRegistration()`。
                    let watchEvery = Self.registrationWatchEvery(watching: self.watchingRegistration)
                    if watchEvery > 0, tick % watchEvery == 0 {
                        _ = try? self.refreshRegistration()
                    }
                    // 卡的状态不能只等 URC：一代模块插卡后不一定吭声，面板就会
                    // 一直停在「未插卡」，客户只会以为模块坏了。没就绪的时候问勤
                    // 一点（客户刚把卡按进去的那几秒就是全部意义），就绪之后放
                    // 慢，只留着发现「卡被拔了」。没卡时只有一两条 AT，便宜。
                    let simEvery = self.sim.ready
                        ? max(1, refreshStatusEvery * 4)
                        : max(1, refreshStatusEvery / 3)
                    if tick % simEvery == 0 {
                        _ = try? self.refreshSIM()
                    }
                }
                Thread.sleep(forTimeInterval: interval)
            }
        }
        thread.name = "dji4g.poll"
        thread.qualityOfService = .utility
        pollThread = thread
        thread.start()
    }

    public func stopPolling() {
        shouldPoll = false
        pollThread = nil
    }

    private func emit(_ event: ModemEvent) {
        onEvent?(event)
    }
}
