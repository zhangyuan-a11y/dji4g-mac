import Foundation
import CUSBAT
#if canImport(Darwin)
import Darwin
#endif

public enum ATTransportError: Error, CustomStringConvertible {
    case deviceNotFound(String)
    case noATInterface(String)
    case openFailed(String)
    case ioFailed(String)
    case timeout
    case closed

    public var description: String {
        switch self {
        case .deviceNotFound(let detail): return "未找到模块：\(detail)"
        case .noATInterface(let detail): return "没有可用的 AT 接口：\(detail)"
        case .openFailed(let detail): return "打开失败：\(detail)"
        case .ioFailed(let detail): return "通信失败：\(detail)"
        case .timeout: return "等待模块响应超时"
        case .closed: return "通道已关闭"
        }
    }
}

/// A byte pipe that can carry AT commands. The module offers one over the raw
/// USB bulk endpoints (no kernel driver required) and, once flashed with stock
/// Quectel firmware, a second one through a CDC-ACM serial device.
public protocol ATTransport: AnyObject {
    var isOpen: Bool { get }
    var describe: String { get }
    func open() throws
    func close()
    func write(_ bytes: [UInt8]) throws
    /// Returns the bytes that arrived, or throws `.timeout` when none did.
    func read(maxLength: Int, timeoutMs: Int) throws -> [UInt8]
}

public struct USBModuleIdentity: Hashable, Sendable {
    public let vendorID: Int32
    public let productID: Int32
    public let label: String

    public init(vendorID: Int32, productID: Int32, label: String) {
        self.vendorID = vendorID
        self.productID = productID
        self.label = label
    }

    public var hex: String { String(format: "%04X:%04X", vendorID, productID) }

    /// The first-generation DJI module keeps its DJI identity unless the USB
    /// composition was rewritten; a module flashed with stock Quectel firmware
    /// enumerates as the Quectel identity instead. Both layouts carry the same
    /// AT channel, so both are accepted.
    public static let dji = USBModuleIdentity(vendorID: 0x2CA3, productID: 0x4006, label: "DJI/QDC507")
    public static let quectel = USBModuleIdentity(vendorID: 0x2C7C, productID: 0x0125, label: "Quectel/EG25-G")

    public static let supported: [USBModuleIdentity] = [.dji, .quectel]

    // MARK: - 认模块（按厂家，不按型号）
    //
    // 2026-09-27：以前这里只写着两块模块 —— DJI 的 QDC507 和 Quectel 的
    // EG25-G（`2c7c:0125`）。同一颗 Quectel 芯片换一套出厂 USB 身份就是另一个
    // 产品号，EC20 / EC21 / EC25 / EG600 全都被这套判断挡在门外，客户拿着的
    // 明明是一块能用的模块，程序却说没有模块。
    //
    // 现在按**厂家**认：Quectel 的 USB 厂家号就是一个 `0x2C7C`，Linux 上那个
    // 同类工具（VoCat）也是这么认的。型号不写死在这儿，模块自己会用 `ATI`
    // 报出来（面板上「型号」那一格本来就是这么来的）。多认一家不等于多猜：
    // 找到的每一个身份都要在 AT 口上答一句 `AT` 才算数（`cusbat_open_auto`）。
    /// 认得的厂家。
    ///
    /// 表不写在这儿了 —— 单一来源在 `VendorDetector.vendors`，那边同时还记着
    /// 每一家属于哪个命令家族（`ModemFamily`）。「支持哪些模块」这个问题，
    /// 全套代码里只该有一个答案，多一处副本就多一处会漏改的地方。
    public static var vendors: [(id: Int32, name: String)] {
        VendorDetector.vendors.map { (id: $0.id, name: $0.name) }
    }

    /// 见过的产品号对应哪几块模块。只喂给命令行和诊断（`dji4gctl usb`、
    /// 诊断包），面板上出现的是模块自己报的型号 —— 客户看到的那一格永远是
    /// 手上那块模块的原话，而不是我们猜的名字。
    private static let productNames: [Int32: String] = [
        0x4006: "DJI QDC507",
        0x0125: "EC20 / EC25 / EG25 一族",
        0x0121: "EC21",
        0x0306: "EP06 / EG06",
        0x0296: "BG95 / BG96",
        0x0800: "RM500Q",
    ]

    /// 现在插在 USB 上的模块，已知的两块排在前面。
    ///
    /// 扫的是厂家，不是型号：同一家下面没见过的产品号也收进来，只要它在 AT
    /// 口上答得上话就一样能用。认不出来时返回空数组 —— 那时候正确答案是
    /// 「没有模块」，不是猜一个。
    public static func attached() -> [USBModuleIdentity] {
        var found: [USBModuleIdentity] = []
        for vendor in vendors {
            var raw = [Int32](repeating: 0, count: 16)
            let count = Int(cusbat_products(vendor.id, &raw, 16))
            guard count > 0 else { continue }
            for index in 0..<min(count, raw.count) {
                let identity = USBModuleIdentity(vendorID: vendor.id,
                                                 productID: raw[index],
                                                 label: label(for: vendor, product: raw[index]))
                if !found.contains(identity) { found.append(identity) }
            }
        }
        // 先摆被人肉验过的那两块，其余按扫到的顺序跟在后面。
        return supported.filter { found.contains($0) } + found.filter { !supported.contains($0) }
    }

    private static func label(for vendor: (id: Int32, name: String), product: Int32) -> String {
        // 产品号要和厂家号对得上才算数：`0x4006` 挂在大疆下面才是 QDC507，
        // 挂在别家下面就是别的模块，不能拿大疆的名字套上去。
        if vendor.id == dji.vendorID, product == dji.productID { return dji.label }
        if vendor.id == quectel.vendorID, product == quectel.productID { return quectel.label }
        if let name = productNames[product] { return "\(vendor.name) \(name)" }
        return "\(vendor.name) 模块（\(String(format: "%04X", product))）"
    }
}

public struct USBInterfaceCandidate {
    public let interfaceNumber: Int
    public let endpointIn: UInt8
    public let endpointOut: UInt8
    public let interfaceClass: UInt8
    public let interfaceSubClass: UInt8
    public let alternateSetting: UInt8
}

public final class USBATTransport: ATTransport {
    public private(set) var handle: UnsafeMutableRawPointer?
    public private(set) var identity: USBModuleIdentity
    public private(set) var candidate: USBInterfaceCandidate?

    private let preferredIdentity: USBModuleIdentity?

    public init(identity: USBModuleIdentity? = nil) {
        self.preferredIdentity = identity
        self.identity = identity ?? .dji
    }

    public var isOpen: Bool { handle != nil }

    public var describe: String {
        if let candidate {
            return String(format: "%@ 接口 %d（out 0x%02X / in 0x%02X）",
                          identity.label, candidate.interfaceNumber,
                          candidate.endpointOut, candidate.endpointIn)
        }
        return identity.label
    }

    /// Attached modules matching any supported identity, most specific first.
    public static func attachedIdentities() -> [USBModuleIdentity] {
        USBModuleIdentity.attached()
    }

    public static func candidates(for identity: USBModuleIdentity) -> [USBInterfaceCandidate] {
        var raw = [cusbat_candidate](repeating: cusbat_candidate(), count: 24)
        let count = Int(cusbat_candidates(identity.vendorID, identity.productID, &raw, 24))
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            USBInterfaceCandidate(interfaceNumber: Int(raw[index].interfaceNumber),
                                  endpointIn: raw[index].endpointIn,
                                  endpointOut: raw[index].endpointOut,
                                  interfaceClass: raw[index].interfaceClass,
                                  interfaceSubClass: raw[index].interfaceSubClass,
                                  alternateSetting: raw[index].alternateSetting)
        }
    }

    public func open() throws {
        close()

        var order: [USBModuleIdentity] = []
        if let preferredIdentity {
            order.append(preferredIdentity)
        }
        for candidateIdentity in USBModuleIdentity.attached() where !order.contains(candidateIdentity) {
            order.append(candidateIdentity)
        }

        var lastError = "没有连接的模块"
        for candidateIdentity in order {
            guard cusbat_present(candidateIdentity.vendorID, candidateIdentity.productID) > 0 else { continue }
            var info = cusbat_open_info()
            var errorBuffer = [CChar](repeating: 0, count: 256)
            let opened = cusbat_open_auto(candidateIdentity.vendorID, candidateIdentity.productID,
                                          &info, &errorBuffer, 256)
            guard let opened else {
                lastError = Self.text(errorBuffer)
                continue
            }
            handle = opened
            identity = candidateIdentity
            candidate = USBInterfaceCandidate(interfaceNumber: Int(info.interfaceNumber),
                                              endpointIn: info.endpointIn,
                                              endpointOut: info.endpointOut,
                                              interfaceClass: 0,
                                              interfaceSubClass: 0,
                                              alternateSetting: 0)
            return
        }

        if USBModuleIdentity.attached().isEmpty {
            // 报厂家，不报产品号：每个型号一串十六进制对客户没有任何用处，
            // 他要做的是把模块插好；而对得上号的排障信息在诊断包里。
            let names = USBModuleIdentity.vendors.map(\.name).joined(separator: " / ")
            throw ATTransportError.deviceNotFound("没有检测到模块（\(names)）")
        }
        throw ATTransportError.noATInterface(lastError)
    }

    public func close() {
        if let handle {
            cusbat_close(handle)
        }
        handle = nil
        candidate = nil
    }

    public func write(_ bytes: [UInt8]) throws {
        guard let handle else { throw ATTransportError.closed }
        let result = cusbat_write(handle, bytes, Int32(bytes.count), 1500)
        guard result == CUSBAT_OK else {
            throw ATTransportError.ioFailed(Self.lastError(handle) ?? "写入返回 \(result)")
        }
    }

    public func read(maxLength: Int = 4096, timeoutMs: Int = 500) throws -> [UInt8] {
        guard let handle else { throw ATTransportError.closed }
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let result = cusbat_read(handle, &buffer, Int32(maxLength), Int32(timeoutMs))
        if result == CUSBAT_ERR_TIMEOUT { throw ATTransportError.timeout }
        guard result >= 0 else {
            throw ATTransportError.ioFailed(Self.lastError(handle) ?? "读取返回 \(result)")
        }
        return Array(buffer[0..<Int(result)])
    }

    private static func lastError(_ handle: UnsafeMutableRawPointer) -> String? {
        guard let pointer = cusbat_last_error(handle) else { return nil }
        let text = String(cString: pointer)
        return text.isEmpty ? nil : text
    }

    static func text(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// CDC-ACM path. Stock Quectel firmware exposes `/dev/cu.usbmodem*`, which is
/// handy when the USB composition has been rewritten.
public final class SerialATTransport: ATTransport {
    public let path: String
    private var descriptor: Int32 = -1

    public init(path: String) {
        self.path = path
    }

    public var isOpen: Bool { descriptor >= 0 }
    public var describe: String { path }

    public func open() throws {
        close()
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw ATTransportError.openFailed("无法打开 \(path)：\(String(cString: strerror(errno)))")
        }
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else {
            Darwin.close(fd)
            throw ATTransportError.openFailed("无法读取 \(path) 的串口属性")
        }
        cfmakeraw(&options)
        cfsetspeed(&options, speed_t(B115200))
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CRTSCTS)
        options.c_cc.16 = 0
        options.c_cc.17 = 1
        guard tcsetattr(fd, TCSANOW, &options) == 0 else {
            Darwin.close(fd)
            throw ATTransportError.openFailed("无法配置 \(path)")
        }
        descriptor = fd
    }

    public func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    public func write(_ bytes: [UInt8]) throws {
        guard descriptor >= 0 else { throw ATTransportError.closed }
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { pointer -> Int in
                guard let base = pointer.baseAddress else { return 0 }
                return Darwin.write(descriptor, base, pointer.count)
            }
            if written <= 0 {
                if errno == EAGAIN { continue }
                throw ATTransportError.ioFailed("写入 \(path) 失败：\(String(cString: strerror(errno)))")
            }
            offset += written
        }
    }

    public func read(maxLength: Int = 4096, timeoutMs: Int = 500) throws -> [UInt8] {
        guard descriptor >= 0 else { throw ATTransportError.closed }
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pollDescriptor, 1, Int32(timeoutMs))
        if ready == 0 { throw ATTransportError.timeout }
        if ready < 0 {
            if errno == EINTR { throw ATTransportError.timeout }
            throw ATTransportError.ioFailed("轮询 \(path) 失败：\(String(cString: strerror(errno)))")
        }
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let bytesRead = Darwin.read(descriptor, &buffer, maxLength)
        if bytesRead <= 0 { throw ATTransportError.timeout }
        return Array(buffer[0..<bytesRead])
    }
}
