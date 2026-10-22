import Foundation
import CUSBAT

/// Which of the module's functions an interface carries.
///
/// Every interface on this module reports a vendor-specific class (0xFF), so the
/// class byte alone cannot tell them apart. The function is instead implied by
/// the order the firmware lays the vendor-specific interfaces out in, which is
/// the same assumption the AT channel selection relies on. Audio and network
/// interfaces are recognised by their real class bytes, so they keep working
/// when `usbcfg` is changed and the numbering shifts.
public enum USBInterfaceRole {
    case diag
    case nmea
    case at
    case modem
    case audio
    case network
    case unknown

    public var label: String {
        switch self {
        case .diag: return "诊断"
        case .nmea: return "GPS 定位"
        case .at: return "AT 命令"
        case .modem: return "数据 / PPP"
        case .audio: return "模块声卡"
        case .network: return "USB 网卡"
        case .unknown: return "未知"
        }
    }
}

public struct USBInterfaceInfo {
    public let number: Int
    public let interfaceClass: UInt8
    public let subClass: UInt8
    public let protocolNumber: UInt8
    public let endpointCount: Int
    /// `UsbExclusiveOwner`, empty while nothing holds this interface.
    public let owner: String
    public let role: USBInterfaceRole

    /// 真机上这份信息只能从 IORegistry 读；留一个公开的构造器，是为了让自检
    /// 能摆出「一模一样的现场」再验一遍报错文案 —— 报错文案里最要紧的那几种
    /// （AT 口被另一个自己抓着、被苹果驱动占着）都不能指望下次还碰得上。
    public init(number: Int, interfaceClass: UInt8, subClass: UInt8,
                protocolNumber: UInt8, endpointCount: Int,
                owner: String, role: USBInterfaceRole) {
        self.number = number
        self.interfaceClass = interfaceClass
        self.subClass = subClass
        self.protocolNumber = protocolNumber
        self.endpointCount = endpointCount
        self.owner = owner
        self.role = role
    }

    public var isHeld: Bool { !owner.isEmpty }

    public var classTriplet: String {
        String(format: "0x%02X/0x%02X/0x%02X", interfaceClass, subClass, protocolNumber)
    }
}

/// A read-only view of everything the module exposes on the USB bus.
///
/// Built entirely from IORegistry properties, so it needs no `IOServiceOpen`
/// and keeps working while another process - typically the menu bar app - holds
/// the module exclusively. That makes it the only diagnostic available in the
/// exact state where every AT command is already doomed to fail.
public struct USBInventory {
    public let identity: USBModuleIdentity
    public let interfaces: [USBInterfaceInfo]
    /// Process holding the device node itself, when one is recorded.
    public let deviceOwner: String

    /// 同 `USBInterfaceInfo.init`：给自检摆现场用，真机上请走 `read(_:)`。
    public init(identity: USBModuleIdentity, interfaces: [USBInterfaceInfo], deviceOwner: String) {
        self.identity = identity
        self.interfaces = interfaces
        self.deviceOwner = deviceOwner
    }

    public var atInterface: USBInterfaceInfo? { interfaces.first { $0.role == .at } }
    public var hasAudioFunction: Bool { interfaces.contains { $0.role == .audio } }
    public var hasNetworkFunction: Bool { interfaces.contains { $0.role == .network } }

    /// Every distinct holder named on the device or any interface.
    public var holders: [String] {
        var seen: [String] = []
        for candidate in ([deviceOwner] + interfaces.map(\.owner)) where !candidate.isEmpty {
            if !seen.contains(candidate) {
                seen.append(candidate)
            }
        }
        return seen
    }

    /// Nil when no module of this identity is attached.
    public static func read(_ identity: USBModuleIdentity) -> USBInventory? {
        var raw = [cusbat_interface_view](repeating: cusbat_interface_view(), count: 32)
        let count = Int(cusbat_interfaces(identity.vendorID, identity.productID, &raw, 32))
        guard count > 0 else { return nil }

        var vendorSpecificOrdinal = 0
        var interfaces: [USBInterfaceInfo] = []
        for index in 0..<count {
            let view = raw[index]
            let role: USBInterfaceRole
            if view.interfaceClass == 0x01 {
                role = .audio
            } else if view.interfaceClass == 0x02 || view.interfaceClass == 0x0A {
                role = .network
            } else {
                role = vendorSpecificRole(ordinal: vendorSpecificOrdinal)
                vendorSpecificOrdinal += 1
            }
            interfaces.append(USBInterfaceInfo(number: Int(view.interfaceNumber),
                                               interfaceClass: view.interfaceClass,
                                               subClass: view.interfaceSubClass,
                                               protocolNumber: view.interfaceProtocol,
                                               endpointCount: Int(view.endpointCount),
                                               owner: ownerString(view),
                                               role: role))
        }

        var deviceOwnerBuffer = [CChar](repeating: 0, count: 96)
        let hasDeviceOwner = cusbat_exclusive_owner(identity.vendorID, identity.productID, -1,
                                                    &deviceOwnerBuffer, 96) > 0
        return USBInventory(identity: identity,
                            interfaces: interfaces,
                            deviceOwner: hasDeviceOwner ? text(deviceOwnerBuffer) : "")
    }

    /// Every attached module, in the order the identities are declared.
    public static func readAll() -> [USBInventory] {
        USBModuleIdentity.attached().compactMap { read($0) }
    }

    private static func vendorSpecificRole(ordinal: Int) -> USBInterfaceRole {
        switch ordinal {
        case 0: return .diag
        case 1: return .nmea
        case 2: return .at
        case 3: return .modem
        default: return .unknown
        }
    }

    private static func ownerString(_ view: cusbat_interface_view) -> String {
        var copy = view
        return withUnsafePointer(to: &copy.owner) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 96) { characters in
                String(cString: characters)
            }
        }
    }

    private static func text(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
