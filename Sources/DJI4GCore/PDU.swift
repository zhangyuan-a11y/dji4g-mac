import Foundation

/// SMS alphabet selected inside TP-DCS.
public enum SMSAlphabet: String, Equatable {
    case gsm7
    case ucs2
    case eightBit

    public var label: String {
        switch self {
        case .gsm7: return "GSM 7-bit"
        case .ucs2: return "UCS-2"
        case .eightBit: return "8-bit"
        }
    }
}

/// One decoded short message. Concatenation is handled by `SMSService`, so the
/// fields describing the segment stay visible here.
public struct SMSMessage: Equatable {
    public var storageIndex: Int
    public var status: String
    public var sender: String
    public var text: String
    public var serviceCenter: String?
    public var timestamp: Date?
    public var alphabet: SMSAlphabet
    public var reference: Int?
    public var totalParts: Int?
    public var partIndex: Int?
    public var rawPDU: String
    /// 这条消息在模块里占了几格。单条是 1；长短信合并之后是段数（2 段就是 2 格）。
    ///
    /// 存在的理由只有一个：把「6 条」和「存储 7/40」这两个数对上。2026-09-26
    /// 真机上客户就是这么被绕住的 —— 小屏说 6 条，底下的存储说 7/40，中间那条
    /// 去哪了？查下来是 slot 3 和 slot 4 是同一组长短信（UDH ref 0x10，2 段），
    /// 合并成一条显示，所以「条数」比「格数」少 1。数据一条没丢，但界面上两个
    /// 数并排出现却对不上，等于逼客户怀疑自己漏看了一条短信。
    /// 记下占几格，界面就能把这两个口径讲清楚（见 `SMSDetail.storageNote`）。
    public var segmentCount: Int

    public init(storageIndex: Int = -1,
                status: String = "REC UNREAD",
                sender: String = "",
                text: String = "",
                serviceCenter: String? = nil,
                timestamp: Date? = nil,
                alphabet: SMSAlphabet = .gsm7,
                reference: Int? = nil,
                totalParts: Int? = nil,
                partIndex: Int? = nil,
                rawPDU: String = "",
                segmentCount: Int = 1) {
        self.storageIndex = storageIndex
        self.status = status
        self.sender = sender
        self.text = text
        self.serviceCenter = serviceCenter
        self.timestamp = timestamp
        self.alphabet = alphabet
        self.reference = reference
        self.totalParts = totalParts
        self.partIndex = partIndex
        self.rawPDU = rawPDU
        self.segmentCount = segmentCount
    }

    public var isUnread: Bool {
        status.uppercased().contains("UNREAD")
    }

    public var isConcatenated: Bool { reference != nil && (totalParts ?? 1) > 1 }
}

public enum PDUError: Error, CustomStringConvertible {
    case malformed(String)
    case tooLong(String)

    public var description: String {
        switch self {
        case .malformed(let detail): return "PDU 解析失败：\(detail)"
        case .tooLong(let detail): return "短信内容过长：\(detail)"
        }
    }
}

// MARK: - GSM 03.38 alphabet

enum GSMAlphabet {
    /// Table 3.38 default alphabet. Index is the septet value.
    static let basic: [Character] = Array(
        "@\u{00A3}$\u{00A5}\u{00E8}\u{00E9}\u{00F9}\u{00EC}\u{00F2}\u{00C7}\n\u{00D8}\u{00F8}\r\u{00C5}\u{00E5}" +
        "\u{0394}_\u{03A6}\u{0393}\u{039B}\u{03A9}\u{03A0}\u{03A8}\u{03A3}\u{0398}\u{039E}\u{001B}\u{00C6}\u{00E6}\u{00DF}\u{00C9}" +
        " !\"#\u{00A4}%&'()*+,-./" +
        "0123456789:;<=>?" +
        "\u{00A1}ABCDEFGHIJKLMNOPQRSTUVWXYZ\u{00C4}\u{00D6}\u{00D1}\u{00DC}\u{00A7}" +
        "\u{00BF}abcdefghijklmnopqrstuvwxyz\u{00E4}\u{00F6}\u{00F1}\u{00FC}\u{00E0}"
    )

    /// Extension table (the characters reachable through the 0x1B escape).
    static let extensionMap: [UInt8: Character] = [
        0x0A: "\u{0C}", 0x14: "^", 0x28: "{", 0x29: "}", 0x2F: "\\",
        0x3C: "[", 0x3D: "~", 0x3E: "]", 0x40: "|", 0x65: "\u{20AC}"
    ]

    static let reverseBasic: [Character: UInt8] = {
        var map: [Character: UInt8] = [:]
        for (index, character) in basic.enumerated() where character != "\u{001B}" {
            if map[character] == nil { map[character] = UInt8(index) }
        }
        return map
    }()

    static let reverseExtension: [Character: UInt8] = {
        var map: [Character: UInt8] = [:]
        for (septet, character) in extensionMap { map[character] = septet }
        return map
    }()

    static let maxSeptets = 160

    /// Septets required to encode `text`, or nil when a character has no
    /// representation in the default alphabet.
    static func septetCount(_ text: String) -> Int? {
        var count = 0
        for character in text {
            if reverseBasic[character] != nil {
                count += 1
            } else if reverseExtension[character] != nil {
                count += 2
            } else {
                return nil
            }
        }
        return count
    }
}

// MARK: - Septet packing

enum Septet {
    /// Packs septets LSB-first into octets. `fillBits` are zero bits emitted
    /// before the first septet — they exist because a user data header is not
    /// a whole number of septets wide.
    static func pack(_ septets: [UInt8], fillBits: Int = 0) -> [UInt8] {
        var output: [UInt8] = []
        var accumulator: UInt32 = 0
        var bitCount = fillBits
        for septet in septets {
            accumulator |= UInt32(septet & 0x7F) << UInt32(bitCount)
            bitCount += 7
            while bitCount >= 8 {
                output.append(UInt8(accumulator & 0xFF))
                accumulator >>= 8
                bitCount -= 8
            }
        }
        if bitCount > 0 { output.append(UInt8(accumulator & 0xFF)) }
        return output
    }

    /// Reads `count` septets starting `skipBits` bits into the payload. A
    /// truncated payload is padded with zero septets instead of failing, which
    /// matches how a handset renders a damaged message.
    static func unpack(_ octets: [UInt8], count: Int, skipBits: Int = 0) -> [UInt8] {
        guard count > 0 else { return [] }
        var septets: [UInt8] = []
        septets.reserveCapacity(count)
        var bitPosition = skipBits
        for _ in 0..<count {
            var value: UInt32 = 0
            for offset in 0..<7 {
                let position = bitPosition + offset
                let byteIndex = position >> 3
                guard byteIndex < octets.count else { break }
                let bit = (octets[byteIndex] >> UInt8(position & 7)) & 1
                value |= UInt32(bit) << UInt32(offset)
            }
            septets.append(UInt8(value & 0x7F))
            bitPosition += 7
        }
        return septets
    }

    /// Interprets septets as GSM 7-bit text, honouring 0x1B escapes.
    static func decodeText(_ septets: [UInt8]) -> String {
        var characters = String.UnicodeScalarView()
        var index = 0
        while index < septets.count {
            let septet = septets[index]
            if septet == 0x1B, index + 1 < septets.count,
               let escaped = GSMAlphabet.extensionMap[septets[index + 1]] {
                characters.append(escaped.unicodeScalars.first!)
                index += 2
                continue
            }
            let scalarIndex = Int(septet)
            if scalarIndex < GSMAlphabet.basic.count {
                let character = GSMAlphabet.basic[scalarIndex]
                if let scalar = character.unicodeScalars.first {
                    characters.append(scalar)
                }
            } else {
                characters.append(" ")
            }
            index += 1
        }
        return String(characters)
    }

    static func encodeText(_ text: String) throws -> [UInt8] {
        var septets: [UInt8] = []
        for character in text {
            if let basic = GSMAlphabet.reverseBasic[character] {
                septets.append(basic)
            } else if let escaped = GSMAlphabet.reverseExtension[character] {
                septets.append(0x1B)
                septets.append(escaped)
            } else {
                throw PDUError.malformed("字符 \(character) 不在 GSM 7-bit 字符集中")
            }
        }
        return septets
    }
}

// MARK: - Addresses

enum BCD {
    /// `+8613800138000` → ToA 0x91 plus swapped semi-octets.
    static func encodeAddress(_ number: String) -> (toa: UInt8, digits: [UInt8], length: Int)? {
        var digitsOnly = number.trimmingCharacters(in: .whitespaces)
        var toa: UInt8 = 0x81
        if digitsOnly.hasPrefix("+") {
            toa = 0x91
            digitsOnly.removeFirst()
        } else if digitsOnly.hasPrefix("00") {
            toa = 0x91
            digitsOnly.removeFirst(2)
        }
        digitsOnly = digitsOnly.filter { $0.isNumber || $0 == "*" || $0 == "#" || $0 == "a" || $0 == "b" || $0 == "c" }
        guard !digitsOnly.isEmpty, digitsOnly.count <= 20 else { return nil }

        var semioctets: [UInt8] = []
        for character in digitsOnly {
            let value: UInt8
            switch character {
            case "*": value = 0x0A
            case "#": value = 0x0B
            case "a": value = 0x0C
            case "b": value = 0x0D
            case "c": value = 0x0E
            default:
                guard let digit = character.wholeNumberValue else { return nil }
                value = UInt8(digit)
            }
            semioctets.append(value)
        }
        if semioctets.count % 2 == 1 { semioctets.append(0x0F) }

        var packed: [UInt8] = []
        var index = 0
        while index < semioctets.count {
            packed.append((semioctets[index + 1] << 4) | semioctets[index])
            index += 2
        }
        return (toa, packed, digitsOnly.count)
    }

    /// Decodes TP-OA / TP-DA. Returns the printable number and the length in
    /// semi-octets so the caller can advance past it.
    static func decodeAddress(_ bytes: [UInt8], at offset: Int) throws -> (number: String, semiOctets: Int, next: Int) {
        guard offset < bytes.count else { throw PDUError.malformed("地址越界") }
        let semiOctets = Int(bytes[offset])
        let toaIndex = offset + 1
        guard toaIndex < bytes.count else { throw PDUError.malformed("缺少 ToA") }
        let toa = bytes[toaIndex]
        let octetCount = (semiOctets + 1) / 2
        let digitStart = toaIndex + 1
        guard digitStart + octetCount <= bytes.count else { throw PDUError.malformed("地址字段被截断") }

        let payload = Array(bytes[digitStart..<(digitStart + octetCount)])
        let ton = (toa >> 4) & 0x07

        if ton == 5 {
            // Alphanumeric sender: the octets are packed GSM 7-bit text.
            let septets = Septet.unpack(payload, count: (semiOctets * 4) / 7)
            return (Septet.decodeText(septets), semiOctets, digitStart + octetCount)
        }

        var digits = ""
        for octet in payload {
            let low = octet & 0x0F
            let high = (octet >> 4) & 0x0F
            if low != 0x0F { digits.append(Self.digitCharacter(low)) }
            if high != 0x0F { digits.append(Self.digitCharacter(high)) }
        }
        if digits.count > semiOctets { digits = String(digits.prefix(semiOctets)) }

        let prefix = (ton == 1) ? "+" : ""
        return (prefix + digits, semiOctets, digitStart + octetCount)
    }

    private static func digitCharacter(_ value: UInt8) -> Character {
        switch value {
        case 0...9: return Character(String(value))
        case 0x0A: return "*"
        case 0x0B: return "#"
        case 0x0C: return "a"
        case 0x0D: return "b"
        case 0x0E: return "c"
        default: return "?"
        }
    }
}

// MARK: - Time stamps

public enum SMSTimestamp {
    /// TP-SCTS: swapped BCD, 7 octets, local time with a quarter-hour offset.
    /// As in TP-Address, the *first* digit of a pair sits in the low nibble:
    /// "26" is encoded as 0x62, so the low nibble is the tens digit.
    public static func decode(_ bytes: [UInt8]) -> Date? {
        guard bytes.count >= 7 else { return nil }
        func value(_ index: Int) -> Int {
            let octet = bytes[index]
            let tens = Int(octet & 0x0F)
            let units = Int((octet >> 4) & 0x0F)
            return tens * 10 + units
        }
        let year = value(0)
        let month = value(1)
        let day = value(2)
        let hour = value(3)
        let minute = value(4)
        let second = value(5)
        // Bit 3 of this octet carries the sign, so it is excluded from the
        // tens digit; the high nibble holds the units of quarters of an hour.
        let offsetByte = bytes[6]
        let offsetTens = Int(offsetByte & 0x07)
        let offsetUnits = Int((offsetByte >> 4) & 0x07)
        var offsetQuarters = offsetTens * 10 + offsetUnits
        if offsetByte & 0x08 != 0 { offsetQuarters = -offsetQuarters }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offsetQuarters * 900) ?? .current
        var components = DateComponents()
        components.year = year >= 90 ? 1900 + year : 2000 + year
        components.month = max(1, month)
        components.day = max(1, day)
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)
    }
}

// MARK: - Decoding

public enum PDUCodec {
    public static func bytes(fromHex hex: String) throws -> [UInt8] {
        let cleaned = hex.filter { $0.isHexDigit }
        guard cleaned.count % 2 == 0 else { throw PDUError.malformed("十六进制长度为奇数") }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let value = UInt8(cleaned[index..<next], radix: 16) else {
                throw PDUError.malformed("非法十六进制字符")
            }
            bytes.append(value)
            index = next
        }
        return bytes
    }

    public static func hex(from bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    static func alphabet(forDCS dcs: UInt8) -> SMSAlphabet {
        if dcs & 0xC0 == 0x00 {
            switch (dcs >> 2) & 0x03 {
            case 0: return .gsm7
            case 1: return .eightBit
            default: return .ucs2
            }
        }
        if dcs & 0xF0 == 0xF0 { return .gsm7 }
        if dcs & 0xF0 == 0xC0 || dcs & 0xF0 == 0xD0 { return .gsm7 }
        if dcs & 0xF0 == 0xE0 { return .ucs2 }
        return .gsm7
    }

    /// 一段 8-bit 消息体像不像「根本不是文字」。
    ///
    /// 判据只有两条，都对准运营商下发的那种二进制短消息：UTF-8 解出替换字符
    /// （说明它压根不是 UTF-8），或者可打印字符不到一半（说明里面塞的是控制
    /// 字节和长度前缀）。余量留给真正的文本 —— 能当 8-bit 文本发出来的东西，
    /// UTF-8 一定解得干净，也一定都是可打印字符。
    static func looksBinary(_ body: [UInt8]) -> Bool {
        guard !body.isEmpty else { return false }
        let decoded = String(decoding: body, as: UTF8.self)
        if decoded.range(of: "\u{FFFD}") != nil { return true }
        var printable = 0
        var total = 0
        for scalar in decoded.unicodeScalars {
            total += 1
            let value = scalar.value
            if value == 0x0A || value == 0x0D || value == 0x09 { printable += 1; continue }
            if value >= 0x20, value != 0x7F { printable += 1 }
        }
        return total > 0 && printable * 2 < total
    }

    /// Decodes one SMS-DELIVER PDU (the shape `AT+CMGL=4` returns).
    public static func decodeDeliver(_ pdu: String, storageIndex: Int = -1, status: String = "REC UNREAD") throws -> SMSMessage {
        let bytes = try bytes(fromHex: pdu)
        var cursor = 0
        guard !bytes.isEmpty else { throw PDUError.malformed("空 PDU") }

        let scaLen = Int(bytes[0])
        cursor = 1 + scaLen
        let serviceCenter: String? = scaLen > 0
            ? decodeServiceCenter(Array(bytes[1..<min(bytes.count, 1 + scaLen)]))
            : nil

        guard cursor < bytes.count else { throw PDUError.malformed("缺少首字节") }
        let firstOctet = bytes[cursor]; cursor += 1
        let mti = firstOctet & 0x03
        guard mti == 0 else { throw PDUError.malformed("不是 SMS-DELIVER（MTI=\(mti)）") }
        let hasUDHI = (firstOctet & 0x40) != 0

        let address = try BCD.decodeAddress(bytes, at: cursor)
        cursor = address.next

        guard cursor + 1 < bytes.count else { throw PDUError.malformed("缺少 PID/DCS") }
        _ = bytes[cursor]; cursor += 1              // TP-PID
        let dcs = bytes[cursor]; cursor += 1        // TP-DCS

        guard cursor + 7 <= bytes.count else { throw PDUError.malformed("缺少时间戳") }
        let timestamp = SMSTimestamp.decode(Array(bytes[cursor..<(cursor + 7)]))
        cursor += 7

        guard cursor < bytes.count else { throw PDUError.malformed("缺少 UDL") }
        let udl = Int(bytes[cursor]); cursor += 1
        let userData = Array(bytes[min(cursor, bytes.count)...])
        let body = decodeUserData(userData, dcs: dcs, hasUDHI: hasUDHI, udl: udl)

        return SMSMessage(storageIndex: storageIndex,
                          status: status,
                          sender: address.number,
                          text: body.text,
                          serviceCenter: serviceCenter,
                          timestamp: timestamp,
                          alphabet: body.alphabet,
                          reference: body.reference,
                          totalParts: body.total,
                          partIndex: body.part,
                          rawPDU: pdu)
    }

    /// Decodes one SMS-SUBMIT PDU. Sent messages live in the module's "MT"
    /// storage as SUBMIT PDUs (`AT+CMGL=4` returns them with status "STO SENT"),
    /// so the receive path has to understand both directions.
    public static func decodeSubmit(_ pdu: String,
                                    storageIndex: Int = -1,
                                    status: String = "STO SENT") throws -> SMSMessage {
        let bytes = try bytes(fromHex: pdu)
        guard !bytes.isEmpty else { throw PDUError.malformed("空 PDU") }
        let scaLen = Int(bytes[0])
        var cursor = 1 + scaLen
        let serviceCenter = scaLen > 0 ? decodeServiceCenter(Array(bytes[1..<min(bytes.count, 1 + scaLen)])) : nil

        guard cursor < bytes.count else { throw PDUError.malformed("缺少首字节") }
        let firstOctet = bytes[cursor]; cursor += 1
        let mti = firstOctet & 0x03
        guard mti == 1 else { throw PDUError.malformed("不是 SMS-SUBMIT（MTI=\(mti)）") }
        let hasUDHI = (firstOctet & 0x40) != 0

        guard cursor < bytes.count else { throw PDUError.malformed("缺少 TP-MR") }
        cursor += 1                                   // TP-MR

        let address = try BCD.decodeAddress(bytes, at: cursor)
        cursor = address.next

        guard cursor + 1 < bytes.count else { throw PDUError.malformed("缺少 PID/DCS") }
        _ = bytes[cursor]; cursor += 1                // TP-PID
        let dcs = bytes[cursor]; cursor += 1          // TP-DCS

        // TP-VP: its width depends on the TP-VPF bits of the first octet.
        let validityFormat = (firstOctet >> 3) & 0x03
        switch validityFormat {
        case 1: cursor += 1
        case 2: cursor += 7
        default: break                                 // 0 = none, 3 = reserved/none
        }
        guard cursor < bytes.count else { throw PDUError.malformed("缺少 UDL") }

        let udl = Int(bytes[cursor]); cursor += 1
        let userData = Array(bytes[min(cursor, bytes.count)...])
        let body = decodeUserData(userData, dcs: dcs, hasUDHI: hasUDHI, udl: udl)

        return SMSMessage(storageIndex: storageIndex,
                          status: status,
                          sender: address.number,
                          text: body.text,
                          serviceCenter: serviceCenter,
                          timestamp: nil,
                          alphabet: body.alphabet,
                          reference: body.reference,
                          totalParts: body.total,
                          partIndex: body.part,
                          rawPDU: pdu)
    }

    /// Decodes a PDU without knowing whether it is a DELIVER or a SUBMIT.
    public static func decode(_ pdu: String,
                              storageIndex: Int = -1,
                              status: String = "REC UNREAD") throws -> SMSMessage {
        let bytes = try bytes(fromHex: pdu)
        guard !bytes.isEmpty else { throw PDUError.malformed("空 PDU") }
        let scaLen = Int(bytes[0])
        let first = 1 + scaLen
        guard first < bytes.count else { throw PDUError.malformed("缺少首字节") }
        switch bytes[first] & 0x03 {
        case 0: return try decodeDeliver(pdu, storageIndex: storageIndex, status: status)
        case 1: return try decodeSubmit(pdu, storageIndex: storageIndex,
                                        status: status == "REC UNREAD" ? "STO SENT" : status)
        default: throw PDUError.malformed("不支持的 MTI=\(bytes[first] & 0x03)")
        }
    }

    struct UserData {
        var text: String
        var alphabet: SMSAlphabet
        var reference: Int?
        var total: Int?
        var part: Int?
    }

    /// Shared TP-UD decoder: both DELIVER and SUBMIT carry the same alphabet
    /// encodings and the same concatenation header.
    static func decodeUserData(_ userData: [UInt8], dcs: UInt8, hasUDHI: Bool, udl: Int) -> UserData {
        let alphabet = alphabet(forDCS: dcs)
        var reference: Int?
        var total: Int?
        var part: Int?
        var text = ""

        switch alphabet {
        case .gsm7:
            var skipBits = 0
            var headerSeptets = 0
            if hasUDHI, let header = parseHeader(userData, septets: true) {
                reference = header.reference
                total = header.total
                part = header.part
                headerSeptets = header.septetLength
                skipBits = header.octetBits + header.fillBits
            }
            let septetCount = max(0, udl - headerSeptets)
            let septets = Septet.unpack(userData, count: septetCount, skipBits: skipBits)
            text = Septet.decodeText(septets)
        case .ucs2:
            var headerOctets = 0
            if hasUDHI, let header = parseHeader(userData, septets: false) {
                reference = header.reference
                total = header.total
                part = header.part
                headerOctets = header.octetLength
            }
            let payload = Array(userData.dropFirst(headerOctets))
            let bodyOctets = min(max(0, udl - headerOctets), payload.count)
            text = String(data: Data(payload.prefix(bodyOctets)), encoding: .utf16BigEndian)
                ?? String(decoding: payload.prefix(bodyOctets), as: UTF8.self)
        case .eightBit:
            var headerOctets = 0
            if hasUDHI, let header = parseHeader(userData, septets: false) {
                reference = header.reference
                total = header.total
                part = header.part
                headerOctets = header.octetLength
            }
            let payload = Array(userData.dropFirst(headerOctets))
            let bodyOctets = min(max(0, udl - headerOctets), payload.count)
            let body = Array(payload.prefix(bodyOctets))
            // 2026-09-26 加：这一支以前直接
            //     text = String(decoding: body, as: UTF8.self)
            // 交出去，而 `String(decoding:)` 是**永远不会失败**的那个 API ——
            // 解不通的字节它一个不落地换成 U+FFFD 交回来。于是运营商下发的
            // 数据短信在客户的短信列表里长这样：
            //     Encoding-Version 1.4 ���Ҍ��JaRqFiDDQAA … http://10.234…
            // （2026-09-26 真机 `AT+CMGR=7` 抓到的那条中国电信消息：DCS=0x04、
            //   UDH 里目的端口 0x0B84＝2948，是标准的 WAP 推送二进制短消息。）
            // 这不是罕见样本：运营商定期下发这类消息，客户第一次打开短信页
            // 就会看到它，然后以为这个功能是坏的。
            text = Self.looksBinary(body)
                ? "（数据短信，无法显示为文字）"
                : String(decoding: body, as: UTF8.self)
        }

        return UserData(text: text, alphabet: alphabet,
                        reference: reference, total: total, part: part)
    }

    /// Service centre address as it appears in the SCA field of a PDU.
    static func decodeServiceCenter(_ scaBytes: [UInt8]) -> String {
        var digits = ""
        var hasPrefix = false
        for (index, octet) in scaBytes.enumerated() {
            let ton = (octet >> 4) & 0x07
            if index == 0 { if ton == 1 { hasPrefix = true }; continue }
            let low = octet & 0x0F
            let high = (octet >> 4) & 0x0F
            if low != 0x0F { digits.append(String(low)) }
            if high != 0x0F { digits.append(String(high)) }
        }
        return (hasPrefix ? "+" : "") + digits
    }

    struct Header {
        var reference: Int?
        var total: Int?
        var part: Int?
        /// Header length in octets, including the UDHL byte itself.
        var octetLength: Int
        /// Header length rounded up to whole septets.
        var septetLength: Int

        var octetBits: Int { octetLength * 8 }
        /// Zero bits needed to pad the header out to a septet boundary.
        var fillBits: Int { septetLength * 7 - octetBits }
    }

    static func parseHeader(_ userData: [UInt8], septets: Bool) -> Header? {
        guard userData.count >= 1 else { return nil }
        let udhl = Int(userData[0])
        guard udhl > 0, userData.count >= 1 + udhl else { return nil }
        var result = Header(reference: nil, total: nil, part: nil,
                            octetLength: 1 + udhl, septetLength: 0)
        if septets {
            let bits = (1 + udhl) * 8
            result.septetLength = (bits + 6) / 7
        }
        var index = 1
        while index + 1 < 1 + udhl {
            let elementId = userData[index]
            let length = Int(userData[index + 1])
            let bodyStart = index + 2
            guard bodyStart + length <= userData.count else { break }
            if elementId == 0x00, length >= 3 {
                // 8-bit reference: [ref][total][part]
                result.reference = Int(userData[bodyStart])
                result.total = Int(userData[bodyStart + 1])
                result.part = Int(userData[bodyStart + 2])
            } else if elementId == 0x08, length >= 4 {
                // 16-bit reference: [ref hi][ref lo][total][part]
                result.reference = Int(userData[bodyStart + 1]) << 8 | Int(userData[bodyStart + 2])
                result.total = Int(userData[bodyStart + 3])
                result.part = length >= 5 ? Int(userData[bodyStart + 4]) : nil
            }
            index = bodyStart + length
        }
        return result
    }
}

// MARK: - Encoding

/// Builds SMS-DELIVER PDUs. The module never needs this to run, but it makes
/// the decoder testable and lets the built-in simulator replay real traffic.
public enum PDUDeliver {

    public static func encode(text: String,
                             from sender: String,
                             timestamp: Date = Date(),
                             reference: UInt8? = nil,
                             total: UInt8 = 1,
                             part: UInt8 = 1,
                             alphabet requestedAlphabet: SMSAlphabet = .gsm7) throws -> String {
        guard let address = BCD.encodeAddress(sender) else {
            throw PDUError.malformed("发件人号码不合法：\(sender)")
        }

        var alphabet = requestedAlphabet
        if alphabet == .gsm7, GSMAlphabet.septetCount(text) == nil {
            alphabet = .ucs2
        }

        var header: [UInt8] = []
        if total > 1 {
            header = [0x05, 0x00, 0x03, reference ?? 0x42, total, part]
        }

        var bytes: [UInt8] = [0x00]                 // default service centre
        bytes.append(header.isEmpty ? 0x04 : 0x44)  // SMS-DELIVER (+ UDHI)
        bytes.append(UInt8(address.length))
        bytes.append(address.toa)
        bytes.append(contentsOf: address.digits)
        bytes.append(0x00)                          // TP-PID

        switch alphabet {
        case .gsm7:
            bytes.append(0x00)
            bytes.append(contentsOf: encodeTimestamp(timestamp))
            let septets = try Septet.encodeText(text)
            if header.isEmpty {
                bytes.append(UInt8(septets.count))
                bytes.append(contentsOf: Septet.pack(septets))
            } else {
                let limits = PDUSubmit.limits(octetCount: header.count)
                bytes.append(UInt8(limits.septets + septets.count))
                bytes.append(contentsOf: PDUSubmit.packWithHeader(header: header,
                                                                  septets: septets,
                                                                  fillBits: limits.fillBits))
            }
        case .ucs2:
            let payload = Array(text.data(using: .utf16BigEndian) ?? Data())
            bytes.append(0x08)
            bytes.append(contentsOf: encodeTimestamp(timestamp))
            bytes.append(UInt8(header.count + payload.count))
            bytes.append(contentsOf: header)
            bytes.append(contentsOf: payload)
        case .eightBit:
            let payload = Array(text.data(using: .utf8) ?? Data())
            bytes.append(0x04)
            bytes.append(contentsOf: encodeTimestamp(timestamp))
            bytes.append(UInt8(header.count + payload.count))
            bytes.append(contentsOf: header)
            bytes.append(contentsOf: payload)
        }

        return PDUCodec.hex(from: bytes)
    }

    public static func encodeTimestamp(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let zone = TimeZone.current.secondsFromGMT(for: date) / 900
        func swapped(_ value: Int) -> UInt8 {
            let clamped = max(0, value)
            return UInt8(((clamped % 10) << 4) | ((clamped / 10) % 10))
        }
        let year = (components.year ?? 2025) % 100
        var octets: [UInt8] = [
            swapped(year), swapped(components.month ?? 1), swapped(components.day ?? 1),
            swapped(components.hour ?? 0), swapped(components.minute ?? 0), swapped(components.second ?? 0)
        ]
        let magnitude = abs(zone)
        var zoneOctet = UInt8(((magnitude % 10) << 4) | ((magnitude / 10) % 10))
        if zone < 0 { zoneOctet |= 0x08 }
        octets.append(zoneOctet)
        return octets
    }
}

public enum PDUSubmit {
    /// Builds an SMS-SUBMIT PDU string (without the trailing Ctrl-Z).
    /// Long text is split into concatenated 8-bit reference segments.
    public static func encode(text: String,
                              to number: String,
                              serviceCenter: String? = nil,
                              reference: Int? = nil,
                              requestStatusReport: Bool = false) throws -> [String] {
        guard let address = BCD.encodeAddress(number) else {
            throw PDUError.malformed("号码不合法：\(number)")
        }

        var sca: [UInt8] = []
        if let serviceCenter, !serviceCenter.isEmpty,
           let center = BCD.encodeAddress(serviceCenter) {
            sca.append(UInt8(center.length + 1))
            sca.append(center.toa)
            sca.append(contentsOf: center.digits)
        } else {
            sca.append(0x00)
        }

        let concatenationReference = UInt8((reference ?? Int.random(in: 1...254)) & 0xFF)
        let sevenBitFitsAll = (GSMAlphabet.septetCount(text) ?? Int.max) <= GSMAlphabet.maxSeptets
        let ucsFitsAll = text.utf16.count <= 70

        if sevenBitFitsAll || ucsFitsAll {
            let single = try encodeSegment(text: text, to: address,
                                           sca: sca,
                                           requestStatusReport: requestStatusReport,
                                           header: nil,
                                           alphabet: sevenBitFitsAll ? .gsm7 : .ucs2)
            return [single]
        }

        let usesGSM7 = GSMAlphabet.septetCount(text) != nil
        let segments = split(text, sevenBit: usesGSM7)
        guard segments.count <= 255 else { throw PDUError.tooLong("超过 255 段") }

        var pdus: [String] = []
        for (offset, segment) in segments.enumerated() {
            let header = PDUConcatHeader(reference: concatenationReference,
                                         total: UInt8(segments.count),
                                         part: UInt8(offset + 1))
            pdus.append(try encodeSegment(text: segment, to: address,
                                          sca: sca,
                                          requestStatusReport: requestStatusReport,
                                          header: header,
                                          alphabet: usesGSM7 ? .gsm7 : .ucs2))
        }
        return pdus
    }

    /// Septet width of a user data header of a given octet length.
    struct PDUHeaderLimits {
        var octets: Int
        var septets: Int
        var fillBits: Int
    }

    static func limits(octetCount: Int) -> PDUHeaderLimits {
        let septets = (octetCount * 8 + 6) / 7
        return PDUHeaderLimits(octets: octetCount, septets: septets,
                               fillBits: septets * 7 - octetCount * 8)
    }

    struct PDUConcatHeader {
        var reference: UInt8
        var total: UInt8
        var part: UInt8

        var octets: [UInt8] {
            [0x05, 0x00, 0x03, reference, total, part]
        }
    }

    /// Splits text so every segment still fits once the 6-octet concatenation
    /// header is present (153 septets / 67 UCS-2 characters).
    static func split(_ text: String, sevenBit: Bool) -> [String] {
        if sevenBit {
            var segments: [String] = []
            var current = ""
            var currentSeptets = 0
            for character in text {
                let cost = GSMAlphabet.reverseExtension[character] != nil ? 2 : 1
                if currentSeptets + cost > 153 {
                    segments.append(current)
                    current = ""
                    currentSeptets = 0
                }
                current.append(character)
                currentSeptets += cost
            }
            if !current.isEmpty { segments.append(current) }
            return segments.isEmpty ? [""] : segments
        }

        var segments: [String] = []
        var current = ""
        var currentUnits = 0
        for character in text {
            let units = character.utf16.count
            if currentUnits + units > 67 {
                segments.append(current)
                current = ""
                currentUnits = 0
            }
            current.append(character)
            currentUnits += units
        }
        if !current.isEmpty { segments.append(current) }
        return segments.isEmpty ? [""] : segments
    }

    static func encodeSegment(text: String,
                              to address: (toa: UInt8, digits: [UInt8], length: Int),
                              sca: [UInt8],
                              requestStatusReport: Bool,
                              header: PDUConcatHeader?,
                              alphabet: SMSAlphabet) throws -> String {
        var bytes = sca
        var firstOctet: UInt8 = 0x01                 // SMS-SUBMIT, no validity period
        if requestStatusReport { firstOctet |= 0x20 }
        if header != nil { firstOctet |= 0x40 }      // TP-UDHI
        bytes.append(firstOctet)
        bytes.append(0x00)                            // TP-MR
        bytes.append(UInt8(address.length))
        bytes.append(address.toa)
        bytes.append(contentsOf: address.digits)
        bytes.append(0x00)                            // TP-PID

        let headerOctets = header?.octets ?? []

        switch alphabet {
        case .gsm7:
            let septets = try Septet.encodeText(text)
            bytes.append(0x00)                        // TP-DCS: 7-bit
            if headerOctets.isEmpty {
                bytes.append(UInt8(septets.count))    // TP-UDL in septets
                bytes.append(contentsOf: Septet.pack(septets))
            } else {
                let header = limits(octetCount: headerOctets.count)
                bytes.append(UInt8(header.septets + septets.count))
                bytes.append(contentsOf: packWithHeader(header: headerOctets,
                                                        septets: septets,
                                                        fillBits: header.fillBits))
            }
        case .ucs2:
            let payload = Array(text.data(using: .utf16BigEndian) ?? Data())
            bytes.append(0x08)                        // TP-DCS: UCS-2
            bytes.append(UInt8(headerOctets.count + payload.count))
            bytes.append(contentsOf: headerOctets)
            bytes.append(contentsOf: payload)
        case .eightBit:
            let payload = Array(text.data(using: .utf8) ?? Data())
            bytes.append(0x04)
            bytes.append(UInt8(headerOctets.count + payload.count))
            bytes.append(contentsOf: headerOctets)
            bytes.append(contentsOf: payload)
        }

        return PDUCodec.hex(from: bytes)
    }

    /// GSM 7-bit user data that starts with a header: the header occupies whole
    /// octets, the rest is packed after `fillBits` padding.
    /// A header followed by septets that begin `fillBits` past the byte
    /// boundary the header ends on.
    static func packWithHeader(header: [UInt8], septets: [UInt8], fillBits: Int) -> [UInt8] {
        guard !header.isEmpty else { return Septet.pack(septets) }
        return header + Septet.pack(septets, fillBits: fillBits)
    }
}
