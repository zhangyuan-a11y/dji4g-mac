import Foundation

/// 模块的「家族」——同一族的模块用同一套 AT 命令。
///
/// 为什么要单开这一层：这个 App 是照着一块 Quectel EG25-G（大疆一代模块就是它
/// 的贴牌）写出来的，`AT+QCSQ` / `AT+QTEMP` / `AT+QNWINFO` / `AT+QENG` 全是
/// Quectel 自己的命令。同一颗芯片换一套出厂身份就是另一个产品号，换一家厂
/// （华为、芯讯、Sierra……）连命令集都不一样 —— 模块认出来了，信号、温度、
/// 频段却读不出来，面板上是一排 `--`，客户拿到手只会说「这软件坏了」。
///
/// 这一层把「这条信息该问哪条命令」摊成一张表：每一族一串候选命令，**按序试，
/// 第一个答得上话的算数**。顺序永远从「说得最细」排到「最通用」—— 排在最后的
/// 一定是 3GPP 标准命令，任何一块正经模块都得答。
public enum ModemFamily: String, Sendable, CaseIterable {
    case quectel
    case huawei
    case simcom
    case generic
}

/// 一族模块的命令表。
public struct VendorProfile: Sendable {
    public let family: ModemFamily
    /// 给客户看的一行字（诊断包里用）。
    public let displayName: String

    /// 信号质量。按序试，先补出 RSSI，再补出 RSRP/RSRQ/SINR。
    public let signalCommands: [String]
    /// 模块温度。
    public let temperatureCommands: [String]
    /// 制式 / 频段 / 频点 —— 比注册状态里那一个 `AcT` 码更细的一层。
    public let networkInfoCommands: [String]
    /// 读上网模式（USB 网卡那一路的组态）。
    public let usbNetModeRead: String?
    /// 写上网模式，`%d` 是模式号。
    public let usbNetModeWrite: String?
    /// 数据用量计数器。
    public let dataCounterCommand: String?

    /// 手动选网时能不能带制式那一位。3GPP 的标准写法是
    /// `AT+COPS=1,2,"<mccmnc>",<act>`，但华为那几家固件只吃三个参数，
    /// 多给一位就回 `ERROR`。写法本身两边都通用，差别只在**先说哪一种** ——
    /// `ModemController.selectOperator` 会按这一位决定先试哪条，第一条没成
    /// 再换另一条。
    public let networkSelectAcceptsAct: Bool

    /// 这一族能不能切上网模式。不能切的时候界面不该给按钮 —— 给了按下去
    /// 只会回一句 `ERROR`，客户以为是自己按错了。
    public var canSwitchUsbNet: Bool { usbNetModeRead != nil && usbNetModeWrite != nil }

    public init(family: ModemFamily,
                displayName: String,
                signalCommands: [String],
                temperatureCommands: [String],
                networkInfoCommands: [String],
                usbNetModeRead: String? = nil,
                usbNetModeWrite: String? = nil,
                dataCounterCommand: String? = nil,
                networkSelectAcceptsAct: Bool = true) {
        self.family = family
        self.displayName = displayName
        self.signalCommands = signalCommands
        self.temperatureCommands = temperatureCommands
        self.networkInfoCommands = networkInfoCommands
        self.usbNetModeRead = usbNetModeRead
        self.usbNetModeWrite = usbNetModeWrite
        self.dataCounterCommand = dataCounterCommand
        self.networkSelectAcceptsAct = networkSelectAcceptsAct
    }
}

public enum VendorCatalog {
    /// 移远（Quectel）。大疆一代模块是它的贴牌，命令集一模一样。
    public static let quectel = VendorProfile(
        family: .quectel,
        displayName: "Quectel",
        signalCommands: ["AT+QCSQ", "AT+QENG=\"servingcell\"", "AT+CESQ", "AT+CSQ"],
        temperatureCommands: ["AT+QTEMP"],
        networkInfoCommands: ["AT+QNWINFO", "AT+QENG=\"servingcell\""],
        usbNetModeRead: "AT+QCFG=\"usbnet\"",
        usbNetModeWrite: "AT+QCFG=\"usbnet\",%d",
        dataCounterCommand: "AT+QGDCNT?")

    /// 华为。信号只有 `AT^HCSQ`，制式靠 `AT^SYSINFOEX`，温度 `AT^CHIPTEMP?`。
    /// 它没有一条「切上网模式」的等价命令（拨号走 `AT^NDISDUP`），所以那两格
    /// 留空 —— 界面据此把切换按钮收起来，而不是让客户按出一个 `ERROR`。
    public static let huawei = VendorProfile(
        family: .huawei,
        displayName: "Huawei",
        signalCommands: ["AT^HCSQ?", "AT^HCSQ=\"LTE\"", "AT+CESQ", "AT+CSQ"],
        temperatureCommands: ["AT^CHIPTEMP?", "AT^TEMP?"],
        networkInfoCommands: ["AT^SYSINFOEX", "AT^HCSQ?"],
        networkSelectAcceptsAct: false)

    /// 芯讯（SIMCom）。`AT+CPSI?` 带制式、频段、频点；信号走标准的 `AT+CESQ`。
    public static let simcom = VendorProfile(
        family: .simcom,
        displayName: "SIMCom",
        signalCommands: ["AT+CPSI?", "AT+CESQ", "AT+CSQ"],
        temperatureCommands: ["AT+CPMUTEMP"],
        networkInfoCommands: ["AT+CPSI?"])

    /// 认不出厂家时的那一档。只发 3GPP 标准命令 —— 正经模块都得答，
    /// 答不上来的就老老实实留 `--`，不猜。
    public static let generic = VendorProfile(
        family: .generic,
        displayName: "通用 3GPP",
        signalCommands: ["AT+CESQ", "AT+CSQ"],
        temperatureCommands: [],
        networkInfoCommands: [])

    public static func profile(for family: ModemFamily) -> VendorProfile {
        switch family {
        case .quectel: return quectel
        case .huawei: return huawei
        case .simcom: return simcom
        case .generic: return generic
        }
    }
}

/// 怎么认出是哪一家。
///
/// 两条线索，先看 USB 厂家号，再看 `ATI` 回的那几行字。USB 厂家号更硬 ——
/// 那是设备自己在 USB 描述符里报的，模块改不了；`ATI` 是固件自己写的字符串，
/// 贴牌厂会改成自己的名字（大疆一代模块回的就是 `Baiwang` / `QDC507`）。
public enum VendorDetector {
    /// 认识的模块厂家。
    ///
    /// 为什么是这些：全是**专门做蜂窝模块**的厂家号。这里刻意**不收**
    /// `0x05C6`（高通那个通用号）—— 手机插上充电时也挂在这个号下面，
    /// 收进来会让程序把客人的手机当成模块，轻则误报「模块已连接」，
    /// 重则去开它的接口。少认一个号，换的是不会认错东西。
    public static let vendors: [(id: Int32, family: ModemFamily, name: String)] = [
        (0x2CA3, .quectel, "DJI"),        // 大疆一代（Quectel EG25-G 贴牌）
        (0x2C7C, .quectel, "Quectel"),
        (0x12D1, .huawei, "Huawei"),
        (0x1E0E, .simcom, "SIMCom"),
        (0x1199, .generic, "Sierra Wireless"),
        (0x1BC7, .generic, "Telit"),
        (0x2CB7, .generic, "Fibocom"),
        (0x1546, .generic, "u-blox"),
        (0x19D2, .generic, "ZTE"),
        (0x1E2D, .generic, "Thales"),
        (0x2DE2, .generic, "Meig"),
    ]

    public static func family(forVendorID id: Int32) -> ModemFamily? {
        vendors.first { $0.id == id }?.family
    }

    /// `ATI` 里能认出来的关键词。放在这里而不是散在解析器里，是为了让
    /// 「支持哪些厂家」永远只有一处答案。
    static let atiHints: [(needle: String, family: ModemFamily)] = [
        ("QUECTEL", .quectel),
        ("QDC", .quectel),
        ("BAIWANG", .quectel),
        ("HUAWEI", .huawei),
        ("SIMCOM", .simcom),
        ("SIM7", .simcom),
        ("SIM8", .simcom),
        ("SIM9", .simcom),
        ("A7670", .simcom),
        ("A7600", .simcom),
        // 型号名也是一条线索：贴牌厂会把 `Quectel` 三个字从 ATI 里抹掉，型号
        // 却常常留着（`EG25-G` / `EC25-A` / `BG96`）。这几串都是移远的型号，
        // 别家不用这一套命名。
        ("EG25", .quectel),
        ("EG21", .quectel),
        ("EG06", .quectel),
        ("EC25", .quectel),
        ("EC21", .quectel),
        ("EC20", .quectel),
        ("EP06", .quectel),
        ("BG95", .quectel),
        ("BG96", .quectel),
        ("RM500", .quectel),
        ("RM520", .quectel),
    ]

    /// 认家族。USB 厂家号说了算；它说不出来（或者报了个我们没见过的号）时
    /// 才去看 `ATI` 的字。两边都认不出来就是 `generic` —— 那是**能用**的一档，
    /// 不是失败：标准命令照样把信号、注册、短信、通话跑通。
    public static func detect(vendorID: Int32?, atiText: String) -> ModemFamily {
        if let vendorID, let family = family(forVendorID: vendorID) { return family }
        let upper = atiText.uppercased()
        for hint in atiHints where upper.contains(hint.needle) { return hint.family }
        return .generic
    }
}
