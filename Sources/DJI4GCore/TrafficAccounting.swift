import Foundation

/// 「本月流量」在面板上的呈现方式。四个状态互斥，直接对应需求里的
/// 「未连接 / 已连接 / 断开 / 重新连接」四段。
public enum TrafficDisplayState: Equatable {
    /// 模块未连接，且没有任何已验证的 QDC507 流量记录：显示「暂无数据」或「—」。
    case noData
    /// 模块已连接，但拿不到有效流量数据：显示「暂无法统计」。
    case unavailable
    /// 模块已连接且已验证的接口正在计数：显示实时「本月」。
    case live
    /// 模块已断开，但有验证过的历史累计：显示「已记录的4G流量」。
    case historical

    /// 纯函数：把「模块是否连着 / 当前读数是否已验证 / 本月是否有已验证历史」
    /// 三件事映射成显示状态。无 IOKit、无 AT，可直接在自检里逐条断言。
    public static func resolve(isConnected: Bool,
                               countersVerified: Bool,
                               monthVerified: Bool) -> TrafficDisplayState {
        if isConnected {
            return countersVerified ? .live : .unavailable
        }
        return monthVerified ? .historical : .noData
    }
}

/// 「今日 / 本月」流量的纯增量累计器。
///
/// 只做算术，不碰 IOKit、不碰 AT、不碰 UserDefaults，所以能在自检里把
/// 「首次绑定建立基线 / 接口重建 / 计数器归零 / 回绕 / 重复采样 / 跨月跨天」
/// 这些分支一条条钉死。
///
/// 一条铁律：**累计器只认增量**。任何一拍进来，先判断它是不是上一次那条
/// 接口的延续；不是（首次、换了接口、计数器回退）就只重建基线、不把当前
/// 读数本身当成新增量 —— 接口生命周期总计数器不能被当成「本月用了多少」。
public struct TrafficAccounting: Equatable {
    /// 上一次采样时接口计数器的读数。`nil` 表示还没建立基线。
    public private(set) var lastTotal: UInt64?
    /// 上一次采样绑定的接口名。接口名变了说明模块重新枚举，需要重新建基线。
    public private(set) var lastInterface: String?
    /// 当月累计（只含有效增量）。
    public private(set) var monthTotal: UInt64 = 0
    /// 当日累计（只含有效增量）。
    public private(set) var dayTotal: UInt64 = 0
    /// 当前累计对应的月份键（`yyyy-MM`），用于跨月清零。
    public private(set) var monthKey: String?
    /// 当前累计对应的日期键（`yyyy-MM-dd`），用于跨天清零。
    public private(set) var dayKey: String?

    public init() {}

    /// 从持久化恢复上一次的累计现场（可选）。没有已验证的历史时不调用。
    public init(monthKey: String?, monthTotal: UInt64,
                dayKey: String?, dayTotal: UInt64,
                lastTotal: UInt64?, lastInterface: String?) {
        self.monthKey = monthKey
        self.monthTotal = monthTotal
        self.dayKey = dayKey
        self.dayTotal = dayTotal
        self.lastTotal = lastTotal
        self.lastInterface = lastInterface
    }

    /// 把某一拍接口计数器读入累计器。
    ///
    /// - Parameters:
    ///   - total: 当前接口计数器的上下行总和。
    ///   - interface: 计数器所属的网卡名（已验证的模块 ECM 网卡）。
    ///   - month: 当前月份键。
    ///   - day: 当前日期键。
    /// - Returns: 这一拍计入「今日 / 本月」的增量。
    @discardableResult
    public mutating func record(total: UInt64,
                                interface: String,
                                month: String,
                                day: String) -> UInt64 {
        // 跨月 / 跨天：只清累计，不动基线。基线由下面「接口是否延续」判。
        if monthKey != month {
            monthKey = month
            monthTotal = 0
        }
        if dayKey != day {
            dayKey = day
            dayTotal = 0
        }

        let delta: UInt64
        if let previous = lastTotal, lastInterface == interface {
            if total >= previous {
                delta = total - previous
            } else {
                // 计数器回退（重新枚举 / 归零 / 回绕）：只重建基线，不计增量。
                delta = 0
            }
        } else {
            // 首次绑定，或接口名变了（模块重新枚举）：只建立基线，不计增量。
            delta = 0
        }

        lastTotal = total
        lastInterface = interface
        monthTotal += delta
        dayTotal += delta
        return delta
    }
}
