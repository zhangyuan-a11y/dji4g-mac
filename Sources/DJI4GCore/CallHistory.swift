import Foundation

/// 一通电话的结局。
public enum CallOutcome: String, Codable, Equatable {
    /// 接通了（呼出、来电都算）。
    case answered
    /// 来电没接到：响过铃，没人接。
    case missed
    /// 来电被按掉了。
    case rejected
    /// 呼出没接通：对方忙、无人接听，或者拨到一半被挂掉。
    case failed

    /// 列表里那一列结果。四个都是三个字 —— 栏宽钉死，扫下去对得齐。
    public var label: String {
        switch self {
        case .answered: return "已接通"
        case .missed: return "没接到"
        case .rejected: return "已拒接"
        case .failed: return "未接通"
        }
    }
}

/// 通话记录里的一行。
public struct CallRecord: Codable, Equatable, Identifiable {
    public var id: UUID
    public var number: String
    public var outgoing: Bool
    public var outcome: CallOutcome
    /// 这一通是什么时候的事：来电记响铃那一刻，呼出记拨出去那一刻。
    public var at: Date
    /// 接通之后说了多久。没接通的记 0。
    public var seconds: Int

    public init(id: UUID = UUID(), number: String, outgoing: Bool,
                outcome: CallOutcome, at: Date, seconds: Int = 0) {
        self.id = id
        self.number = number
        self.outgoing = outgoing
        self.outcome = outcome
        self.at = at
        self.seconds = seconds
    }

    /// 这一通是什么时候的事。
    ///
    /// 今天只给钟点，昨天就写「昨天」，同年写月日 —— 一排记录里最该一眼分出来的
    /// 是「今天打的那几个」，`09-24 14:23` 那种全量写法反而把钟点埋进数字里。
    /// 精确到分的那一刻在 `.help` 和这个方法的 `full` 里都还留着。
    public func timeLabel(now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        if calendar.isDate(at, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.isDate(at, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now) ?? now) {
            return "昨天"
        } else if calendar.component(.year, from: at) == calendar.component(.year, from: now) {
            formatter.dateFormat = "MM-dd"
        } else {
            // 上一年的只写年份。栏宽是按「09-19」这五个字符定的，`2026-09`
            // 七个字符会被裁成省略号 —— 而这一列被裁只会让客户读错时间。
            formatter.dateFormat = "yyyy"
        }
        return formatter.string(from: at)
    }

    /// 鼠标停上去看的那一行：几月几号几点几分、接通了多久。
    public func detailLabel(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var text = (outgoing ? "呼出 " : "来电 ") + formatter.string(from: at) + " · " + outcome.label
        if seconds > 0 { text += " · " + CallRecord.durationLabel(seconds) }
        return text
    }

    /// `02:05` / `62:05`。
    ///
    /// 分钟不做进位：62 分 5 秒就写 `62:05`，和通话卡片上那颗计时器一个写法
    /// （`CallInfo.durationLabel`）。分成小时写 `1:02:05` 是七个字符，这一栏
    /// 只有三十几个点宽，末位会被省略号吃掉。
    public static func durationLabel(_ seconds: Int) -> String {
        let total = max(0, seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// 通话记录：屏幕上一行行看的那份，同时落盘。
///
/// 模块**不给**通话记录。`AT+CLCC` 报的只有「此刻在响 / 在通」的那几路，一代
/// QDC507 固件上问不出历史（真机试过 `AT+CPBS` 那套，结果为空）。所以这一份是
/// 我们自己攒的：响铃、接通、挂断每翻一页就抄一条下来，攒成客户的通话记录。
///
/// 两条边界：
///   1. **只在真客户那条路上记。** 自检、截图、`--sim` 演示都会造出「来电」，
///      那些不能进客户的历史。过滤在调用方（`AppModel` 认 `announcesAlerts`），
///      这一层只管记；
///   2. **要跨重启。** 客户早上打过的电话，晚上再打开还得在 —— 所以每写一条
///      就存一次盘。
///
/// 线程：`observe` 从主线程和 AT 那条线程都会进来，内部一把锁。
public final class CallHistory {
    /// 正在发生的那一通。
    private struct Live {
        var number: String
        var outgoing: Bool
        var startedAt: Date
        var answeredAt: Date?
        var rejected = false
    }

    public private(set) var records: [CallRecord] = []

    private let lock = NSLock()
    private let file: URL
    /// 这一份要不要落到 `file`。见 `init(file:persists:)`。
    private let persists: Bool
    private let saveQueue = DispatchQueue(label: "local.dji4g.callhistory")
    private var live: Live?
    /// 通话中插进来的第二路。它不占 `live` —— 第一路还通着，两条各记各的。
    private var waiting: Live?

    /// 攒这么多条就丢最旧的。两百行够客户回看很久，文件也就几十 KB。
    private static let keep = 200

    /// `~/Library/Application Support/DJI4G/calllog.json`。
    ///
    /// 和 `instance.lock` 同一处：卸载、排查、备份都只认这一个文件夹。
    public static func defaultFile() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DJI4G/calllog.json")
    }

    /// `persists: false` 是给模拟器那条路的：**只活在内存里，既不读也不写那个
    /// 文件**。
    ///
    /// 出图、`--sim-check`、`--sim` 演示都跑在真 App 进程里，用的也是这台机器上
    /// **真那一份** `calllog.json`。而这三条路每走一次就要响一遍铃、走一遍收线，
    /// `finish()` 一落盘就把桌上的通话记录写成模拟数据。2026-09-30 在客户的机器
    /// 上数出来的：28 行里 24 行是 `+8613800138000`（模拟器的号码），真通话只剩
    /// 09-28 那 4 条 —— 客户点开「通话记录」，看到的是我们自己出图留下的痕迹。
    ///
    /// 不读那一半同样重要：`seed()` 之后再来一条就落盘，落的是「种下去的几条 +
    /// 新的这一条」，客户原来那两百行会被整份覆盖掉。
    public init(file: URL = CallHistory.defaultFile(), persists: Bool = true) {
        self.file = file
        self.persists = persists
        guard persists else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: file),
           let stored = try? decoder.decode([CallRecord].self, from: data) {
            records = Array(stored.suffix(Self.keep))
        }
    }

    // MARK: - 记

    /// 状态每翻一页喂一口。同一状态重复喂没有副作用。
    ///
    /// 返回值是这一口**刚结算**出来的那条记录（没有就返回 nil）。调用方拿它
    /// 在日志里留一行 —— 客户说「通话记录不对」时，报告里有没有这一行，是能
    /// 分清「没记」和「记错了」的唯一凭据。
    @discardableResult
    public func observe(_ info: CallInfo) -> CallRecord? {
        lock.lock(); defer { lock.unlock() }

        // 第二路（通话中插进来的来电）单独算一条：`CallService` 会把排在
        // 前面的那一路报出来，但第一路并没有结束。
        if info.state == .waiting {
            var call = waiting ?? Live(number: "", outgoing: false, startedAt: Date())
            if !info.number.isEmpty { call.number = info.number }
            waiting = call
            return nil
        }
        if let parked = waiting {
            waiting = nil
            if parked.answeredAt != nil {
                // 换路：客户接的是后来那一路，原来那一路转成保持。两条各记
                // 各的 —— 前一条按时长收掉，从这一路接着数。
                if let previous = live { finish(previous, outcome: .answered, at: Date()) }
                live = parked
            } else {
                finish(parked, outcome: parked.rejected ? .rejected : .missed, at: Date())
            }
        }

        if info.state.isBusy {
            var call = live ?? Live(number: "", outgoing: info.direction == .outgoing,
                                    startedAt: info.startedAt ?? Date())
            if !info.number.isEmpty { call.number = info.number }
            // 接通的那一刻就是「说过多久」的起点。`CallService` 已经记了
            // 这个时刻，它比这里的第一眼准（轮询两秒一拍）。
            if info.state == .active, call.answeredAt == nil {
                call.answeredAt = info.startedAt ?? Date()
            }
            live = call
            return nil
        }

        // idle / ended：这一通结束了。
        guard let finished = live else { return nil }
        live = nil
        if finished.answeredAt != nil {
            return finish(finished, outcome: .answered, at: Date())
        } else if finished.rejected {
            return finish(finished, outcome: .rejected, at: Date())
        }
        return finish(finished, outcome: finished.outgoing ? .failed : .missed, at: Date())
    }

    /// 客户按了「拒接」（响铃中的来电）。
    public func markRejected() {
        lock.lock()
        if waiting != nil { waiting?.rejected = true } else { live?.rejected = true }
        lock.unlock()
    }

    /// 客户按了「挂断」。响铃中的来电按挂断，在对面看就是被拒 —— 记成
    /// 「没接到」和事实相反。已经接通的那一通按挂断只是正常结束。
    public func markHungUp() {
        lock.lock()
        if var call = live, call.answeredAt == nil, !call.outgoing {
            call.rejected = true
            live = call
        }
        lock.unlock()
    }

    /// 客户接了第二路（`AT+CHLD=2`）。记在第二路上，等状态翻页时结算。
    public func markAnsweredWaiting() {
        lock.lock()
        if var call = waiting {
            call.answeredAt = Date()
            waiting = call
        }
        lock.unlock()
    }

    /// 客户把第二路拒了（`AT+CHLD=0`），或者按了「挂断全部」把两路一起挂了。
    public func markRejectedWaiting() {
        lock.lock()
        waiting?.rejected = true
        lock.unlock()
    }

    /// 客户自己清空的。清的是历史，不影响正在进行的这一通。
    public func clear() {
        lock.lock()
        records = []
        lock.unlock()
        persist([])
    }

    /// 出图 / 演示专用：把列表钉成给定的几条。
    ///
    /// 只改内存、不落盘 —— 出图的这台机器上装着真客户的那份 `calllog.json`，
    /// 画一张商品图不能顺手把人家的通话记录覆盖掉。
    public func seed(_ items: [CallRecord]) {
        lock.lock()
        records = items
        lock.unlock()
    }

    // MARK: - 收尾

    @discardableResult
    private func finish(_ call: Live, outcome: CallOutcome, at when: Date) -> CallRecord? {
        // 号码和接通都没见到的「通话」是模块自己抖出来的，不记：一行空白
        // 记录对客户没有任何意义。QDC507 把 ECM 数据链路报成通话那件事已经
        // 在 `parseCLCC` 里挡掉了，这里是第二道。
        guard !call.number.isEmpty || call.answeredAt != nil else { return nil }
        let seconds = call.answeredAt.map { max(0, Int(when.timeIntervalSince($0))) } ?? 0
        let record = CallRecord(number: call.number, outgoing: call.outgoing,
                                outcome: outcome, at: call.startedAt, seconds: seconds)
        records.append(record)
        if records.count > Self.keep {
            records.removeFirst(records.count - Self.keep)
        }
        persist(records)
        return record
    }

    /// 存盘。写文件排在自己的队列上，不在调用线程上做 —— 它会在 AT 那条
    /// 线程和主线程上被叫到。
    private func persist(_ snapshot: [CallRecord]) {
        // 模拟器那一份没有文件可写，见 `init(file:persists:)`。
        guard persists else { return }
        let url = file
        saveQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// 日志、报告里用的脱敏号码。
///
/// 客户桌面上的「诊断.command」打的报告是会被发出来的（微信、邮件，都会），
/// 里面不该跟着一串完整手机号 —— 日志文件里本来还留着短信正文之类的东西，
/// 少一条隐私是一条。留头三位、尾四位：谁打来的还认得出来，报告照样能用来看
/// 时间线对不对。
///
/// 短号（`10086`、`+8610` 这种客服号）原样返回：它不是私人号码，遮了反而让
/// 报告读不懂。
public extension String {
    var maskedAsPhoneNumber: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 7 else { return trimmed }
        return trimmed.prefix(3) + "****" + trimmed.suffix(4)
    }
}
