import Foundation

/// The three things the module is bought for. Every check names the goals it
/// stands in the way of, so a failure can be read as "which ability does this
/// cost me" instead of a raw AT status.
public enum Capability: String, CaseIterable {
    case calls
    case sms
    case internet

    public var label: String {
        switch self {
        case .calls: return "来电与拨号"
        case .sms: return "收发短信"
        case .internet: return "联网"
        }
    }
}

public enum CheckState: String {
    case ok
    case warn
    case fail
    case skipped

    public var symbol: String {
        switch self {
        case .ok: return "✓"
        case .warn: return "!"
        case .fail: return "✗"
        case .skipped: return "–"
        }
    }

    public var label: String {
        switch self {
        case .ok: return "正常"
        case .warn: return "待设置"
        case .fail: return "失败"
        case .skipped: return "跳过"
        }
    }

    /// A check is in the way when it is anything other than a clean pass.
    public var blocks: Bool { self == .fail || self == .warn }
}

public struct DoctorCheck {
    public let title: String
    public let state: CheckState
    public let detail: String
    /// What to run to clear it. Kept next to the failure so the report can be
    /// followed top to bottom without consulting anything else.
    public let fix: String?
    public let blocks: [Capability]

    public init(title: String, state: CheckState, detail: String,
                fix: String? = nil, blocks: [Capability] = []) {
        self.title = title
        self.state = state
        self.detail = detail
        self.fix = fix
        self.blocks = blocks
    }
}

/// Everything the report is derived from, gathered once. Kept separate from the
/// gathering so the verdict logic stays a pure function the self-test can drive.
public struct DoctorFacts {
    public var transport: String = ""
    public var atResponsive: Bool = false
    public var firmware: String = ""
    public var imei: String = ""
    public var usbnetMode: USBnetMode?
    public var composition: USBComposition?
    public var simReady: Bool = false
    public var simDetail: String = ""
    /// 卡这一项的下一步动作。由 `SIMStatus.guidance` 填，空则用通用提示。
    public var simFix: String = ""
    public var registered: Bool = false
    public var carrier: String = ""
    public var signalDBm: String = ""
    public var apn: String = ""
    public var interfaceName: String = ""
    public var ipv4: String = ""
    public var serviceName: String = ""
    public var serviceEnabled: Bool = false
    public var hasModuleAudio: Bool = false
    public var audioDeviceName: String = ""
    public var smsStorage: String = ""
    public var smsUnread: Int = 0
    /// 用满的存储会把新短信吃掉 —— 这不是「快满了注意一下」，是新短信真的
    /// 收不到，所以它得单独一个字段，不能靠解析 `smsStorage` 那个字符串。
    public var smsStorageFull: Bool = false

    public init() {}
}

/// Turns `DoctorFacts` into an ordered, actionable report.
///
/// The failure this exists for: the module's factory configuration ships with a
/// proprietary network mode that macOS has no driver for, so no interface ever
/// appears — with no error anywhere to explain it.
///
/// 报告里原来还有第二条「USB 音频没开 → 来电与拨号不可用」。那个因果关系是
/// 反的：声卡开不开，拨号、接听、挂断、短信都照常（2026-09-25 真机实测）。
/// 声卡是通话**语音**的载体，而语音还另需一次「一键安装」把厂商驱动
/// 和出厂校准写进模块（见 `ModuleVoiceSetup`）。所以这一项不再拦任何能力，
/// 只作为一次性设置的一项事实说明 —— 不然客户会照着一句不成立的话去点按钮。
public enum Doctor {
    public static func evaluate(_ facts: DoctorFacts) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []

        checks.append(DoctorCheck(
            title: "USB 连接",
            state: facts.transport.isEmpty ? .fail : .ok,
            detail: facts.transport.isEmpty ? "没有找到模块" : facts.transport,
            fix: facts.transport.isEmpty
                ? "插上模块，确认 system_profiler SPUSBDataType 里有 BAIWANG/QDC507"
                : nil,
            blocks: Capability.allCases))

        guard facts.atResponsive else {
            checks.append(DoctorCheck(
                title: "AT 通道",
                state: .fail,
                detail: "模块没有响应 AT 命令",
                fix: "拔插一次模块；若仍无响应，查看是否有其它程序占用了串口",
                blocks: Capability.allCases))
            return checks
        }

        checks.append(DoctorCheck(
            title: "AT 通道",
            state: .ok,
            detail: [facts.firmware, facts.imei.isEmpty ? "" : "IMEI \(facts.imei)"]
                .filter { !$0.isEmpty }.joined(separator: " · "),
            blocks: Capability.allCases))

        // The two one-time module settings. Both need a reboot to take effect,
        // so when neither has been done yet they are written in one pass: two
        // reboots are two chances for the module not to come back.
        let audioOn = facts.composition?.audio ?? false
        let ecmOn = facts.usbnetMode == .ecm
        let combined = (!audioOn && !ecmOn) ? "dji4gctl prepare   # 两项一起写，只重启一次" : nil

        // 这一项**不拦**「来电与拨号」。它以前拦，理由写的是「不开就没有声音」。
        // 2026-09-25 的真机实测把因果关系理清了：声卡在**不等于**通话有声音
        // （固件默认不建 DSP 语音通路，要靠「一键安装」把驱动和出厂
        // 校准写进去），但反过来，声卡是语音的载体 —— 没有它，装什么都听不见。
        // 所以它仍然是「一键启用顺手就写」的一次性设置，只是不再拦任何能力：
        // 拨号、接听、挂断、收发短信都不看它。
        checks.append(DoctorCheck(
            title: "模块声卡",
            state: audioOn ? .ok : .warn,
            detail: audioOn
                // 这里不写「光开着还不够」那种话：声卡开着只是它自己这一格，
                // 装没装过通话语音要看 ADB 那一趟（2026-09-27 装好之后跑
                // doctor，读到「先跑一次一键安装」会以为自己白装了）。
                ? "已开启（通话语音走它）。装好没有，跑 dji4gctl voice-provision 看"
                : "未开启（出厂组态）。拨号、接听、短信都不看它，但通话语音需要它：「一键启用」会顺手写 1，之后跑一次「一键安装」",
            fix: audioOn ? nil : (combined ?? "dji4gctl voice-enable   # 会重启模块"),
            blocks: []))

        checks.append(DoctorCheck(
            title: "USB 网络模式",
            state: ecmOn ? .ok : .warn,
            detail: ecmOn
                ? "ECM，macOS 自带驱动"
                : "当前 \(facts.usbnetMode?.technicalName ?? "未知")，macOS 没有对应驱动",
            fix: ecmOn ? nil : (combined ?? "dji4gctl usbnet 1   # 会重启模块"),
            blocks: [.internet]))

        checks.append(DoctorCheck(
            title: "SIM 卡",
            state: facts.simReady ? .ok : .fail,
            detail: facts.simDetail.isEmpty ? (facts.simReady ? "已就绪" : "未就绪") : facts.simDetail,
            // 没插卡和欠费停机要做的事不一样，所以这句提示跟着卡的实际状态走。
            fix: facts.simReady
                ? nil
                : (facts.simFix.isEmpty ? "确认卡座方向正确，且 SIM 没有欠费/停机" : facts.simFix),
            blocks: [.calls, .sms, .internet]))

        // 没有卡的时候注册必然失败，那不是第二个问题：多报一条只会让人去查
        // 天线，而真正要做的是把卡插上。跟 ECM 未开时的网卡一项同样处理。
        if facts.simReady {
            checks.append(DoctorCheck(
                title: "网络注册",
                state: facts.registered ? .ok : .fail,
                detail: facts.registered
                    ? [facts.carrier, facts.signalDBm].filter { !$0.isEmpty }.joined(separator: " · ")
                    : "未注册到运营商",
                fix: facts.registered ? nil : "检查天线是否接好，或换个位置再看信号",
                blocks: [.calls, .sms, .internet]))
        } else {
            checks.append(DoctorCheck(
                title: "网络注册",
                state: .skipped,
                detail: "SIM 卡就绪后模块才会注册",
                blocks: []))
        }

        checks.append(DoctorCheck(
            title: "短信通道",
            state: (facts.smsStorage.isEmpty || facts.smsStorageFull) ? .warn : .ok,
            detail: facts.smsStorage.isEmpty
                ? "读不到短信存储"
                : "存储 \(facts.smsStorage)\(facts.smsUnread > 0 ? "，\(facts.smsUnread) 条未读" : "")"
                  + (facts.smsStorageFull ? "（已满）" : ""),
            fix: facts.smsStorage.isEmpty
                ? "dji4gctl at AT+CPMS?"
                : (facts.smsStorageFull
                   ? "存储满了，新短信会被网络丢掉。先删旧短信，或把接收存储换到 SIM 卡：dji4gctl sms-storage SM"
                   : nil),
            // 满了只挡「收新的」，已经存在里面的照样能读能删 —— 所以是 warn，
            // 但确实要挡一挡，否则客人以为短信功能是好的。
            blocks: facts.smsStorageFull ? [.sms] : []))

        checks.append(contentsOf: internetChecks(facts))
        return checks
    }

    private static func internetChecks(_ facts: DoctorFacts) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []

        // 建议得跟着卡走。写死 CTNET 的版本会让移动/联通/广电的卡也照抄
        // 电信的 APN —— 客户照着报告做，反而连不上。认不出运营商时给自动
        // 那一条，它插卡后自己会认。
        let apnFix: String
        if let known = CarrierCatalog.carrier(forOperatorName: facts.carrier),
           !known.apn.isEmpty {
            apnFix = "dji4gctl apn \(known.apn)"
        } else {
            apnFix = "dji4gctl apn"
        }
        // 「APN 里存着什么」和「数据能不能出去」是两件事，客人问的是后者。
        // 网卡已经拿到 IP 的时候 APN 必然是对的，这时候还判它失败，报告会
        // 自己打自己的脸：上一条写着 en59 有地址，下一条说 PDP 无法激活，
        // 客户就照着去查一个根本没坏的东西。
        let apnKnown = !facts.apn.isEmpty
        let dataUp = apnKnown || !facts.ipv4.isEmpty
        checks.append(DoctorCheck(
            title: "APN",
            state: dataUp ? .ok : .warn,
            detail: apnKnown
                ? facts.apn
                : (dataUp ? "未读到 APN 名，但网卡已拿到 IP，流量在走"
                          : "未设置，PDP 无法激活"),
            fix: dataUp ? nil : apnFix,
            blocks: [.internet]))

        // Everything below only means something once the module is in ECM mode;
        // an interface cannot exist before then, so a failure here is reported
        // as a consequence rather than a second problem to chase.
        guard facts.usbnetMode == .ecm else {
            checks.append(DoctorCheck(
                title: "网卡与 IP",
                state: .skipped,
                detail: "切到 ECM 并重启后才会出现",
                blocks: []))
            return checks
        }

        checks.append(DoctorCheck(
            title: "网卡与 IP",
            state: facts.ipv4.isEmpty ? .fail : .ok,
            detail: facts.ipv4.isEmpty
                ? (facts.interfaceName.isEmpty ? "macOS 没有为模块建网卡" : "\(facts.interfaceName) 未取得 IP")
                : "\(facts.interfaceName) · \(facts.ipv4)",
            fix: facts.ipv4.isEmpty ? "拔插模块，或在「系统设置 → 网络」里确认该网卡为 DHCP" : nil,
            blocks: [.internet]))

        // The setting nobody finds on their own: the interface can be up with a
        // valid address while macOS still sends every packet over Wi-Fi.
        checks.append(DoctorCheck(
            title: "macOS 网络服务",
            state: facts.serviceEnabled ? .ok : .warn,
            detail: facts.serviceEnabled
                ? "「\(facts.serviceName)」已启用，流量会走模块"
                : (facts.serviceName.isEmpty
                    ? "macOS 还没为该网卡建立服务"
                    : "「\(facts.serviceName)」未启用，流量仍走 Wi-Fi"),
            fix: facts.serviceEnabled ? nil : "dji4gctl net-enable",
            blocks: [.internet]))

        return checks
    }

    /// A goal is reachable when nothing that stands in its way is still open.
    public static func isReady(_ goal: Capability, in checks: [DoctorCheck]) -> Bool {
        !checks.contains { $0.blocks.contains(goal) && $0.state.blocks }
    }

    /// The fixes worth running, in report order, without repeats.
    public static func pendingFixes(_ checks: [DoctorCheck]) -> [String] {
        var seen = Set<String>()
        return checks.compactMap { $0.state.blocks ? $0.fix : nil }
            .filter { seen.insert($0).inserted }
    }

    /// 卡还没插的时候，报告末尾那一句。
    ///
    /// 没插卡不是死路，但报告把它排成一条待办，其余全是「卡的后果」——客户
    /// 就只能干等卡到。事实上模块声卡、USB 网络模式、APN 都不需要卡，而且
    /// 越早做完越好：前两项写完要重启模块，卡没插的时候重启不会打断任何东
    /// 西。这句话就是把顺序讲出来，免得客户拿着模块白等几天。
    public static func noCardNote(_ facts: DoctorFacts) -> String? {
        guard !facts.simReady else { return nil }
        return "注：卡还没插。上面除「插卡」以外的步骤都不需要卡，可以先做完；"
            + "模块声卡和网络模式写完会重启模块，趁现在做，等卡到了就不会把刚上线的网络打断。"
    }
}
