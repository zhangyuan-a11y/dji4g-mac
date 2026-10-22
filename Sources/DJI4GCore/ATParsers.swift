import Foundation

/// Field-level parsers for the Quectel command set the module answers to.
/// Everything here is pure so it can be exercised against recorded responses.
public enum ATParsers {

    // MARK: - Identity

    public static func identity(fromATI response: ATResponse, revision: ATResponse?) -> ModuleIdentity {
        var identity = ModuleIdentity()
        let atiLines = response.lines.filter { !$0.isEmpty }
        identity.rawATI = atiLines.joined(separator: " | ")

        for line in atiLines {
            let upper = line.uppercased()
            if upper.hasPrefix("REVISION") || upper.hasPrefix("+GMR") {
                identity.revision = value(afterColonIn: line)
            } else if line.range(of: #"^EG\d|^EC\d|^UC\d|^RM\d|^BG\d|^QDC\d"#, options: .regularExpression) != nil {
                identity.model = line
            } else if upper.contains("QUECTEL") {
                if identity.model.isEmpty { identity.model = line }
            } else if line.range(of: #"^[A-Z0-9_]{8,}$"#, options: .regularExpression) != nil, identity.revision.isEmpty {
                identity.revision = line
            }
        }
        // 大疆一代模块（DJI/QDC507，Quectel EG25-G 的贴牌）`ATI` 回的是三行
        // 贴牌厂自己的串：`Baiwang` / `QDC507` / `Revision: QDC507GLEFM21`。
        // 型号行不落在上面任何一条前缀里，型号就是空串，面板于是给一台好好
        // 干活的模块显示「未识别」。兜一层：回显、品牌词、已经认成固件号的
        // 行都排掉之后，第一个「带数字的短代号」当型号。白名单认得出来的
        // 型号永远走不到这里。
        if identity.model.isEmpty {
            identity.model = atiLines.first { isModelLike($0, revision: identity.revision) } ?? ""
        }
        if let revision {
            let text = revision.lines.first(where: { !$0.isEmpty && !$0.uppercased().hasPrefix("AT+") })
            if let text, !text.isEmpty { identity.firmwareBuild = text }
        }
        return identity
    }

    /// `QDC507`、`SIM7600G-H`、`RM500Q-GL` 是型号；`Baiwang`、`OK`、以及
    /// 已经被认成固件号的那串（如 `QDC507GLEFM21`）不是。
    private static func isModelLike(_ line: String, revision: String) -> Bool {
        let upper = line.uppercased()
        guard !upper.hasPrefix("AT"), !upper.hasPrefix("REVISION"), !upper.hasPrefix("+GMR") else { return false }
        guard line.count >= 3, line.count <= 24, line != revision else { return false }
        guard line.contains(where: { $0.isNumber }) else { return false }
        return line.range(of: #"^[A-Za-z][A-Za-z0-9_+.\-]*$"#, options: .regularExpression) != nil
    }

    public static func imei(from response: ATResponse) -> String {
        for line in response.lines {
            let digits = line.filter { $0.isNumber }
            if digits.count >= 14, !line.uppercased().hasPrefix("AT") { return digits }
        }
        return ""
    }

    public static func temperatures(from response: ATResponse) -> [String] {
        guard let raw = response.firstValue(for: "+QTEMP"), !raw.isEmpty else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - SIM

    /// Reads `AT+CPIN?` into a state the app can act on.
    ///
    /// The answer of a card-less module is a bare `+CME ERROR: 10` (or `13`,
    /// depending on firmware), with no `+CPIN` line at all. Treating that as
    /// "PIN required" — which is what a `ready == false` fallback does — tells
    /// the user to go find a PIN they do not need, while the card is simply not
    /// in the slot.
    public static func simStatus(fromCPIN response: ATResponse,
                                 qsimstat: ATResponse? = nil) -> SIMStatus {
        var status = SIMStatus()
        let raw = (response.firstValue(for: "+CPIN") ?? "").trimmingCharacters(in: .whitespaces)
        status.rawResponse = raw
        status.pinState = raw
        if let qsimstat, let detected = simDetected(fromQSIMSTAT: qsimstat) {
            status.detectedInserted = detected
        }
        status.state = simState(final: response.final, pinLine: raw, detected: status.detectedInserted)
        status.ready = status.state == .ready
        status.pinRequired = status.state == .pinRequired || status.state == .pukRequired
        return status
    }

    /// Classifies what the module said. Pure, so every recorded answer can be
    /// replayed in the self-test.
    static func simState(final: ATFinal, pinLine: String, detected: Bool? = nil) -> SIMState {
        let upper = pinLine.uppercased()
        // "NOT READY" contains "READY", so the negations are matched first.
        if upper.contains("NOT READY") { return .notReady }
        if upper.contains("NOT INSERTED") || upper.contains("ABSENT") { return .missing }
        if upper.contains("PUK") { return .pukRequired }
        if upper.contains("PIN") { return .pinRequired }
        if upper.contains("READY") { return .ready }

        switch final {
        case .cme(let code):
            switch code {
            case 10, 15: return .missing
            case 11: return .pinRequired
            case 12: return .pukRequired
            case 13: return .failure
            case 14: return .busy
            // The module answers `+CME ERROR: 3` (operation not allowed) for a
            // while after boot, before it has looked at the card at all.
            case 3: return detected == false ? .missing : .notReady
            default: return detected == false ? .missing : .unknown
            }
        case .ok, .error:
            return pinLine.isEmpty ? .unknown : .notReady
        default:
            return pinLine.isEmpty ? .unknown : .notReady
        }
    }

    /// `AT+QSIMSTAT?` → `+QSIMSTAT: <enable>,<inserted>`；第二段就是卡座的硬件检测。
    /// 模块不支持这个命令时返回 ERROR，这里自然拿到 nil，调用方忽略即可。
    public static func simDetected(fromQSIMSTAT response: ATResponse) -> Bool? {
        guard let raw = response.firstValue(for: "+QSIMSTAT") else { return nil }
        let fields = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 2, let value = Int(fields[1]) else { return nil }
        return value == 1
    }

    public static func simInserted(fromQUSIM response: ATResponse) -> Bool? {
        guard let raw = response.firstValue(for: "+QUSIM") else { return nil }
        if let first = raw.split(separator: ",").first, let value = Int(first.trimmingCharacters(in: .whitespaces)) {
            return value == 1
        }
        return nil
    }

    public static func subscriberID(from response: ATResponse) -> String {
        for line in response.lines where !line.uppercased().hasPrefix("AT") {
            let digits = line.filter { $0.isNumber }
            if digits.count >= 14 { return digits }
        }
        return ""
    }

    public static func ownNumber(fromCNUM response: ATResponse) -> String {
        guard let raw = response.firstValue(for: "+CNUM") else { return "" }
        for field in raw.split(separator: ",") {
            let cleaned = field.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            let digits = cleaned.filter { $0.isNumber || $0 == "+" }
            if digits.filter({ $0.isNumber }).count >= 6 { return digits }
        }
        return ""
    }

    // MARK: - Signal

    public static func signal(fromCSQ response: ATResponse) -> SignalStatus {
        var status = SignalStatus()
        guard let raw = response.firstValue(for: "+CSQ") else { return status }
        status.rawCSQ = raw
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if let first = parts.first, let value = Int(first) { status.rssiIndex = value }
        if parts.count > 1, let second = Int(parts[1]) { status.berIndex = second }
        return status
    }

    /// `AT+QCSQ` answers `<sysmode>,<rssi>,<rsrp>,<sinr>,<rsrq>` on the EG25-G.
    /// EG21-G class firmware reports the LTE RSSI as a positive magnitude, so a
    /// positive first value is read as its own negation.
    public static func mergeQCSQ(_ response: ATResponse, into status: inout SignalStatus) {
        guard let raw = response.firstValue(for: "+QCSQ") else { return }
        status.rawQCSQ = raw
        let parts = raw.split(separator: ",").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"\t"))
        }
        guard parts.count >= 5 else {
            // Single-value form alternates between RSSI / RSRP / SINR / RSRQ.
            return
        }
        if let rssi = Double(parts[1]) { status.rssiDBmOverride = Int(rssi > 0 ? -rssi : rssi) }
        if let rsrp = Double(parts[2]), rsrp < 0 { status.rsrp = rsrp }
        if let sinr = Double(parts[3]) { status.sinr = sinrInDecibels(sinr) }
        if let rsrq = Double(parts[4]), rsrq <= 0 { status.rsrq = rsrq }
    }

    /// `AT+QCSQ` scales SINR in fifths of a dB on most firmware revisions while
    /// `AT+QENG` reports whole dB, so only values that cannot be dB are rescaled.
    static func sinrInDecibels(_ value: Double) -> Double {
        value > 40 ? value / 5 : value
    }

    // MARK: - Network

    public static func registration(from response: ATResponse, prefix: String) -> RegistrationState? {
        guard let raw = response.firstValue(for: prefix) else { return nil }
        let parts = raw.split(separator: ",")
        guard parts.count >= 2, let code = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return RegistrationState(code: code)
    }

    public static func networkInfo(from response: ATResponse, into status: inout NetworkStatus) {
        guard let raw = response.firstValue(for: "+QNWINFO") else { return }
        status.rawNetworkInfo = raw
        let parts = splitQuoted(raw)
        if parts.count > 0 { status.accessTechnology = parts[0] }
        if parts.count > 1 { status.carrier = CarrierCatalog.carrier(forMCCMNC: parts[1]) }
        if parts.count > 2 { status.band = parts[2] }
        if parts.count > 3, let channel = Int(parts[3]) { status.channel = channel }
    }

    public static func operatorName(from response: ATResponse) -> String? {
        guard let raw = response.firstValue(for: "+COPS") else { return nil }
        for field in splitQuoted(raw) where !field.isEmpty {
            let digits = field.filter { $0.isNumber }
            if digits.count == field.count, !digits.isEmpty { continue }
            if field.uppercased().hasPrefix("+") { continue }
            return field
        }
        return nil
    }

    /// `AT+QENG="servingcell"` carries the most detail; fields differ per RAT.
    /// LTE answers `state,rat,duplex,mcc,mnc,cellid,pcid,earfcn,band,ulbw,dlbw,
    /// tac,rsrp,rsrq,rssi,sinr,srxlev`; WCDMA places `rscp,ecio` at the end.
    public static func mergeQENG(_ response: ATResponse, into status: inout NetworkStatus, signal: inout SignalStatus) {
        guard let raw = response.firstValue(for: "+QENG") else { return }
        let parts = splitQuoted(raw)
        guard let ratIndex = parts.firstIndex(where: {
            ["LTE", "WCDMA", "GSM", "NR5G", "CDMA"].contains($0.uppercased())
        }) else { return }
        let rat = parts[ratIndex]
        if status.accessTechnology.isEmpty { status.accessTechnology = rat }

        let rest = Array(parts[(ratIndex + 1)...])
        func number(_ index: Int) -> Double? {
            guard index >= 0, index < rest.count else { return nil }
            return Double(rest[index])
        }
        func useCarrier(fromMCC mccIndex: Int) {
            guard mccIndex + 1 < rest.count else { return }
            let mcc = rest[mccIndex], mnc = rest[mccIndex + 1]
            if !mcc.isEmpty, !mnc.isEmpty {
                status.carrier = CarrierCatalog.carrier(forMCCMNC: mcc + mnc)
            }
        }

        if rat.uppercased() == "LTE" {
            useCarrier(fromMCC: 1)
            if let earfcn = number(5) { status.channel = Int(earfcn) }
            if rest.count > 6, !rest[6].isEmpty { status.band = "LTE BAND \(rest[6])" }
            let fields = lteSignalFields(rest)
            if let value = fields.rsrp, value < 0 { signal.rsrp = value }
            if let value = fields.rsrq, value <= 0 { signal.rsrq = value }
            if let value = fields.rssi, value < 0 { signal.rssiDBmOverride = Int(value) }
            if let value = fields.sinr { signal.sinr = value }
        } else {
            useCarrier(fromMCC: 0)
            if rat.uppercased() == "WCDMA", let uarfcn = number(4) { status.channel = Int(uarfcn) }
            // WCDMA ends `...<psc>,<rscp>,<ecio>`; GSM ends with RSSI in dBm.
            let measurement = rat.uppercased() == "WCDMA" ? rest.count - 2 : rest.count - 1
            if let dbm = number(measurement), dbm < -20 { signal.rssiDBmOverride = Int(dbm) }
        }
    }

    /// RSRP/RSRQ/RSSI/SINR follow `<tac>` in the LTE serving-cell answer, but
    /// firmware revisions differ in how many fields precede them. The tuple is
    /// therefore located by the value ranges each measurement must fall in,
    /// scanned from the end so the last well-formed run wins.
    static func lteSignalFields(_ rest: [String]) -> (rsrp: Double?, rsrq: Double?, rssi: Double?, sinr: Double?) {
        func number(_ index: Int) -> Double? {
            guard index >= 0, index < rest.count else { return nil }
            return Double(rest[index])
        }
        let offset = (rsrp: number(10), rsrq: number(11), rssi: number(12), sinr: number(13))
        var index = min(rest.count - 4, 13)
        while index >= 0 {
            let rsrp = number(index), rsrq = number(index + 1), rssi = number(index + 2)
            if let rsrp, let rsrq, let rssi,
               (-140...(-44)).contains(rsrp), (-20...(-3)).contains(rsrq), (-113...(-25)).contains(rssi) {
                return (rsrp, rsrq, rssi, number(index + 3))
            }
            index -= 1
        }
        return offset
    }

    // MARK: - 厂家无关的信号与网络读取
    //
    // 上面那两条 `mergeQCSQ` / `mergeQENG` 吃的是 Quectel 的私房命令。下面这
    // 几条是给别的厂家（以及压根认不出厂家时）用的 —— 有了这一层，「换一块
    // 模块」才不再等于「面板上一排 `--`」。

    /// `AT+CESQ` —— 3GPP TS 27.007 第 8.69 节，**不是哪一家专有**。
    ///
    /// `+CESQ: <rssi>,<ber>,<rscp>,<ecno>,<rsrq>,<rsrp>`
    ///
    /// 这一层里最值钱的一条：它同时给出 RSRQ 和 RSRP，而这两格正是面板上
    /// 「信号」那张卡最需要的。`AT+CSQ` 只给一个 RSSI 档位，远远不够。
    /// 六格各自用 99 / 255 表示「不知道」，缺哪格就留哪格，不拿 0 去凑。
    public static func mergeCESQ(_ response: ATResponse, into status: inout SignalStatus) {
        guard let raw = response.firstValue(for: "+CESQ") else { return }
        status.rawCESQ = raw
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        func value(_ index: Int) -> Int? {
            guard index < parts.count, let number = Int(parts[index]) else { return nil }
            return number
        }
        // 0…63 → −113 + 2n dBm；99 = 不知道。
        if let rssi = value(0), (0...63).contains(rssi) {
            status.rssiIndex = min(31, rssi / 2)
            status.rssiDBmOverride = -113 + 2 * rssi
        }
        // 0…97 → −140 + n dBm；255 = 不知道。
        if let rsrp = value(5), (0...97).contains(rsrp) {
            status.rsrp = Double(-140 + rsrp)
        }
        // 0…34 → −19.5 + 0.5n dB。
        if let rsrq = value(4), (0...34).contains(rsrq) {
            status.rsrq = -19.5 + 0.5 * Double(rsrq)
        }
        // 0…96 → −120 + n dBm（UTRAN 的 RSCP）。只在没有 RSRP 时顶这一格。
        if status.rsrp == nil, let rscp = value(2), (0...96).contains(rscp) {
            status.rsrp = Double(-120 + rscp)
        }
        // 0…49 → −24 + 0.5n dB（Ec/No）。SINR 缺席时拿它顶。
        if status.sinr == nil, let ecno = value(3), (0...49).contains(ecno) {
            status.sinr = -24 + 0.5 * Double(ecno)
        }
    }

    /// `AT^HCSQ?` —— 华为自己的信号质量。
    ///
    /// `^HCSQ: "LTE",<rssi>,<rsrp>,<sinr>,<rsrq>`
    ///
    /// 只认 `"LTE"` 那一行：换成 `"WCDMA"` / `"GSM"` 之后同样位置上摆的是另外
    /// 几个量，照 LTE 的公式换算会把 RSCP 当成 RSRP 报出去 —— 那比空着更糟。
    public static func mergeHCSQ(_ response: ATResponse, into status: inout SignalStatus) {
        guard let raw = response.firstValue(for: "^HCSQ") else { return }
        status.rawHCSQ = raw
        var parts = splitQuoted(raw)
        guard let rat = parts.first, rat.uppercased() == "LTE" else { return }
        parts.removeFirst()
        func value(_ index: Int) -> Int? {
            guard index < parts.count, let number = Int(parts[index]) else { return nil }
            return number
        }
        if let rssi = value(0), (0...31).contains(rssi) { status.rssiIndex = rssi }
        if let rsrp = value(1), (0...97).contains(rsrp) { status.rsrp = Double(-140 + rsrp) }
        if let sinr = value(2), (0...250).contains(sinr) { status.sinr = -20 + 0.2 * Double(sinr) }
        if let rsrq = value(3), (0...34).contains(rsrq) { status.rsrq = -19.5 + 0.5 * Double(rsrq) }
    }

    /// `AT+CPSI?` —— 芯讯（SIMCom）当前服务小区。
    ///
    /// `+CPSI: LTE,Online,460-11,0x…,…,EUTRAN-BAND3,…`
    ///
    /// 只抠制式和频段两格。这条命令的字段位置在不同固件版本之间**是会挪的**
    /// （频点一会儿在频段前面、一会儿在后面），照位置硬读会把小区号当成频点
    /// 显示出去。信号交给标准的 `AT+CESQ` —— 那条的位置是标准钉死的。
    public static func mergeCPSI(_ response: ATResponse, into status: inout NetworkStatus) {
        guard let raw = response.firstValue(for: "+CPSI") else { return }
        let parts = splitQuoted(raw)
        if let rat = parts.first, !rat.isEmpty, status.accessTechnology.isEmpty {
            status.accessTechnology = rat
        }
        for (index, field) in parts.enumerated() where field.uppercased().contains("BAND") {
            let upper = field.uppercased()
            guard let range = upper.range(of: "BAND") else { break }
            let tail = upper[range.upperBound...].prefix { $0.isNumber }
            if !tail.isEmpty, status.band.isEmpty {
                status.band = "\(parts.first?.uppercased() ?? "LTE") BAND \(tail)"
                // 频点：两种固件格式一个把频点摆在频段前面、一个摆在后面，
                // 只认紧挨着的那一个，隔着就不认。
                if index > 0, let before = Int(parts[index - 1]), before > 0 {
                    status.channel = before
                } else if index + 1 < parts.count, let after = Int(parts[index + 1]), after > 0 {
                    status.channel = after
                }
            }
            break
        }
    }

    /// `AT^SYSINFOEX` —— 华为报的制式。
    ///
    /// `^SYSINFOEX: 2,3,0,1,,6,"LTE","LTE",…`
    ///
    /// 只取里面那个带引号的名字，前面那串裸数字一概不认 —— 它们的位数各版本
    /// 不一样，照着读会把 `6` 当成制式。
    public static func mergeSYSINFOEX(_ response: ATResponse, into status: inout NetworkStatus) {
        guard status.accessTechnology.isEmpty,
              let raw = response.firstValue(for: "^SYSINFOEX") else { return }
        let quoted = splitQuoted(raw).filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) }
        guard let name = quoted.last else { return }
        let upper = name.uppercased()
        for known in ["LTE", "NR5G", "NR", "WCDMA", "HSPA", "GSM", "EDGE", "CDMA", "TD-SCDMA"]
        where upper.hasPrefix(known) {
            status.accessTechnology = known
            return
        }
    }

    /// 注册状态那一行里跟着的 `AcT` —— **这一格是通用的**。
    ///
    /// `+CEREG: <n>,<stat>[,[<tac>],[<ci>],[<AcT>]]`（TS 27.007 §7.2）
    ///
    /// 有了这一格，任何一块正经模块都能报出制式：不用 Quectel 的
    /// `AT+QNWINFO`，也不用华为的 `AT^SYSINFOEX`。频段和频点它不给 —— 那两格
    /// 只能留给厂家命令，给不出来就是 `--`，这是诚实的。
    public static func accessTechnology(fromRegistration response: ATResponse, prefix: String) -> String? {
        guard let raw = response.firstValue(for: prefix) else { return nil }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 5, let act = Int(parts[4]) else { return nil }
        return accessTechnologyName(act: act)
    }

    /// TS 27.007 §7.2 的 `AcT` 表。表里没有的就返回 nil —— 不猜。
    public static func accessTechnologyName(act: Int) -> String? {
        switch act {
        case 0, 1: return "GSM"
        case 2: return "WCDMA"
        case 3: return "EDGE"
        case 4, 5, 6: return "HSPA"
        case 7, 10, 13: return "LTE"
        case 8: return "EC-GSM"
        case 9: return "LTE-M"
        case 11, 12: return "NR5G"
        default: return nil
        }
    }

    // MARK: - Data / USB composition

    /// `+QCFG: "usbnet",0` → `0`; `+QCFG: "usbcfg",0x2CA3,0x4006,1,1,1,1,1,0,0` → the tail.
    public static func qcfgComposite(from response: ATResponse) -> USBComposition? {
        guard let raw = response.firstValue(for: "+QCFG") else { return nil }
        let parts = splitQuoted(raw)
        // name, vid, pid, diag, nmea, at, modem, network, adb, audio
        guard parts.count >= 10 else { return nil }
        func flag(_ index: Int) -> Bool {
            guard index < parts.count else { return false }
            return parts[index].trimmingCharacters(in: .whitespaces) == "1"
        }
        func hex(_ text: String) -> Int32? {
            let cleaned = text.trimmingCharacters(in: .whitespaces).lowercased()
            let body = cleaned.hasPrefix("0x") ? String(cleaned.dropFirst(2)) : cleaned
            return Int32(body, radix: 16)
        }
        guard let vid = hex(parts[1]), let pid = hex(parts[2]) else { return nil }
        return USBComposition(vendorID: vid,
                              productID: pid,
                              diag: flag(3),
                              nmea: flag(4),
                              atPort: flag(5),
                              modem: flag(6),
                              network: flag(7),
                              adb: flag(8),
                              audio: flag(9))
    }

    public static func usbnetMode(from response: ATResponse) -> Int? {
        guard let raw = response.firstValue(for: "+QCFG") else { return nil }
        let parts = splitQuoted(raw)
        guard let last = parts.last else { return nil }
        return Int(last.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Helpers

    static func value(afterColonIn line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return line }
        return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    /// Splits a comma list where fields may be double quoted.
    public static func splitQuoted(_ text: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if character == "," && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(character)
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    /// Pulls the APN out of a `+QICSGP` read response.
    ///
    /// The field list is not the same on every firmware. Quectel documents six
    /// fields — `<contextID>,<context_type>,<APN>,<username>,<password>,<auth>`
    /// — and the simulated module answers that way. The EG25-G inside the DJI
    /// module answers with five: `1,"CTNET","","",0`, the `context_type` field
    /// simply absent.
    ///
    /// So a fixed index is wrong on one firmware or the other. Reading `[2]`
    /// (the documented APN slot) on the real module returns the empty username
    /// instead, and every caller then reports "模块里还没有 APN" for a module
    /// that is at that moment routing traffic. The two layouts are told apart
    /// by length, which is the only thing that actually differs.
    public static func apnField(fromQICSGP raw: String) -> String? {
        let fields = splitQuoted(raw)
        guard fields.count >= 2 else { return nil }
        return fields.count >= 6 ? fields[2] : fields[1]
    }

    // MARK: - USSD

    /// 一条 `+CUSD` 上报（TS 27.007 §7.15）。
    ///
    /// 形状是 `+CUSD: <status>,"<text>",<dcs>`，三个字段都可能缺：`+CUSD: 2`
    /// 就是「会话被网络结束了」，后面一个字段都没有。
    public struct USSDReply: Equatable, Sendable {
        /// 0 = 还有后续（多步菜单，网络在等一个回答）；1 = 本次结束；
        /// 2 = 会话被结束（超时，或网络自己收摊）。
        public var status: Int
        /// 已经解出来的正文。
        public var text: String
        /// 网络给的编码，`72` 是 UCS2。
        public var dcs: Int
        /// 模块原样回的那一串。十六进制那种照样留着 —— 界面解不出来的时候，
        /// 这一串是唯一还能拿去查的东西。
        public var raw: String

        public var isComplete: Bool { status == 1 || status == 2 }

        public init(status: Int, text: String, dcs: Int, raw: String) {
            self.status = status
            self.text = text
            self.dcs = dcs
            self.raw = raw
        }
    }

    /// 认一行 `+CUSD`。不是这一条就返回 nil。
    public static func ussdReply(from line: String) -> USSDReply? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.uppercased().hasPrefix("+CUSD:") else { return nil }
        let body = String(trimmed.dropFirst("+CUSD:".count))
        let fields = splitQuoted(body)
        guard let first = fields.first,
              let status = Int(first.trimmingCharacters(in: .whitespaces)) else { return nil }
        let raw = fields.count > 1 ? fields[1] : ""
        let dcs = fields.count > 2 ? (Int(fields[2].trimmingCharacters(in: .whitespaces)) ?? 15) : 15
        return USSDReply(status: status, text: decodeUSD(raw, dcs: dcs), dcs: dcs, raw: raw)
    }

    /// 把 `+CUSD` 里那串字按 `<dcs>` 说的编码解出来。
    ///
    /// `15`（GSM 7 位默认表）一般是能直接读的 ASCII；`72`（UCS2）则是
    /// **用十六进制写的 UTF-16BE** —— 国内三家运营商全走后者，回的是
    /// `60A87684…` 这种。原样印出来，客户看到的就是一串十六进制。
    static func decodeUSD(_ text: String, dcs: Int) -> String {
        guard !text.isEmpty else { return "" }
        guard text.count % 4 == 0, text.allSatisfy({ $0.isHexDigit }) else { return text }
        guard let decoded = decodeUCS2Hex(text) else { return text }
        if [4, 8, 72].contains(dcs) { return decoded }
        // `<dcs>` 说不是 UCS2，可这一串又整整齐齐是十六进制 ——「1234」这种
        // 纯数字的余额本来也是这个长相。只有解出来带汉字才认它是编码过的，
        // 否则原样返回，免得把一句正常的数字答案解成乱码。
        return decoded.contains(where: { character in
            character.unicodeScalars.contains { $0.value >= 0x2E80 }
        }) ? decoded : text
    }

    /// 十六进制 → UTF-16BE。长度不对、碰上落单的代理项就返回 nil，
    /// 交给调用方原样显示 —— 猜错的乱码比原始那串十六进制更难查。
    static func decodeUCS2Hex(_ text: String) -> String? {
        guard text.count % 4 == 0, !text.isEmpty else { return nil }
        var scalars = String.UnicodeScalarView()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 4)
            guard let unit = UInt32(text[index..<next], radix: 16),
                  let scalar = Unicode.Scalar(unit) else { return nil }
            scalars.append(scalar)
            index = next
        }
        return String(scalars)
    }

    // MARK: - 选网

    /// `AT+COPS=?` 扫回来的一个运营商。
    public struct NetworkOperator: Equatable, Sendable, Identifiable {
        /// 0 未知、1 可用、2 当前、3 禁用。
        public var status: Int
        public var name: String
        public var shortName: String
        /// 五或六位 MCC+MNC，`46011` 这种。
        public var numeric: String

        public var id: String { numeric }
        public var isCurrent: Bool { status == 2 }
        /// 运营商把自己列成禁用：这台机器在这个位置注册不上它。
        public var isForbidden: Bool { status == 3 }
        public var label: String {
            if !name.isEmpty { return name }
            return shortName.isEmpty ? numeric : shortName
        }

        public init(status: Int, name: String, shortName: String, numeric: String) {
            self.status = status
            self.name = name
            self.shortName = shortName
            self.numeric = numeric
        }
    }

    /// 拆 `AT+COPS=?` 的应答。
    ///
    /// 一行里挤着好几组 `(2,"CHINA TELECOM","CT","46011")`，逗号相连；尾巴上
    /// 还会再挂两对括号 —— 那是「这台机器支持的频段」`(0-1)` 和「支持的制式」
    /// `(0,2)`。它们不是运营商，靠「凑不满四个字段」挡掉。
    public static func operators(fromCOPSScan response: ATResponse) -> [NetworkOperator] {
        guard let raw = response.firstValue(for: "+COPS") else { return [] }
        var found: [String: NetworkOperator] = [:]
        var index = raw.startIndex
        while let open = raw[index...].firstIndex(of: "(") {
            guard let close = raw[open...].firstIndex(of: ")") else { break }
            let inner = String(raw[raw.index(after: open)..<close])
            let fields = splitQuoted(inner)
            if fields.count >= 4,
               let status = Int(fields[0].trimmingCharacters(in: .whitespaces)),
               !fields[3].isEmpty,
               fields[3].allSatisfy({ $0.isNumber }) {
                let row = NetworkOperator(status: status, name: fields[1],
                                          shortName: fields[2], numeric: fields[3])
                // 同一家会在好几个制式上各出现一次，按号码合成一条：把「当前」
                // 那一档留下 —— 客户要认的是它。
                if let existing = found[row.numeric] {
                    if !existing.isCurrent, row.isCurrent { found[row.numeric] = row }
                } else {
                    found[row.numeric] = row
                }
            }
            index = raw.index(after: close)
        }
        return found.values.sorted { $0.numeric < $1.numeric }
    }
}

public struct USBComposition: Equatable {
    public var vendorID: Int32
    public var productID: Int32
    public var diag: Bool
    public var nmea: Bool
    public var atPort: Bool
    public var modem: Bool
    public var network: Bool
    public var adb: Bool
    public var audio: Bool

    public init(vendorID: Int32, productID: Int32,
                diag: Bool, nmea: Bool, atPort: Bool, modem: Bool,
                network: Bool, adb: Bool, audio: Bool) {
        self.vendorID = vendorID
        self.productID = productID
        self.diag = diag
        self.nmea = nmea
        self.atPort = atPort
        self.modem = modem
        self.network = network
        self.adb = adb
        self.audio = audio
    }

    public var hexIdentity: String { String(format: "%04X:%04X", vendorID, productID) }

    public var flags: [Bool] { [diag, nmea, atPort, modem, network, adb, audio] }

    public var flagString: String { flags.map { $0 ? "1" : "0" }.joined(separator: ",") }

    /// The audio flag is what makes the module enumerate as a USB audio device,
    /// which is the only way to get call audio on macOS without ADB plumbing.
    public var supportsVoice: Bool { audio }
}
