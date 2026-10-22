import Foundation

/// 卡的归属地区。由 MCC（IMSI 前三位 / MCC+MNC 前三位）推出，和「当前驻留
/// 网络」是两回事 —— 香港卡在大陆漫游时，归属地区仍是香港。
public enum CarrierRegion: String, Equatable {
    case mainlandChina = "中国大陆"
    case hongKong = "中国香港"
    case macau = "中国澳门"
    case other = "其他地区"
    case unknown = "未知"
}

/// MCC/MNC → 运营商身份 + 该运营商可用的候选 APN 列表。
///
/// APN 单独放进 `apns`（按优先级排列，首个是首选）：同一家运营商的套餐可能
/// 用不同 APN，写首选失败时按顺序退到下一个候选。`apn` 是首选，给老代码用。
public struct Carrier: Equatable, Hashable {
    public let mccmnc: String
    public let name: String
    public let shortName: String
    public let apns: [String]
    public let region: CarrierRegion

    public init(mccmnc: String, name: String, shortName: String, apns: [String],
                region: CarrierRegion = .unknown) {
        self.mccmnc = mccmnc
        self.name = name
        self.shortName = shortName
        self.apns = apns
        self.region = region
    }

    /// 首选 APN。空串 = 认不出、不写。
    public var apn: String { apns.first ?? "" }

    /// 该 APN 是否命中任一候选（不区分大小写）。
    public func matches(apn candidate: String) -> Bool {
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return apns.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
    }

    public static let unknown = Carrier(mccmnc: "", name: "未知运营商", shortName: "未知",
                                        apns: [], region: .unknown)
}

public enum CarrierCatalog {
    /// Mainland-China operators first (this module ships with a Chinese SIM in
    /// most cases), then a small set of roaming partners seen from the module's
    /// default firmware.
    private static let table: [String: Carrier] = {
        var map: [String: Carrier] = [:]
        func add(_ codes: [String], _ name: String, _ short: String, _ apns: [String]) {
            for code in codes {
                let region = CarrierCatalog.region(forMCC: String(code.prefix(3)))
                map[code] = Carrier(mccmnc: code, name: name, shortName: short,
                                    apns: apns, region: region)
            }
        }
        add(["46000", "46002", "46004", "46007", "46008"], "中国移动", "移动", ["CMNET"])
        add(["46003", "46005", "46011", "46012"], "中国电信", "电信", ["CTNET"])
        add(["46001", "46006", "46009"], "中国联通", "联通", ["3GNET"])
        add(["46015", "46020"], "中国广电", "广电", ["CBNET"])

        // ── 香港（MCC 454）。APN 用各家的官方默认；不同套餐可能不同，只在
        //    自动识别**能确定**归属运营商时才写，绝不覆盖客户手改的 APN。
        //    注意 CMHK 是「中国移动香港」，不是大陆中国移动 —— 以前错配成
        //    CMNET（大陆 APN），香港卡插进去会上不了网。
        add(["45412", "45413"], "中国移动香港 CMHK", "CMHK", ["cmhk"])
        add(["45403", "45404", "45405"], "3香港 3HK", "3HK", ["mobile.lte.three.com.hk"])
        add(["45406", "45415", "45416"], "数码通 SmarTone", "SmarTone",
            ["smartone", "internet"])
        // CSL 与 1010 共用 MCC/MNC 454-00，按套餐可能不同；统一给 CSL 的官方
        // 默认 mobile，1010 作为可选按钮单独列出。
        add(["45400", "45402", "45410", "45418", "45419"], "CSL 香港电讯", "CSL",
            ["mobile", "hkcsl"])
        add(["45500", "45501", "45502", "45503", "45504", "45505"], "CTM 澳门电讯", "CTM", ["ctmnet"])
        add(["46601", "46692", "46693"], "Chunghwa 中华电信", "CHT", ["internet"])
        add(["46697", "46699"], "Taiwan Mobile 台湾大哥大", "TWM", ["internet"])
        add(["46688", "46689"], "FarEasTone 远传", "FET", ["internet"])
        add(["310260", "310200", "310210", "310220", "310230", "310240", "310250", "310270", "310310", "310490"], "T-Mobile US", "T-Mobile", ["fast.t-mobile.com"])
        add(["310410", "310150", "310170", "310380", "310560"], "AT&T", "AT&T", ["nxtgenphone"])
        add(["311480", "310004", "310012", "310013"], "Verizon", "Verizon", ["vzwinternet"])
        add(["26201", "26206", "26278"], "Telekom DE", "T-Mobile DE", ["internet.telekom"])
        add(["26202", "26209", "26242"], "Vodafone DE", "Vodafone", ["web.vodafone.de"])
        add(["26203", "26208", "26223", "26243"], "O2 DE", "O2", ["internet"])
        add(["23410", "23430", "23433"], "EE UK", "EE", ["everytime"])
        add(["23415", "23420", "23430"], "Vodafone UK", "Vodafone", ["internet"])
        add(["23430", "23431"], "EE / Virgin UK", "EE", ["everytime"])
        add(["44010", "44011", "44020"], "NTT docomo", "docomo", ["spmode.ne.jp"])
        add(["44020", "44051", "44053"], "SoftBank JP", "SoftBank", ["plus.4g"])
        add(["45005", "45008", "45000", "45002"], "SKT / KT KR", "KR", ["internet"])
        return map
    }()

    public static func carrier(forMCCMNC code: String?) -> Carrier {
        guard let code, !code.isEmpty else { return .unknown }
        let digits = code.filter { $0.isNumber }
        if let exact = table[digits] { return exact }
        // Fall back to the 5-digit MCC+MNC when the module reports 6 digits.
        if digits.count >= 5, let short = table[String(digits.prefix(5))] { return short }
        return Carrier(mccmnc: digits, name: "运营商 \(digits)", shortName: digits, apns: [],
                       region: region(forMCC: String(digits.prefix(3))))
    }

    /// 从 IMSI 推出**卡的归属运营商**。IMSI = MCC(3) + MNC(2~3) + MSIN，
    /// 所以先按 6 位、再按 5 位在表里找，找不到时退回「只知道地区」。
    ///
    /// 与 `carrier(forMCCMNC:)` 的区别：那条吃的是 `AT+QNWINFO` / `AT+COPS?`
    /// 里的**驻留网络**编号，这条吃的是卡自己身上的 IMSI。香港卡在大陆漫游
    /// 时，两条会给出完全不同的答案 —— APN 必须跟卡走，不跟驻留网络走。
    public static func carrier(forIMSI imsi: String?) -> Carrier {
        guard let imsi, !imsi.isEmpty else { return .unknown }
        let digits = imsi.filter { $0.isNumber }
        guard digits.count >= 5 else { return .unknown }
        for length in [6, 5] where digits.count >= length {
            if let exact = table[String(digits.prefix(length))] { return exact }
        }
        let mcc = String(digits.prefix(3))
        return Carrier(mccmnc: mcc, name: "运营商 \(mcc)", shortName: mcc, apns: [],
                       region: region(forMCC: mcc))
    }

    /// MCC → 归属地区。
    public static func region(forMCC mcc: String?) -> CarrierRegion {
        switch mcc {
        case "460": return .mainlandChina
        case "454": return .hongKong
        case "455": return .macau
        case "466": return .other
        default: return .unknown
        }
    }

    /// The buttons on the settings window, in the order they are drawn.
    ///
    /// They exist because the automatic path needs the module to have *said*
    /// which operator the card belongs to, and that only happens once a card is
    /// in and the module has registered. Someone holding an unregistered card —
    /// or standing at the bench with no card at all — still has to be able to
    /// say "this is a Telecom card" and have CTNET written.
    public static let mainlandChina: [Carrier] = [
        carrier(forMCCMNC: "46000"),
        carrier(forMCCMNC: "46001"),
        carrier(forMCCMNC: "46003"),
        carrier(forMCCMNC: "46015"),
    ]

    /// 香港运营商的按钮顺序。1010 与 CSL 共用 454-00，单独列出来让客户能
    /// 按套餐名选；APN 默认都给 `mobile`（1010 部分套餐是 `hkcsl`，客户可
    /// 在自定义里改）。
    public static let hongKong: [Carrier] = [
        carrier(forMCCMNC: "45412"),
        carrier(forMCCMNC: "45403"),
        carrier(forMCCMNC: "45406"),
        carrier(forMCCMNC: "45400"),
        Carrier(mccmnc: "45400", name: "1010（CSL 旗下）", shortName: "1010",
                apns: ["mobile", "hkcsl"], region: .hongKong),
    ]

    /// Aliases firmware puts in `AT+COPS?`. Matching is substring-based because
    /// the answer arrives decorated ("CHINA MOBILE", "CHN-UNICOM", "CMCC"…).
    private static let nameAliases: [(alias: String, mccmnc: String)] = [
        // 香港的先判，且「中国移动香港 / CMHK」必须排在「中国移动 / CMCC」
        // 前面 —— 后者的名字是前者的子串，顺序反了会把香港卡认成大陆移动。
        ("CHINA MOBILE HONG KONG", "45412"), ("CHINA MOBILE HK", "45412"),
        ("CMHK", "45412"), ("中国移动香港", "45412"),
        ("3 HONG KONG", "45403"), ("HUTCHISON", "45403"), ("3HK", "45403"),
        ("SMARTONE", "45406"), ("SMC", "45406"), ("数码通", "45406"),
        ("PCCW", "45419"), ("HKT", "45419"), ("CSL", "45400"),
        ("1010", "45400"), ("香港电讯", "45400"),
        ("CHINA MOBILE", "46000"), ("CHN-MOBILE", "46000"), ("CMCC", "46000"),
        ("CHINA UNICOM", "46001"), ("CHN-CUGSM", "46001"), ("UNICOM", "46001"),
        ("CHINA TELECOM", "46003"), ("CHN-CT", "46003"),
        ("CHINA BROADNET", "46015"), ("BROADNET", "46015"), ("CBN", "46015"),
        // 有些固件把运营商名写成中文，面板上看到的就是这几个字。
        ("中国移动", "46000"), ("中国联通", "46001"),
        ("中国电信", "46003"), ("中国广电", "46015"),
    ]

    /// Resolves the operator from the *name* in `AT+COPS?`.
    ///
    /// Some firmware answers `+COPS: 0,0,"CHINA MOBILE",7` with no numeric code
    /// at all, and the table above is keyed on the numeric code. Before this,
    /// that answer produced a carrier whose APN was empty — so the one case
    /// that had successfully registered was the case where AUTO did nothing.
    public static func carrier(forOperatorName name: String) -> Carrier? {
        let needle = name.uppercased()
        guard !needle.isEmpty else { return nil }
        for entry in nameAliases where needle.contains(entry.alias) {
            return carrier(forMCCMNC: entry.mccmnc)
        }
        return nil
    }
}

/// Why an APN could not be put in place.
///
/// The operator buttons used to return `nil` into an `if let` and do nothing at
/// all: no write, no message, no way to tell them from an unwired button.
/// Anything that refuses now says which of the two things it is.
public enum APNError: Error, CustomStringConvertible {
    /// No operator from the module, and none chosen by hand either.
    case noOperator
    /// The module answered the write with an error.
    case writeFailed(carrier: String, apn: String, reason: Error)

    public var description: String {
        switch self {
        case .noOperator:
            return "读不到运营商（没插卡，或卡还没注册上网络），也没有指定用哪一家。"
                + "插卡后重试；要现在就用，在「模块设置」里点中国移动 / 中国联通 / 中国电信，"
                + "或在终端跑 dji4gctl apn 移动"
        case .writeFailed(let carrier, let apn, let reason):
            return "往模块里写接入点 \(apn)（\(carrier)）失败：\(reason)"
        }
    }
}

/// Registration state shared by `AT+CREG?`, `AT+CEREG?` and `AT+CGREG?`.
public enum RegistrationState: Equatable {
    case notRegistered
    case registeredHome
    case searching
    case denied
    case registeredRoaming
    case unknown(Int)

    public init(code: Int) {
        switch code {
        case 0: self = .notRegistered
        case 1: self = .registeredHome
        case 2: self = .searching
        case 3: self = .denied
        case 5: self = .registeredRoaming
        default: self = .unknown(code)
        }
    }

    public var isRegistered: Bool {
        self == .registeredHome || self == .registeredRoaming
    }

    public var label: String {
        switch self {
        case .notRegistered: return "未注册"
        case .registeredHome: return "已注册（本地）"
        case .searching: return "搜索中"
        case .denied: return "被拒绝"
        case .registeredRoaming: return "已注册（漫游）"
        case .unknown(let code): return "状态 \(code)"
        }
    }
}

public struct NetworkStatus: Equatable {
    public var registration: RegistrationState = .notRegistered
    public var packetRegistration: RegistrationState = .notRegistered
    public var carrier: Carrier = .unknown
    public var accessTechnology: String = ""
    public var band: String = ""
    public var channel: Int?
    public var rawNetworkInfo: String = ""

    public init() {}

    /// 是否在漫游。数据域和电路域任一报「漫游注册」（`+CREG` / `+CEREG`
    /// 第 2 格 = 5）就算 —— 香港卡在大陆用、大陆卡在境外用都落在这里。
    public var isRoaming: Bool {
        registration == .registeredRoaming || packetRegistration == .registeredRoaming
    }

    /// 卡在境外、但没在网（或只在搜索）时的「可能漫游」提示，给界面解释
    /// 「为什么上不了网」用。
    public var roamingLabel: String {
        isRoaming ? "漫游中" : "本地"
    }

    /// 数据通不通看分组域：`AT+CEREG?`（LTE）/`AT+CGREG?`（GPRS）。
    ///
    /// 在中国大陆的纯 LTE 网络上，电信卡的 `AT+CREG?`（电路域，管打电话
    /// 那一路）回 `0,3`「被拒绝」是常态 —— 电路域是给 2G/3G 语音用的，
    /// 网已经退了。早先这里只看 `registration`，于是插着卡、能上网，界面
    /// 上却写「被拒绝」，客人照着这句话去查天线和卡，而真正该做的是别管它。
    public var dataRegistered: Bool {
        packetRegistration.isRegistered || registration.isRegistered
    }

    /// 界面和报告里该显示的那一个注册状态：分组域通了就以分组域为准，
    /// 两个都没通才轮到电路域那个码说话。
    public var reportedRegistration: RegistrationState {
        if registration.isRegistered { return registration }
        if packetRegistration.isRegistered { return packetRegistration }
        return registration
    }

    /// 电路域没注册、但分组域通了：上网没事，只有「打电话」这一项要另说。
    /// 界面拿它决定要不要多解释一句，而不是把它当成故障报出去。
    public var voiceDomainDenied: Bool {
        dataRegistered && !registration.isRegistered
    }

}

public struct SignalStatus: Equatable {
    /// Raw `AT+CSQ` value, 0…31 with 99 meaning "unknown".
    public var rssiIndex: Int = 99
    public var berIndex: Int = 99
    public var rsrp: Double?
    public var rsrq: Double?
    public var sinr: Double?
    public var rawCSQ: String = ""
    public var rawQCSQ: String = ""
    /// 非 Quectel 模块的原始串，同上：诊断包里要能看见模块到底回了什么。
    /// `+CESQ` 是 3GPP 标准那条，`^HCSQ` 是华为那条。
    public var rawCESQ: String = ""
    public var rawHCSQ: String = ""
    /// Set when the module answered with a direct dBm value (`AT+QCSQ`).
    public var rssiDBmOverride: Int?

    public init() {}

    /// `AT+CSQ` reports an index; EG25-G maps it to dBm as -113 + 2·index.
    public var rssiDBm: Int? {
        if let rssiDBmOverride { return rssiDBmOverride }
        guard rssiIndex != 99, (0...31).contains(rssiIndex) else { return nil }
        return -113 + 2 * rssiIndex
    }

    /// 0…5 bars, derived from whichever measurement is available.
    public var bars: Int {
        if let rsrp {
            switch rsrp {
            case ..<(-120): return 1
            case ..<(-110): return 2
            case ..<(-100): return 3
            case ..<(-90): return 4
            default: return 5
            }
        }
        guard rssiIndex != 99, (0...31).contains(rssiIndex) else { return 0 }
        switch rssiIndex {
        case ..<6: return 1
        case ..<11: return 1
        case ..<16: return 2
        case ..<21: return 3
        case ..<26: return 4
        default: return 5
        }
    }

    public var label: String {
        if let rsrp {
            return String(format: "RSRP %.0f dBm · %d/5", rsrp, bars)
        }
        if let dBm = rssiDBm {
            return "\(dBm) dBm · \(bars)/5"
        }
        return "无信号"
    }
}

/// What the module actually said about the card in the slot.
///
/// The distinction worth keeping is 卡不在 (`.missing`) versus 卡在但还没就绪
/// (`.notReady` / `.busy` / `.pinRequired`). Both leave `ready` false, but only
/// the first one means someone has to open the module, and only the second one
/// is worth waiting for. Collapsing them into one "SIM 未就绪" is what makes a
/// missing card look like a fault.
public enum SIMState: Equatable {
    case unknown
    case missing
    case notReady
    case busy
    case pinRequired
    case pukRequired
    case failure
    case ready
}

public struct SIMStatus: Equatable {
    public var state: SIMState = .unknown
    public var pinRequired: Bool = false
    public var ready: Bool = false
    public var pinState: String = ""
    public var imsi: String = ""
    public var iccid: String = ""
    public var ownNumber: String = ""
    /// 卡的**归属运营商**，从 IMSI 推出。与 `NetworkStatus.carrier`（当前驻留
    /// 网络）是两回事 —— 漫游时归属不变、驻留会变。
    public var homeCarrier: Carrier = .unknown
    public var rawResponse: String = ""
    /// `AT+QSIMSTAT?` 的卡座检测位：插槽里到底有没有卡。nil ＝ 模块没回答。
    public var detectedInserted: Bool?

    public init() {}

    /// 面板上一行放得下的短标签。
    public var shortLabel: String {
        switch state {
        case .ready: return "就绪"
        case .missing: return "未插卡"
        case .failure: return "读卡失败"
        case .busy: return "初始化中"
        case .pinRequired: return "需要 PIN"
        case .pukRequired: return "需要 PUK"
        case .notReady: return "未就绪"
        case .unknown: return pinState.isEmpty ? "未知" : pinState
        }
    }

    public var label: String {
        switch state {
        case .ready: return "SIM 就绪"
        case .missing:
            return detectedInserted == false
                ? "未检测到 SIM 卡（卡座检测：没有卡）"
                : "未检测到 SIM 卡"
        case .failure: return "SIM 卡读取失败"
        case .busy: return "SIM 卡忙（模块正在读卡）"
        case .pinRequired: return "SIM 卡带 PIN 锁，需要先解锁"
        case .pukRequired: return "SIM 卡被 PUK 锁住"
        case .notReady:
            return pinState.isEmpty ? "SIM 卡未就绪" : "SIM 卡未就绪（\(pinState)）"
        case .unknown:
            return pinState.isEmpty ? "SIM 状态未知" : pinState
        }
    }

    /// 现在该做什么。空字符串 ＝ 不需要动作。
    public var guidance: String {
        switch state {
        case .ready: return ""
        case .missing:
            // 「卡座里没有卡」和「卡在卡座里但读不到」要做的事不一样：前者是
            // 把卡拿来插上（客户的卡常常还没到），后者才是拔出来重插。卡座
            // 检测读不到（nil）时按后者说 —— 那时模块自己也不知道卡在不在，
            // 让客户拔出来重插一次，比让他对着一个空卡座拆卡托强。
            return detectedInserted == false
                ? "卡座里现在是空的：把 SIM 卡装进卡托、按到底，再插回模块"
                : "取出卡托，把卡按到底再插回；插好了仍显示未插卡，就把卡先插到手机上确认卡是好的"
        case .failure: return "重新插一次；换一张卡能读到，就是卡的问题"
        case .busy: return "等几秒刷新，模块读卡通常一秒内完成"
        case .pinRequired: return "先在手机上关掉这张卡的 PIN 锁"
        case .pukRequired: return "用手机解开 PUK（PUK 连错十次会废卡）"
        case .notReady: return "稍后重试；一直这样说明卡没插到位"
        case .unknown: return "模块没有报告卡的状态，检查卡座排线"
        }
    }

    /// 为什么现在用不了这张卡 —— 直接拼进报错里，省得再解释一遍。
    public var unavailableReason: String {
        guidance.isEmpty ? label : "\(label)。\(guidance)"
    }
}

public struct ModuleIdentity: Equatable {
    public var model: String = ""
    public var revision: String = ""
    public var imei: String = ""
    public var firmwareBuild: String = ""
    public var temperatures: [String] = []
    public var rawATI: String = ""

    public init() {}

    public var displayName: String {
        model.isEmpty ? "DJI 4G 模块" : model
    }
}
