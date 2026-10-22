import Foundation
import CryptoKit

/// Quectel 工厂锁（`AT+QADBKEY`）解锁口令的推导。
///
/// 模块出厂时 ADB 是锁着的，不打开就没有 shell，也就 `insmod` 不进厂商的
/// 语音驱动 —— 而那是通话有声音的前提（见 `CallAudioBridge`）。解锁分两步：
///
///   `AT+QADBKEY?`        → `+QADBKEY: 27454934`（8 位挑战值）
///   `AT+QADBKEY="…"`     → `OK`（把这个挑战值算出来的口令交回去）
///
/// 口令的算法是公开的，**不是**这台机器特有的：标准 Unix MD5-crypt，密码固定
/// 为 `SH_adb_quectel`，盐就是那 8 位挑战值，取密文的前 15 个字符。
///
/// 所以这里老老实实算，而不是把本机试出来的口令写死。挑战值在同一个固件上
/// 是常量（本机重启、USB 重枚举之后都还是 `27454934`），但客户的模块是另一台
/// 机器，挑战值未必相同；写死等于「客户那台解不开，且不知道为什么」。
/// 自己算的另一个好处是不用管固件升级后挑战值变了怎么办。
///
/// 已核对：挑战值 `27454934` → `LWuf7OD1GJ1q/Lj`，与真机上解锁成功的口令一致。
public enum QADBKey {

    /// 厂商在固件里写死的那个口令字面量，别改。
    private static let password = "SH_adb_quectel"

    /// MD5-crypt 的字母表。注意**不是**标准 Base64：没有 `+`，顺序也不同。
    private static let alphabet = Array("./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// 挑战值是不是合法的 8 位数字。`AT+QADBKEY?` 正常就回这个形状。
    public static func isChallenge(_ text: String) -> Bool {
        text.count == 8 && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// 从 `AT+QADBKEY?` 回的挑战值算出要交回去的口令。挑战值不合法时返回 nil。
    ///
    /// 返回值只能用于本机对应的那台模块 —— 挑战值换了口令就得重算。
    public static func derive(challenge: String) -> String? {
        guard isChallenge(challenge) else { return nil }
        let encoded = md5Crypt(password: password, salt: challenge)
        guard encoded.count >= 15 else { return nil }
        return String(encoded.prefix(15))
    }

    // MARK: - MD5-crypt

    /// 标准 Unix MD5-crypt（`$1$`），返回 22 个字符的密文部分（不含 `$1$salt$`）。
    ///
    /// 直接照 RFC 里那份广为流传的伪代码实现：先拼初始块，再做 1000 轮混合。
    /// 每一轮拼进去的四段和数据顺序都不能动 —— 顺序错一位结果就完全不同，
    /// 而模块只会回一个 `ERROR`，不会告诉你哪里错了。
    static func md5Crypt(password: String, salt: String) -> String {
        let passwordBytes = Array(password.utf8)
        let saltBytes = Array(salt.utf8)

        // 初始块 = 密码 + "$1$" + 盐
        var initial = passwordBytes + Array("$1$".utf8) + saltBytes

        // 先把「密码 + 盐 + 密码」的摘要按密码长度补齐进去。
        let alternate = Array(md5(Array(passwordBytes + saltBytes + passwordBytes)))
        var remaining = passwordBytes.count
        while remaining > 0 {
            let take = min(remaining, alternate.count)
            initial.append(contentsOf: alternate[0..<take])
            remaining -= take
        }

        // 再按密码长度的二进制位补 0 或密码首字节。
        var bits = passwordBytes.count
        while bits > 0 {
            initial.append((bits & 1) == 1 ? 0 : passwordBytes[0])
            bits >>= 1
        }

        var digest = Array(md5(initial))

        // 1000 轮混合。
        for round in 0..<1000 {
            var block: [UInt8] = []
            block.append(contentsOf: (round & 1) == 1 ? passwordBytes : digest)
            if round % 3 != 0 { block.append(contentsOf: saltBytes) }
            if round % 7 != 0 { block.append(contentsOf: passwordBytes) }
            block.append(contentsOf: (round & 1) == 1 ? digest : passwordBytes)
            digest = Array(md5(block))
        }

        // 最后把 16 字节摘要按 3 字节一组编成 22 个字符。
        var encoded = ""
        encoded += base64From24(digest[0], digest[6], digest[12], count: 4)
        encoded += base64From24(digest[1], digest[7], digest[13], count: 4)
        encoded += base64From24(digest[2], digest[8], digest[14], count: 4)
        encoded += base64From24(digest[3], digest[9], digest[15], count: 4)
        encoded += base64From24(digest[4], digest[10], digest[5], count: 4)
        encoded += base64From24(0, 0, digest[11], count: 2)
        return encoded
    }

    /// 把 3 个字节当成一个 24 位数，每次取低 6 位编一个字符。
    private static func base64From24(_ high: UInt8, _ middle: UInt8, _ low: UInt8, count: Int) -> String {
        var value = (UInt32(high) << 16) | (UInt32(middle) << 8) | UInt32(low)
        var out = ""
        for _ in 0..<count {
            out.append(alphabet[Int(value & 0x3f)])
            value >>= 6
        }
        return out
    }

    private static func md5(_ bytes: [UInt8]) -> [UInt8] {
        Array(Insecure.MD5.hash(data: Data(bytes)))
    }
}
