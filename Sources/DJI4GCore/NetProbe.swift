import CMacNet
import Darwin
import Foundation

/// 「这台电脑现在真的能出网吗」—— 一次走系统默认路由的 TCP 探测。
///
/// 为什么非要有这一条（2026-09-26 真机事故的收尾）：模块自己报「已注册、
/// PDP 也活着」并不等于这条路真能把包送出去。卡欠费、APN 选错、运营商那边
/// 没放行、上游断了 —— 这几种情况模块都会一直说自己好的，而 macOS 的默认
/// 路由已经压在模块上了。客户的整台电脑于是没有网，且**没有任何东西会告诉
/// 他为什么**：Wi-Fi 明明连着，浏览器就是打不开。
///
/// 所以判断「这条路能不能用」不能只听模块的，得真发一个包。模块状态那一路
/// 管的是「模块这头有没有准备好」，这一路管的是「准备好的这条路通不通」，
/// 两条都绿才敢把默认路由交出去。
///
/// 用 TCP 而不是 ICMP：`ping` 要 root，App 没有；而且不少网络直接丢 ICMP，
/// 拿它当判据会把一条好的链路判死。
public enum NetProbe {

    /// 探测目标。**纯 IP，不写域名** —— 默认路由压在一条死链路上时，域名
    /// 解析本身就失败，拿域名去测等于把「DNS 通不通」和「能不能出网」混成
    /// 一件事，报出来的原因也是错的。
    ///
    /// 三个都是国内可达的公共 DNS 的 TCP 53 端口（真机实测三个都通）：
    /// 阿里、114、腾讯。Google / Cloudflare 在国内多半连不上，拿来当判据
    /// 会让一条好好的 4G 被判死。
    static let targets: [(label: String, host: String, port: UInt16)] = [
        ("阿里 DNS", "223.5.5.5", 53),
        ("114 DNS", "114.114.114.114", 53),
        ("腾讯 DNS", "119.29.29.29", 53),
    ]

    /// 走系统默认路由试一次。任意一个目标连通就算通。
    ///
    /// 三个目标**同时**发（2026-09-26 改，原来是排队一个个试）。排队的时候
    /// 每个目标独享三秒，模块那条链路死掉时最坏要九秒才回来 —— 而这条路径
    /// 的每一秒都是客人实实在在的断网。并发之后最坏就是一个超时窗口。
    ///
    /// 调用方在后台线程上跑，主线程不等它。
    public static func reachableInternet(timeout: TimeInterval = 3) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var reachable = false
        for target in targets {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                guard tcpConnect(host: target.host, port: target.port, timeout: timeout) else { return }
                lock.lock()
                reachable = true
                lock.unlock()
            }
        }
        // 每个目标自己限时 `timeout`，所以这里最坏等一个超时窗口；多给半秒
        // 是留给线程调度的，不是留给网络的。等超时了就带着手上已有的答案走，
        // 不等那几个还没回来的 —— 它们的结果改变不了「这一轮通没通」，
        // 而且它们自己会结束。
        _ = group.wait(timeout: .now() + timeout + 0.5)
        lock.lock()
        defer { lock.unlock() }
        return reachable
    }

    /// 一次非阻塞 connect + `select` 等结果。成功 = 三次握手真的完成了，
    /// 也就是这条路真的能把包送出去并收回来。
    ///
    /// 不用 `connect()` 的阻塞模式：默认路由压在死链路上时，它要等内核的
    /// TCP 超时（分钟级），面板会一直卡在那里。
    public static func tcpConnect(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        let started = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // 0 = 立刻连上（本机或同网段）；`EINPROGRESS` = 正在握手。其余都是
        // 「这条路现在根本发不出去」—— 没有默认路由时就是这里直接掉出来，
        // 不用等超时。
        if started != 0 && errno != EINPROGRESS { return false }

        var writeSet = fd_set()
        withUnsafeMutablePointer(to: &writeSet) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
                bits[Int(fd) / 32] |= Int32(bitPattern: UInt32(1) << UInt32(Int(fd) % 32))
            }
        }
        var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
        guard select(fd + 1, nil, &writeSet, nil, &wait) > 0 else { return false }

        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }

    /// 这台电脑的默认路由现在压在哪块网卡上（如 `en0`）；没有默认路由时是空串。
    ///
    /// 2026-09-26 交付当天真机实测出来的盲区：保命逻辑拿「模块那条网络服务是不是
    /// 开着」当总闸，而那个标记只有**完整刷新**才会更新。于是只要路由是从别的路
    /// 上到模块的 —— 在终端里开的服务、macOS 在 USB 重新枚举之后自己恢复的、
    /// App 刚重启还没刷过 —— 保命逻辑就以为「这条 4G 不关我的事」，两眼一闭。
    /// 真机实测：整台电脑断了九十秒，它一次都没动。
    ///
    /// 真正该问的是「默认路由现在在谁手上」，而路由表当场就能回答：不拉进程、
    /// 不发 AT、也没有会过期的缓存。
    public static func defaultRouteInterface() -> String {
        var name = [CChar](repeating: 0, count: 64)
        guard cmacnet_default_route_interface(&name, name.count) == 1 else { return "" }
        return String(cString: name)
    }

    /// 默认路由是不是正压在 `interface` 这块网卡上。
    ///
    /// `interface` 空着时一律回 false：不知道模块叫什么名字的时候宁可不动
    /// （调用方另有兜底），也不能凭猜去抢路由。
    public static func defaultRouteIsOn(interface: String) -> Bool {
        guard !interface.isEmpty else { return false }
        return defaultRouteInterface() == interface
    }

    /// 除了 `excluding` 之外，这台机器上还有别的、拿到 IPv4 的网卡吗？
    ///
    /// 用来回答「把模块这条服务关掉以后，还有没有路可走」。没有别的路可走
    /// 时不能关：关掉只是把最后一根线也剪了，客户的电脑一样没有网，还少了
    /// 一个「4G 自己好了就恢复」的机会。
    ///
    /// `169.254.x.x` 不算 —— 那是 DHCP 没拿到地址时自己编的，出不了网。
    public static func hasOtherUplink(excluding: String) -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return false }
        defer { freeifaddrs(head) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            if name == excluding { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var body = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard inet_ntop(AF_INET, &body, &buffer, socklen_t(buffer.count)) != nil else {
                continue
            }
            if String(cString: buffer).hasPrefix("169.254.") { continue }
            return true
        }
        return false
    }
}
