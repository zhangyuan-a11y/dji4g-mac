import Foundation
import CMacNet

public enum USBnetMode: Int, CaseIterable {
    case rndis = 0
    case ecm = 1
    case mbim = 2
    case qmi = 3

    /// 客户看到的名字。只说这一档是给什么设备用的 —— 协议名（ECM / RNDIS）
    /// 客户既认不出也帮不上忙，看懂「是不是给我这台电脑用的」就够了。
    public var label: String {
        switch self {
        case .rndis: return "Windows 电脑"
        case .ecm: return "这台 Mac（推荐）"
        case .mbim: return "特殊用途（MBIM）"
        case .qmi: return "特殊用途（QMI）"
        }
    }

    /// 协议本名。只给命令行、诊断信息和控制台用，不进面板。
    public var technicalName: String {
        switch self {
        case .rndis: return "RNDIS"
        case .ecm: return "ECM"
        case .mbim: return "MBIM"
        case .qmi: return "QMI"
        }
    }

    /// macOS ships a CDC-ECM driver and no RNDIS driver, so ECM is the only
    /// composition that yields an interface without extra kexts.
    public var worksOnMac: Bool { self == .ecm }

    public var note: String {
        switch self {
        case .rndis: return "Windows 电脑用的模式。Mac 认不出这块网卡，选它上不了网。"
        case .ecm: return "这台电脑用的模式，一般不用改；改了模块会重启一次。"
        case .mbim: return "特殊用途，Mac 上一般用不了。"
        case .qmi: return "特殊用途，Mac 上一般用不了。"
        }
    }
}

/// Where the byte totals on the panel come from.
public enum DataCounterSource: String, Equatable {
    /// macOS's counters for the BSD interface it created for the module.
    case host
    /// The module's own totals (`AT+QGDCNT?`). Used when macOS has not
    /// attached a driver to the ECM interface, so there is nothing to count on
    /// the host side — the module still knows how much went through it.
    case module
}

public struct DataStatus: Equatable {
    public var usbnetMode: USBnetMode?
    public var composition: USBComposition?
    public var interfaceName: String = ""
    public var ipv4Address: String = ""
    public var bytesIn: UInt64 = 0
    public var bytesOut: UInt64 = 0
    public var apn: String = ""
    public var pdpActive: Bool = false
    public var counterSource: DataCounterSource = .host
    /// Name of the macOS network service bound to `interfaceName`, e.g.
    /// "Baiwang". Empty before macOS finishes creating it.
    public var serviceName: String = ""
    /// Whether that service is switched on. macOS leaves it off by default so
    /// cellular can never silently take the default route from Wi-Fi.
    public var serviceEnabled: Bool = false
    /// 模块的网卡已经在系统里出现了，但 macOS 一直没给它起名字。
    ///
    /// 这不是「模块没插」也不是「模块没注册」—— 这两种 `interfaceName` 也会是
    /// 空的，但系统里根本没有那块网卡。这一种是网卡**在**、名字**没有**，起因
    /// 是插模块的时候控制台锁着（见 `cmacnet_usb_ethernet_unnamed`）。客户能
    /// 看见的差别是：前者等一等会自己好，这一种等多久都不会好。
    public var interfaceStranded: Bool = false

    public init() {}

    /// The link is up: macOS built an interface for the module and DHCP gave
    /// it an address. This does **not** mean traffic flows — see `isRoutable`.
    public var isConnected: Bool { !ipv4Address.isEmpty }

    public var hasInterface: Bool { !interfaceName.isEmpty }

    /// Traffic can actually leave the machine over the module. macOS keeps the
    /// network service disabled until asked, so a link can be fully up and
    /// still route nothing; that is the single most confusing state here and
    /// the reason it gets its own flag.
    public var isRoutable: Bool { isConnected && serviceEnabled }

    public var serviceLabel: String {
        if serviceName.isEmpty { return hasInterface ? "未绑定服务" : "--" }
        return serviceEnabled ? "\(serviceName) 已启用" : "\(serviceName) 未启用"
    }

    public var label: String {
        if isConnected { return "\(interfaceName) · \(ipv4Address)" }
        if !interfaceName.isEmpty { return "\(interfaceName) · 无 IP" }
        return "无网络接口"
    }

    public static func format(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0 ? "\(Int(value)) B" : String(format: "%.2f %@", value, units[index])
    }
}

public enum DataError: Error, CustomStringConvertible {
    case rejected(ATFinal)
    case noInterface(String)
    case invalidParameter(String)

    public var description: String {
        switch self {
        case .rejected(let final): return "模块拒绝操作：\(final.text)"
        case .noInterface(let detail): return detail
        case .invalidParameter(let detail): return detail
        }
    }
}

/// Packet data: APN configuration, PDP activation and the macOS side of the
/// ECM interface.
///
/// The module does the cellular work; macOS sees a plain Ethernet interface and
/// runs DHCP over it. Anything that fails here is almost always either the
/// wrong `usbnet` mode (RNDIS has no macOS driver) or a wrong APN.
public final class DataService {
    private let session: ATSession
    private let identity: () -> USBModuleIdentity

    /// Resolving the service name walks every network service on the machine,
    /// which is far too much work for a 2-second poll, so the name is kept
    /// until the interface changes and only the on/off flag is re-read.
    private struct ServiceCache {
        var device: String
        var name: String
        var enabled: Bool
        var at: Date
    }
    private var serviceCache: ServiceCache?
    private static let serviceCacheLifetime: TimeInterval = 5
    /// Set only by `overrideHostState`. While true the host half of the link
    /// is stated by the caller rather than read from this Mac, which is what
    /// lets the whole app run on a simulated module: without the pin, the very
    /// next poll would find no interface, blank the service name, and make the
    /// panel contradict itself one refresh after it was drawn.
    private var pinnedHostState = false
    /// Set only by `overrideCounters`. Same idea as `pinnedHostState`, for the
    /// two totals printed under the ring: they belong to the caller, not to
    /// this Mac. Without the pin the numbers in a screenshot depend on what is
    /// plugged into the machine rendering it — a module left attached during a
    /// re-render puts its own traffic in the picture, the ring reads 100% left
    /// instead of 43%, and the file no longer matches the one that shipped.
    private var pinnedCounters: (bytesIn: UInt64, bytesOut: UInt64, source: DataCounterSource)?

    public private(set) var status = DataStatus()

    /// 这一族模块的命令表。
    ///
    /// 「读上网模式」这条命令本身是 Quectel 私有的：`AT+QCFG="usbnet"`。华为
    /// 没有等价的一条（它走 `AT^NDISDUP` 拨号），芯讯、Sierra 也各有各的写法。
    /// 以前这里写死了 Quectel 那一条，换一块别家的模块按「切换上网模式」只会
    /// 收到一句 `ERROR`。现在这一格由 `ModemController` 握手时按认出的厂家写
    /// 进来；表里空着的时候下面两个方法直接说「这块模块没有这一项」，而不是
    /// 发一条注定被拒的命令。
    public var profile: VendorProfile = VendorCatalog.generic

    /// 保护 `status` 这一份状态。
    ///
    /// 2026-09-26 加：计数器多了一条两秒一次的高频刷新路径
    /// （`refreshCountersOnly`），它和 `refreshStatus` 会同时改 `status`。
    /// 这里原本一个写者也没有，加上第二个写者以后必须串起来 —— `DataStatus`
    /// 里有 String 字段，两个线程同时写同一份，坏起来是 retain/release 级别
    /// 的崩溃，不是「数字偶尔不对」那么轻。
    ///
    /// 唯一要忍的代价：`refreshStatus` 会握着这把锁走 AT（正常几十毫秒，忙的
    /// 时候到秒级），这期间高频那一路要等。等就等 —— 它跑在 `.utility` 上，
    /// 而且 AppModel 那边有「上一拍还没回来就跳过这一拍」的闸，不会堆积。
    private let statusLock = NSLock()

    public init(session: ATSession, identity: @escaping () -> USBModuleIdentity) {
        self.session = session
        self.identity = identity
    }

    /// 高频（每两秒）刷新接口计数器和 IPv4，**一条 AT 都不发、一个进程都不拉**。
    ///
    /// 为什么需要它：面板上的「今日 / 本月」和那个流量环读的是 `status.bytesIn/Out`，
    /// 而这两个数字以前只在「打开面板 / 手动刷新 / 切 PCM」时才更新。面板开着不动
    /// 的客户看到的就是一组冻住的数字 —— 视频在放、流量在跑，读数一动不动，这个表
    /// 看起来就是假的。
    ///
    /// 为什么不能直接调 `refreshStatus()`：
    /// - 它开头两条 `AT+QCFG` 是走 AT 口的。通话期间 AT 口归语音链路，
    ///   每两秒插一次往返，代价可能是一通被掐掉的电话。
    /// - 它末尾的 `hostService()` 会过期重拉 `networksetup`，那是一次**进程启动**。
    ///   每五秒拉起一个进程问一句几小时都不变的话，代价远超它值钱的部分。
    ///
    /// 所以这一条路只做 `NET_RT_IFLIST2` 和路由查询这两件纯本地的事，并且只写
    /// `status` 里跟它们有关的几个字段。`usbnetMode` / `composition` 是插上就不变的
    /// 静态配置，`serviceName` / `serviceEnabled` 由完整路径负责，这里一律留着旧值。
    ///
    /// 没有接口时不退回 `AT+QGDCNT`（那是 AT）：读数留在上一次的值上，等完整的
    /// `refreshData()` 去管。少报一会儿，好过在通话里多发一条命令。
    @discardableResult
    public func refreshCountersOnly() -> DataStatus {
        statusLock.lock()
        defer { statusLock.unlock() }
        guard !pinnedHostState else { return status }

        let name = hostInterfaceName()
        guard !name.isEmpty else {
            // 早返回之前先问一句「网卡是不是挂着没有名字」。客人插着模块却一直
            // 没网的时候面板多半是关着的，这条两秒一次的巡检是唯一还在走的路 ——
            // 把这一问放到早返回后面，等于这个状态永远没人看见。
            status.interfaceStranded = hostInterfaceStranded()
            return status
        }
        status.interfaceStranded = false

        var address = [CChar](repeating: 0, count: 64)
        cmacnet_interface_ipv4(name, &address, address.count)
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        let counted = cmacnet_interface_counters(name, &bytesIn, &bytesOut) == 1

        status.interfaceName = name
        status.ipv4Address = String(cString: address)
        status.counterSource = .host
        if counted {
            status.bytesIn = bytesIn
            status.bytesOut = bytesOut
        }
        return status
    }

    // MARK: - Module configuration

    public func readUSBnetMode() throws -> USBnetMode? {
        guard let command = profile.usbNetModeRead else { return nil }
        let response = try session.send(command, timeout: 5)
        guard let raw = ATParsers.usbnetMode(from: response) else { return nil }
        return USBnetMode(rawValue: raw)
    }

    /// 这块模块能不能切上网模式。界面据此决定给不给那个按钮 ——
    /// 给一个按下去只会被拒的按钮，客户的结论是「软件坏了」。
    public var canSwitchUSBnetMode: Bool { profile.canSwitchUsbNet }

    /// Switches the USB networking function and reads the value back.
    ///
    /// Takes effect after a reboot, so the caller decides when to restart the
    /// module. Returns what the module reports *after* the write rather than
    /// what was asked for: firmware that answers OK and then keeps the old
    /// value would otherwise be reported as a success it never adopted.
    @discardableResult
    public func setUSBnetMode(_ mode: USBnetMode, reboot: Bool = false) throws -> USBnetMode {
        // 上网模式也是持久化写入：只允许写在一代模块上，别的型号一律只读。
        try ModuleIdentityGate.requireGenerationOne(session)
        guard let template = profile.usbNetModeWrite else {
            throw DataError.noInterface("这块模块没有切换上网模式的命令，通常不用改。")
        }
        let response = try session.send(String(format: template, mode.rawValue), timeout: 8)
        guard response.final == .ok else { throw DataError.rejected(response.final) }
        // Read back before the reboot: the AT port is gone once this lands.
        let stored = (try? readUSBnetMode()) ?? nil
        status.usbnetMode = stored
        if reboot {
            _ = try? session.send("AT+CFUN=1,1", timeout: 3)
        }
        return stored ?? mode
    }

    public func readComposition() throws -> USBComposition? {
        let response = try session.send("AT+QCFG=\"usbcfg\"", timeout: 5)
        return ATParsers.qcfgComposite(from: response)
    }

    /// Configures PDP context 1. `authentication` 0 = none, 1 = PAP, 2 = CHAP.
    public func configureAPN(_ apn: String,
                             username: String = "",
                             password: String = "",
                             authentication: Int = 0,
                             context: Int = 1) throws {
        // APN / 用户名 / 密码都要原样嵌进带引号的 AT 字符串里。放进去之前
        // 先把会拆坏这条命令的字符挡在门外：引号会提前结束字段、逗号会多切
        // 一个字段、换行/回车/空字符能直接改写成「另一条命令」。APN 本身
        // 允许点、横线、下划线这些，所以只黑名单最危险的那几个。
        for (name, value) in [("APN", apn), ("用户名", username), ("密码", password)] {
            let bad = value.contains { ch in
                ch == "\"" || ch == "," || ch == "\r" || ch == "\n" || ch == "\0"
            }
            if bad {
                throw DataError.invalidParameter("\(name) 里不能有引号、逗号或换行：\(value)")
            }
        }
        guard !apn.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DataError.invalidParameter("APN 不能为空")
        }

        let command = "AT+QICSGP=\(context),1,\"\(apn)\",\"\(username)\",\"\(password)\",\(authentication)"
        let response = try session.send(command, timeout: 8)
        guard response.final == .ok else { throw DataError.rejected(response.final) }
        status.apn = apn
    }

    public func readAPN(context: Int = 1) throws -> String? {
        let response = try session.send("AT+QICSGP=\(context)", timeout: 5)
        guard let raw = response.firstValue(for: "+QICSGP") else { return nil }
        guard let apn = ATParsers.apnField(fromQICSGP: raw) else { return nil }
        status.apn = apn
        return apn
    }

    @discardableResult
    public func activatePDP(context: Int = 1) throws -> Bool {
        let response = try session.send("AT+QIACT=\(context)", timeout: 20)
        let ok = response.final == .ok
        status.pdpActive = ok
        return ok
    }

    public func deactivatePDP(context: Int = 1) throws {
        _ = try session.send("AT+QIDEACT=\(context)", timeout: 25)
        status.pdpActive = false
    }

    /// `AT+QIACT?`：模块自己认为哪些 PDP 上下文是活的。
    ///
    /// 这个位不能只由 `activatePDP()` / `deactivatePDP()` 来写。模块注册上
    /// 网络之后会**自己**把上下文 1 拉起来 —— 客户一个按钮都没按过，网就在
    /// 跑了。只记「我按过的那一下」，面板和只读体检页就会写着「PDP 未激活」，
    /// 而模块那边 `AT+QIACT?` 明明回 `+QIACT: 1,1,1,"100.69.150.192"`。
    /// 2026-09-26 真机实测撞到的就是这个：远程看页面的人会去追一个不存在的
    /// 故障，而现场一切正常。
    ///
    /// 一行 `+QIACT:` 都没有，就是「一个都没起来」—— 那是个确定的 false。
    /// 只有命令本身发不出去（模块不在、AT 口正被语音链路占着）才抛错，调用
    /// 方用 `try?` 接住并保留上一次的结论：**「没问到」不等于「没有」**。
    public func readPDPActive() throws -> Bool {
        let response = try session.send("AT+QIACT?", timeout: 5)
        for row in response.values(for: "+QIACT") {
            // 形状：<contextID>,<state>,<type>,"<ip>"，state = 1 才是活的。
            let fields = row.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if fields.count >= 2, fields[1] == "1" { return true }
        }
        return false
    }

    /// `AT+QGDCNT?` returns byte counters kept by the module itself; useful when
    /// the host interface counters reset.
    ///
    /// 计数器也是私有的：Quectel 叫 `+QGDCNT`，别家不一定有这一条 —— 档案里
    /// 空着就干脆不问，读数留给主机的 `NET_RT_IFLIST2`（那条每块网卡都有）。
    public func moduleCounters() throws -> (sent: UInt64, received: UInt64)? {
        guard let command = profile.dataCounterCommand else { return nil }
        let response = try session.send(command, timeout: 5)
        // `AT+QGDCNT?` → `+QGDCNT`：掐掉开头的 AT、再掐到第一个 `=` / `?`。
        let marker = command.drop { $0 == "A" || $0 == "T" }.prefix { $0 != "=" && $0 != "?" }
        guard !marker.isEmpty, let raw = response.firstValue(for: String(marker)) else { return nil }
        let fields = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 2,
              let sent = UInt64(fields[0]), let received = UInt64(fields[1]) else { return nil }
        return (sent, received)
    }

    // MARK: - Host interface

    /// BSD name of the ECM interface belonging to the module, if macOS has
    /// already attached a driver to it.
    public func hostInterfaceName() -> String {
        for candidate in USBModuleIdentity.attached() {
            var buffer = [CChar](repeating: 0, count: 64)
            if cmacnet_usb_ethernet(UInt16(candidate.vendorID), UInt16(candidate.productID),
                                    &buffer, buffer.count) == 1 {
                return String(cString: buffer)
            }
        }
        // A module re-flashed with stock Quectel firmware presents the Quectel
        // identity, which `attached()` already covers, so reaching here means
        // the composition carries no ECM function at all.
        return ""
    }

    /// 模块那块网卡挂在系统里，但一直没有名字。
    ///
    /// 2026-09-27 真机复现三次：控制台锁着的时候插上模块，`configd` 会明确
    /// 拒绝给它命名（`Console locked, network interface[matching] ignored`），
    /// 而且**解锁之后也不会补做**。这块接口就永远停在「存在但没有 `BSD Name`」
    /// 这个状态上，`hostInterfaceName()` 一辈子返回空。
    ///
    /// 给客户看到的现象是「模块插着、灯亮着，就是没网」，而 App 这边连一句
    /// 解释都说不出来 —— 它以为网卡还没出现，会一直等下去。所以这个状态必须
    /// 单独认出来：它不是「还没到」，是「到不了了」。
    public func hostInterfaceStranded() -> Bool {
        for candidate in USBModuleIdentity.attached() {
            if cmacnet_usb_ethernet_unnamed(UInt16(candidate.vendorID),
                                            UInt16(candidate.productID)) > 0 {
                return true
            }
        }
        return false
    }

    /// 屏幕是不是锁着。
    ///
    /// 只跟上面那条故障一起用：锁着屏幕的时候，让模块重新枚举一次也会被系统
    /// 同样地拒绝（见 `cmacnet_console_locked`），所以自愈得先等到客人回来。
    public var consoleLocked: Bool { cmacnet_console_locked() == 1 }

    @discardableResult
    public func refreshStatus() -> DataStatus {
        statusLock.lock()
        defer { statusLock.unlock() }
        var fresh = status
        fresh.usbnetMode = (try? readUSBnetMode()) ?? fresh.usbnetMode
        fresh.composition = (try? readComposition()) ?? fresh.composition

        // Nothing below can be true of a simulated module, and every line of
        // it would overwrite what the caller stated.
        guard !pinnedHostState else {
            status = fresh
            return fresh
        }

        // 同一个道理：PDP 是模块自己拉起来的，回读一次才知道它真实的样子。
        // 读不到（AT 忙 / 模块刚走）就保留上一次的结论，见 `readPDPActive()`。
        // 必须待在 guard 下面：模拟器的 `AT+QIACT?` 是写死「活着」的，放在
        // 上面会把「用户按了 4G OFF」的夹具冲成「已开启」，截图和真机对不上。
        fresh.pdpActive = (try? readPDPActive()) ?? fresh.pdpActive

        let name = hostInterfaceName()
        fresh.interfaceName = name
        if !name.isEmpty {
            fresh.interfaceStranded = false
            fresh.counterSource = .host
            var address = [CChar](repeating: 0, count: 64)
            cmacnet_interface_ipv4(name, &address, address.count)
            fresh.ipv4Address = String(cString: address)

            var bytesIn: UInt64 = 0
            var bytesOut: UInt64 = 0
            if cmacnet_interface_counters(name, &bytesIn, &bytesOut) == 1 {
                fresh.bytesIn = bytesIn
                fresh.bytesOut = bytesOut
            }
            if let service = hostService() {
                fresh.serviceName = service.name
                fresh.serviceEnabled = service.enabled
            }
        } else {
            fresh.ipv4Address = ""
            fresh.serviceName = ""
            fresh.serviceEnabled = false
            serviceCache = nil
            fresh.interfaceStranded = hostInterfaceStranded()
            // No interface to count on, so fall back to the module's own
            // totals. Without this the panel shows 0 B on a firmware that is
            // not in ECM mode even though traffic is clearly flowing.
            if let counters = try? moduleCounters() {
                fresh.bytesIn = counters.received
                fresh.bytesOut = counters.sent
                fresh.counterSource = .module
            } else {
                fresh.bytesIn = 0
                fresh.bytesOut = 0
                fresh.counterSource = .host
            }
        }
        // The stated totals win over anything measured here, including a real
        // module this Mac happens to have attached.
        if let pinned = pinnedCounters {
            fresh.bytesIn = pinned.bytesIn
            fresh.bytesOut = pinned.bytesOut
            fresh.counterSource = pinned.source
        }
        status = fresh
        return fresh
    }

    // MARK: - macOS network service

    /// The network service macOS created for the module's interface.
    ///
    /// Cheap enough to call from a poll: the service name is cached until the
    /// interface changes, and the enabled flag is only re-read every few
    /// seconds. Pass `force` after changing something to skip the cache.
    public func hostService(force: Bool = false) -> HostNetwork.Service? {
        let device = status.interfaceName
        guard !device.isEmpty else {
            serviceCache = nil
            return nil
        }

        let name: String
        if !force, let cached = serviceCache, cached.device == device {
            name = cached.name
        } else {
            guard let resolved = HostNetwork.service(for: device) else {
                serviceCache = nil
                return nil
            }
            name = resolved.name
        }

        if !force, let cached = serviceCache, cached.device == device,
           Date().timeIntervalSince(cached.at) < Self.serviceCacheLifetime {
            return HostNetwork.Service(name: cached.name, enabled: cached.enabled, device: device)
        }

        let service = HostNetwork.Service(name: name,
                                          enabled: HostNetwork.isEnabled(name),
                                          device: device)
        serviceCache = ServiceCache(device: device, name: name,
                                    enabled: service.enabled, at: Date())
        status.serviceName = service.name
        status.serviceEnabled = service.enabled
        return service
    }

    /// Switches the module's macOS network service on or off.
    ///
    /// Turning it on is what actually sends traffic through the module, and
    /// turning it off is what gives the default route back to Wi-Fi. Fails when
    /// the process is not allowed to change network settings; the caller should
    /// then show `HostNetwork.manualCommand`.
    @discardableResult
    public func setHostService(enabled: Bool) throws -> HostNetwork.Service {
        statusLock.lock()
        let device = status.interfaceName
        statusLock.unlock()
        guard !device.isEmpty else { throw DataError.noInterface("还没有网卡，先在设置里把「使用模式」切到 Mac 版") }
        // The pinned interface does not exist on this Mac, so there is no real
        // service to switch. Only the stated value moves — which also keeps a
        // simulated run from ever reaching `networksetup`.
        if pinnedHostState {
            statusLock.lock()
            defer { statusLock.unlock() }
            status.serviceEnabled = enabled
            serviceCache = ServiceCache(device: device, name: status.serviceName,
                                        enabled: enabled, at: Date())
            return HostNetwork.Service(name: status.serviceName, enabled: enabled, device: device)
        }
        guard let service = HostNetwork.service(for: device) else {
            throw HostNetwork.HostNetworkError.serviceNotFound(device)
        }
        try HostNetwork.setEnabled(service.name, enabled)
        let updated = HostNetwork.Service(name: service.name, enabled: enabled, device: device)
        // 这一笔必须进锁写。`refreshStatus` 是「先取快照 → 干慢活 → 整块写回」，
        // 而且整段都握着这把锁；不在锁里写的话，落地在它临界区中间的这一笔会被
        // 它手里那份旧快照抹掉。2026-09-27 自检实测到了这件事：刚打开的服务被
        // 两秒一次的巡检写回「未启用」，面板停在关着的样子，而系统里它是开的 ——
        // 客人再按一次，来回反复。进程（`networksetup`）留在锁外跑：真机上它要
        // 三到四秒，握着锁等它会把两秒一次那个轻量刷新卡住。
        statusLock.lock()
        serviceCache = ServiceCache(device: device, name: service.name,
                                    enabled: enabled, at: Date())
        status.serviceName = service.name
        status.serviceEnabled = enabled
        statusLock.unlock()
        return updated
    }

    /// Test seam. The module half of this link is observable over AT, but the
    /// host half — the BSD interface and the macOS network service — can only
    /// be read on a machine that actually has the module attached. The
    /// offscreen renderer runs where it does not, and the panel and the setup
    /// window both read this one status, so they have to be seeded together or
    /// they contradict each other in the screenshot.
    ///
    /// Unlike the rest of the test seams this one **sticks**: `refreshStatus`
    /// stops reading IOKit until the process exits. That is what makes it
    /// usable from a running app rather than only from a single-shot renderer
    /// — a poll lands every two seconds, and an unpinned override would be
    /// gone before the user could look at it. Only the `--sim` launch path and
    /// the offscreen renderer call this; the live path never does.
    public func overrideHostState(interface: String, ipv4: String,
                                  service: String, enabled: Bool) {
        statusLock.lock()
        defer { statusLock.unlock() }
        pinnedHostState = true
        status.interfaceName = interface
        status.ipv4Address = ipv4
        status.serviceName = service
        status.serviceEnabled = enabled
        serviceCache = ServiceCache(device: interface, name: service,
                                    enabled: enabled, at: Date())
    }

    /// Screenshot only, the totals half of `overrideHostState`: the byte counts
    /// and their source are stated by the caller instead of read from this Mac.
    public func overrideCounters(bytesIn: UInt64, bytesOut: UInt64,
                                 source: DataCounterSource = .module) {
        statusLock.lock()
        defer { statusLock.unlock() }
        pinnedCounters = (bytesIn, bytesOut, source)
        status.bytesIn = bytesIn
        status.bytesOut = bytesOut
        status.counterSource = source
    }

    /// Everything that has to be true before macOS can pass traffic.
    public func diagnostics() -> [String] {
        var notes: [String] = []
        if let mode = status.usbnetMode {
            notes.append("USB 网络模式：\(mode.technicalName)（\(mode.label)）")
            if !mode.worksOnMac {
                notes.append("⚠️ macOS 没有 RNDIS 驱动，需要执行 AT+QCFG=\"usbnet\",1 并重启模块")
            }
        }
        if let composition = status.composition {
            notes.append("USB 组态：\(composition.hexIdentity) \(composition.flagString)")
            // 这条说明的因果被 2026-09-25 的真机实测理清了：USB 组态里的 audio
            // 位只决定模块要不要**暴露**一张声卡，而接通之后有没有声音还要看
            // 声卡上面那条语音通路（厂商驱动 + 出厂校准 + PCM 桥，见
            // `ModuleVoiceSetup`）。写成「没开就没声音」或者「反正都不走 USB」
            // 都会把客户送去点一个改变不了现象的开关。
            if !composition.audio {
                notes.append("模块声卡未开启（usbcfg 最后一位是 0）。它是通话语音的载体，"
                             + "但光开着还不够；「一键启用」会顺手写 1")
            }
        }
        if status.interfaceName.isEmpty {
            notes.append("未找到模块的网卡：模块未插入、未切到 ECM，或驱动未加载")
        } else if status.ipv4Address.isEmpty {
            notes.append("网卡 \(status.interfaceName) 已存在但还没有 IP，等待 DHCP")
        } else {
            notes.append("网卡 \(status.interfaceName) 在线，IP \(status.ipv4Address)")
            if status.serviceName.isEmpty {
                notes.append("⚠️ macOS 还没有为该网卡建立网络服务，稍后重试或重新插拔")
            } else if status.serviceEnabled {
                notes.append("macOS 网络服务「\(status.serviceName)」已启用，流量会走模块")
            } else {
                notes.append("⚠️ macOS 网络服务「\(status.serviceName)」未启用：网卡有 IP 也不会走流量。"
                             + "点 4G 开关即可启用，或手动执行 "
                             + HostNetwork.manualCommand(status.serviceName, true))
            }
        }
        if !status.apn.isEmpty {
            notes.append("接入点：\(status.apn)")
        }
        return notes
    }
}
