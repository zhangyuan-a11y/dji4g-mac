import Foundation

/// Turns the module's error results into the sentence a person needs.
///
/// A raw `+CME ERROR: 10` only helps someone who has the 3GPP table memorised,
/// and the codes that actually show up here are boringly consistent: the card is
/// not in, the card is locked, or the module has not registered yet. Saying so
/// directly is the difference between "坏了" and "卡没插好".
public enum ATFailure {
    /// Nil when the result is not a failure worth explaining.
    public static func explain(_ final: ATFinal) -> String? {
        switch final {
        case .cme(let code): return cme(code)
        case .cms(let code): return cms(code)
        case .error:
            return "模块回了 ERROR：这条命令现在不被接受（卡没插好或没注册到网络时最常见）"
        case .timeout:
            return "模块没有在超时前回复：串口可能被别的程序占着，或模块正在重启"
        case .closed:
            return "串口已断开：模块被拔掉，或正在重启"
        case .other(let value):
            switch value {
            case "NO DIALTONE": return "没有拨号音：模块没有注册到网络，或天线没接好"
            case "BUSY": return "对方忙"
            case "NO ANSWER": return "对方没有接听"
            case "NO CARRIER": return "通话已断开"
            default: return "模块回了 \(value)"
            }
        default:
            return nil
        }
    }

    /// USSD 失败时的话。
    ///
    /// 为什么不能直接套 `cme(_:)`：`+CME ERROR: 30` 在通话那边是「还没注册
    /// 到网络」，在 USSD 这边却是另一件事 —— 2026-09-28 在真机上按到过：数据
    /// 通着、通话也能打，`AT+CUSD=1,"*100#",15` 照样回 30。原因在
    /// `AT+CREG?` 那一行：`0,3` 是**电路域**注册被拒，而 USSD 是走电路域的业务。
    /// 拿通话那句话去解释，客户会以为是自己没插好卡，然后一直重试。
    public static func explainUSSD(_ final: ATFinal) -> String? {
        switch final {
        case .cme(30):
            return "当前网络没有给语音通道，查话费这类业务用不了（换张卡或换个网络再试）"
        case .cme(50):
            return "模块报参数不对：代码照着 *100# 这种样子写，别漏掉两头的符号"
        default:
            return explain(final)
        }
    }

    /// 3GPP TS 27.007 §9.2，只列这张卡用得到的那些。
    public static func cme(_ code: Int) -> String {
        switch code {
        case 3: return "模块现在不允许这个操作：通常是没有注册到网络"
        case 10: return "模块没检测到 SIM 卡：卡座空着，或卡没插到底"
        case 11: return "SIM 卡开着 PIN 锁，模块在等 PIN 码"
        case 12: return "SIM 卡被 PUK 锁住，要先用手机解开"
        case 13: return "SIM 卡读取失败：没插好、接触不良，或卡本身有问题"
        case 14: return "SIM 卡忙：模块正在读卡，等几秒重试"
        case 15: return "SIM 卡不对：换一张卡试试"
        case 16: return "SIM 卡密码错误"
        case 30: return "模块还没注册到网络，通话建立不起来"
        case 31: return "当前没有可用的网络服务"
        default:
            return code < 0 ? "模块返回了一个没法识别的错误" : "模块返回错误码 \(code)"
        }
    }

    /// 3GPP TS 27.005，短信相关的那些。
    public static func cms(_ code: Int) -> String {
        switch code {
        case 21: return "模块拒收这条短信：参数不合法"
        case 28: return "短信内容超出模块允许的长度"
        case 38: return "短信存储已满，先删几条再发"
        case 50: return "模块没读到短信中心号码（SIM 里没写 SMSC）"
        case 128: return "短信中心号码不合法"
        case 304: return "短信内容为空"
        case 322: return "模块短信存储已满"
        case 330: return "短信中心拒绝了这条短信"
        case 500: return "模块报未知短信错误：多半是卡没插好或没注册到网络"
        case 512: return "短信业务暂时不可用，稍后再试"
        default:
            return code < 0 ? "短信发送失败，模块没给出原因" : "短信发送失败（+CMS ERROR: \(code)）"
        }
    }
}
