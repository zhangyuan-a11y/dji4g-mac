import Foundation
import DJI4GCore

// dji4gctl — a console front end for the DJI first-generation 4G module.
// Every capability the menu-bar app has is reachable here, which is also how
// the engine gets verified against real hardware.

setvbuf(stdout, nil, _IONBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())

/// 命令词之后的所有参数。
///
/// 这几个子命令原先按固定下标取参（`arguments[2]`、`dropFirst(2)`），只有
/// 在「不带任何全局开关」时才碰巧对得上；一旦写成 `dji4gctl --sim-nosim at ...`，
/// 下标整体右移，参数就取错位了。真机上踩到的是最要命的那种形式：
/// `dji4gctl at 'AT+CPIN?'` 什么都没发出去，只回一句「用法」—— 而这是交付
/// 清单里让客户跑的第一条命令。取参一律从这里走。
func argumentsAfter(_ command: String, in all: [String]) -> [String] {
    Array(all.drop { $0 != command }.dropFirst())
}
let useSimulator = arguments.contains("--sim")
    || arguments.contains("--sim-nosim")
    || ProcessInfo.processInfo.environment["DJI4G_SIM"] == "1"

/// `--sim-nosim` runs the same in-memory module with an empty card slot, which
/// is the state a freshly modified module arrives in. Everything except the
/// card-bound commands has to keep working there.
let simulatorScenario: SimulatedATTransport.Scenario =
    arguments.contains("--sim-nosim") ? .noSIM : .ready

let traceEnabled = ProcessInfo.processInfo.environment["DJI4G_TRACE"] == "1"

/// Set only in `--sim`, so the interactive menu can offer the simulator-only
/// entries (incoming call, remote hangup) without lying about real hardware.
var activeSimulator: SimulatedATTransport?

func makeController() -> ModemController {
    if useSimulator {
        let sim = SimulatedATTransport(scenario: simulatorScenario)
        if traceEnabled {
            sim.onCommand = { print("   → \($0)") }
            sim.onEmit = { text in
                for line in text.split(separator: "\r", omittingEmptySubsequences: true) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { print("   ← \(trimmed)") }
                }
            }
        }
        activeSimulator = sim
        let session = ATSession(factory: { sim })
        return ModemController(session: session)
    }
    return ModemController()
}

func hex(_ text: String) -> String { text }

func banner(_ title: String) {
    let line = String(repeating: "─", count: 56)
    print("\n\(line)\n  \(title)\n\(line)")
}

func field(_ label: String, _ value: String) {
    let padded = label.padding(toLength: 14, withPad: " ", startingAt: 0)
    print("  \(padded)\(value)")
}

// MARK: - Self test

/// Verifies the parts that can be checked without hardware: PDU round trips in
/// both alphabets, concatenation, and the AT response parsers.
func runSelfTest() -> Bool {
    var passed = 0
    var failed = 0
    func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            passed += 1
            print("  ✓ \(name)")
        } else {
            failed += 1
            print("  ✗ \(name)")
        }
    }

    banner("自检（无需硬件）")

    // --- GSM 7-bit round trip
    do {
        let text = "Hello 4G module 12345 !@#$"
        let pdu = try PDUDeliver.encode(text: text, from: "+8613800138000")
        let decoded = try PDUCodec.decodeDeliver(pdu)
        check("GSM 7-bit 往返：\"\(text)\"", decoded.text == text)
        check("GSM 7-bit 发件人", decoded.sender == "+8613800138000")
        check("GSM 7-bit 编码标记", decoded.alphabet == .gsm7)
    } catch {
        check("GSM 7-bit 往返（异常：\(error)）", false)
    }

    // --- UCS-2 round trip (Chinese)
    do {
        let text = "你好，大疆一代 4G 模块！"
        let pdu = try PDUDeliver.encode(text: text, from: "10086")
        let decoded = try PDUCodec.decodeDeliver(pdu)
        check("UCS-2 中文往返", decoded.text == text)
        check("UCS-2 编码标记", decoded.alphabet == .ucs2)
    } catch {
        check("UCS-2 中文往返（异常：\(error)）", false)
    }

    // --- Escaped characters
    do {
        let text = "雨伞 {中括号} 反斜杠 \\ 欧元 €"
        let pdu = try PDUDeliver.encode(text: text, from: "10086")
        let decoded = try PDUCodec.decodeDeliver(pdu)
        check("GSM 7-bit 扩展字符往返", decoded.text == text)
    } catch {
        check("GSM 7-bit 扩展字符往返（异常：\(error)）", false)
    }

    // --- Timestamp round trip
    do {
        let now = Date()
        let octets = PDUDeliver.encodeTimestamp(now)
        let decoded = SMSTimestamp.decode(octets)
        let delta = decoded.map { abs($0.timeIntervalSince(now)) } ?? .infinity
        let failed = delta >= 60
        if failed {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            print("      编码 \(PDUCodec.hex(from: octets))"
                  + " 解码 \(decoded.map { formatter.string(from: $0) } ?? "nil")"
                  + " 原始 \(formatter.string(from: now))")
        }
        check("SMS 时间戳往返（误差 \(Int(delta)) 秒）", !failed)
    }

    // --- Concatenation
    do {
        let long = String(repeating: "ABCDEFGHIJ", count: 20)   // 200 septets
        let pdus = try PDUSubmit.encode(text: long, to: "+8613800138000", reference: 7)
        check("长短信被切成多段（\(pdus.count) 段）", pdus.count == 2)

        var segments: [SMSMessage] = []
        for (offset, pdu) in pdus.enumerated() {
            let bytes = try PDUCodec.bytes(fromHex: pdu)
            let scaLength = Int(bytes[0])
            segments.append(stripAndDecodeSubmit(Array(bytes[(1 + scaLength)...]), index: offset + 1))
        }
        let merged = SMSService.assemble(segments)
        check("长短信拼接结果正确", merged.count == 1 && merged[0].text == long)
    } catch {
        check("长短信分段（异常：\(error)）", false)
    }

    // --- Chinese long message
    do {
        let long = String(repeating: "这是一条很长的中文测试短信内容。", count: 6)
        let pdus = try PDUSubmit.encode(text: long, to: "10086", reference: 9)
        check("中文长短信分段（\(pdus.count) 段）", pdus.count >= 2)
        var segments: [SMSMessage] = []
        for (offset, pdu) in pdus.enumerated() {
            let bytes = try PDUCodec.bytes(fromHex: pdu)
            let scaLength = Int(bytes[0])
            segments.append(stripAndDecodeSubmit(Array(bytes[(1 + scaLength)...]), index: offset + 1))
        }
        let merged = SMSService.assemble(segments)
        check("中文长短信拼接结果正确", merged.count == 1 && merged[0].text == long)
    } catch {
        check("中文长短信（异常：\(error)）", false)
    }

    // --- TPDU length used by AT+CMGS
    do {
        let pdu = try PDUSubmit.encode(text: "test", to: "10086").first ?? ""
        let bytes = try PDUCodec.bytes(fromHex: pdu)
        let expected = bytes.count - 1 - Int(bytes[0])
        check("AT+CMGS 的 TPDU 长度计算", SMSService.tpduLength(of: pdu) == expected)
    } catch {
        check("AT+CMGS 长度（异常：\(error)）", false)
    }

    // --- Parsers
    let csq = ATResponse(command: "AT+CSQ", lines: ["+CSQ: 22,99"], final: .ok, unsolicited: [])
    let signal = ATParsers.signal(fromCSQ: csq)
    check("AT+CSQ 解析（-69 dBm）", signal.rssiDBm == -69)

    let qnwinfo = ATResponse(command: "AT+QNWINFO",
                             lines: ["+QNWINFO: \"FDD LTE\",\"46000\",\"LTE BAND 3\",1650"],
                             final: .ok, unsolicited: [])
    var network = NetworkStatus()
    ATParsers.networkInfo(from: qnwinfo, into: &network)
    check("AT+QNWINFO 解析（中国移动）", network.carrier.shortName == "移动" && network.band == "LTE BAND 3")

    let cereg = ATResponse(command: "AT+CEREG?", lines: ["+CEREG: 0,1"], final: .ok, unsolicited: [])
    check("AT+CEREG 解析（已注册）",
          ATParsers.registration(from: cereg, prefix: "+CEREG")?.isRegistered == true)

    // --- 真机 `ATI`：大疆一代模块挂着 Quectel EG25-G 的牌子，回的却是贴牌厂
    // 自己的型号串（下面这四行是从插着电信卡的真机上原样抄下来的）。型号行
    // 不在任何前缀白名单里，面板就给一台干得好好的模块显示「未识别」。
    let djiATI = ATResponse(command: "ATI",
                            lines: ["Baiwang", "QDC507", "Revision: QDC507GLEFM21"],
                            final: .ok, unsolicited: [])
    let djiQGMR = ATResponse(command: "AT+QGMR",
                             lines: ["QDC507GLEFM21_01.001.02.004"], final: .ok, unsolicited: [])
    let djiIdentity = ATParsers.identity(fromATI: djiATI, revision: djiQGMR)
    check("真机 ATI：型号认成 QDC507", djiIdentity.model == "QDC507")
    check("真机 ATI：品牌词不当型号", djiIdentity.model != "Baiwang")
    check("真机 ATI：固件号不当型号", djiIdentity.revision == "QDC507GLEFM21")
    check("真机 AT+QGMR：构建号", djiIdentity.firmwareBuild == "QDC507GLEFM21_01.001.02.004")

    // --- 型号门禁：一代与二代严格分开，认不出的一律拒绝写入。
    check("门禁：QDC507 是一代", ModuleGate.isGenerationOne(model: "QDC507"))
    check("门禁：EG25 是一代", ModuleGate.isGenerationOne(model: nil, revision: "EG25-G"))
    check("门禁：固件号带 QDC507 也认一代",
          ModuleGate.isGenerationOne(model: nil, revision: nil, build: "QDC507GLEFM21_01.001.02.004"))
    check("门禁：二代 IG832 拒绝", !ModuleGate.isGenerationOne(model: "IG832"))
    check("门禁：未知型号拒绝", !ModuleGate.isGenerationOne(model: ""))
    check("门禁：空白身份拒绝", !ModuleGate.isGenerationOne(model: nil, revision: nil, build: nil))
    check("门禁：语音内核 3.18.44 放行", ModuleGate.voiceKernelSupported("3.18.44-perf"))
    check("门禁：其他内核拒绝", !ModuleGate.voiceKernelSupported("5.15.0-android8"))
    check("门禁：空内核拒绝", !ModuleGate.voiceKernelSupported("  "))

    // --- 白名单之外的贴牌模块也不能再显示「未识别」：兜底要挑那条短的型号行，
    // 不能挑走厂名，也不能挑走固件号。
    let oemATI = ATResponse(command: "ATI",
                            lines: ["SIMCOM_Ltd", "SIM7600G-H", "Revision: SIM7600G_R1.0"],
                            final: .ok, unsolicited: [])
    let oemIdentity = ATParsers.identity(fromATI: oemATI, revision: nil)
    check("白名单外型号兜底（SIM7600G-H）", oemIdentity.model == "SIM7600G-H")

    // --- 中国电信的纯 LTE 卡：`AT+CREG?` 回 `0,3`（电路域被拒）而
    // `AT+CEREG?` 回 `0,1`（分组域已注册）。真机上就是这个组合，而界面
    // 早先只看电路域，于是插着卡能上网却显示「被拒绝」。
    var lteOnly = NetworkStatus()
    lteOnly.registration = .denied
    lteOnly.packetRegistration = .registeredHome
    check("电路域被拒、分组域已注册 → 算在线", lteOnly.dataRegistered)
    check("这时候显示的是分组域那句，不是「被拒绝」",
          lteOnly.reportedRegistration == .registeredHome
          && lteOnly.reportedRegistration.label == "已注册（本地）")
    check("这时候只把通话标成受影响", lteOnly.voiceDomainDenied)

    var bothDenied = NetworkStatus()
    bothDenied.registration = .denied
    bothDenied.packetRegistration = .denied
    check("两个域都被拒才算真没注册", !bothDenied.dataRegistered)
    check("两个域都被拒时照实说「被拒绝」",
          bothDenied.reportedRegistration == .denied)
    check("两个域都被拒时不谎报通话单独受影响", !bothDenied.voiceDomainDenied)

    var voiceOnly = NetworkStatus()
    voiceOnly.registration = .registeredHome
    check("电路域自己就注册上时以它为准",
          voiceOnly.reportedRegistration == .registeredHome && !voiceOnly.voiceDomainDenied)

    // --- 短信存储满了要报出来：满了以后新短信会被网络直接丢掉，
    // 而屏幕上什么都不会变。
    var fullMailbox = DoctorFacts()
    fullMailbox.transport = "USB"
    fullMailbox.atResponsive = true
    fullMailbox.simReady = true
    fullMailbox.registered = true
    fullMailbox.smsStorage = "23/23"
    fullMailbox.smsStorageFull = true
    let smsCheck = Doctor.evaluate(fullMailbox).first { $0.title == "短信通道" }
    check("短信存储满了要报 warn", smsCheck?.state == .warn)
    check("存储满时说明新短信会被丢掉",
          smsCheck?.detail.contains("已满") == true && smsCheck?.detail.contains("23/23") == true)
    check("存储满时给出换存储的命令",
          smsCheck?.fix?.contains("sms-storage SM") == true)

    var roomyMailbox = fullMailbox
    roomyMailbox.smsStorage = "1/40"
    roomyMailbox.smsStorageFull = false
    let roomyCheck = Doctor.evaluate(roomyMailbox).first { $0.title == "短信通道" }
    check("存储没满就别报警", roomyCheck?.state == .ok && roomyCheck?.fix == nil)

    // --- Signal detail: both AT+QCSQ and AT+QENG feed the same SignalStatus,
    // and the two must not disagree about which field is which.
    do {
        let qcsq = ATResponse(command: "AT+QCSQ",
                              lines: ["+QCSQ: \"LTE\",-69,-96,138,-11"],
                              final: .ok, unsolicited: [])
        var status = SignalStatus()
        ATParsers.mergeQCSQ(qcsq, into: &status)
        check("AT+QCSQ 解析（RSSI -69 / RSRP -96 / RSRQ -11）",
              status.rssiDBmOverride == -69 && status.rsrp == -96 && status.rsrq == -11)
        check("AT+QCSQ 的 SINR 138 归一化为 27.6 dB", status.sinr == 27.6)

        let positiveRSSI = ATResponse(command: "AT+QCSQ",
                                      lines: ["+QCSQ: \"LTE\",77,-116,76,-17"],
                                      final: .ok, unsolicited: [])
        var eg21 = SignalStatus()
        ATParsers.mergeQCSQ(positiveRSSI, into: &eg21)
        check("AT+QCSQ 正数 RSSI 取负（77 → -77 dBm）", eg21.rssiDBmOverride == -77)

        let qeng = ATResponse(command: "AT+QENG=\"servingcell\"",
                              lines: ["+QENG: \"servingcell\",\"NOCONN\",\"LTE\",\"FDD\",460,00,"
                                      + "1A2D303,214,1650,3,5,5,2F5E,-96,-11,-69,14,-"],
                              final: .ok, unsolicited: [])
        var cell = NetworkStatus()
        var detail = SignalStatus()
        ATParsers.mergeQENG(qeng, into: &cell, signal: &detail)
        check("AT+QENG 解析（频段 BAND 3 / 频点 1650）",
              cell.band == "LTE BAND 3" && cell.channel == 1650)
        check("AT+QENG 解析（RSRP -96 / RSRQ -11 / RSSI -69 / SINR 14）",
              detail.rsrp == -96 && detail.rsrq == -11
              && detail.rssiDBmOverride == -69 && detail.sinr == 14)
        check("AT+QENG 解析（46000 → 中国移动）", cell.carrier.shortName == "移动")

        // Some firmware revisions place two extra fields before the measurement
        // tuple; the tuple has to be found by its ranges rather than its offset.
        let shifted = ATResponse(command: "AT+QENG=\"servingcell\"",
                                 lines: ["+QENG: \"servingcell\",\"NOCONN\",\"LTE\",\"FDD\",460,01,"
                                         + "8401A29,132,3740,8,3,3,-95,5992,-75,-8,-50,11,44"],
                                 final: .ok, unsolicited: [])
        var shiftedCell = NetworkStatus()
        var shiftedDetail = SignalStatus()
        ATParsers.mergeQENG(shifted, into: &shiftedCell, signal: &shiftedDetail)
        check("AT+QENG 字段错位仍能定位（RSRP -75 / SINR 11 / 频点 3740）",
              shiftedDetail.rsrp == -75 && shiftedDetail.sinr == 11 && shiftedCell.channel == 3740)

        // WCDMA reports RSCP second from the end, not the trailing ECIO.
        let wcdma = ATResponse(command: "AT+QENG=\"servingcell\"",
                               lines: ["+QENG: \"servingcell\",\"NOCONN\",\"WCDMA\",460,01,"
                                       + "1A2B3C,4D5E6F,10737,120,-88,-6"],
                               final: .ok, unsolicited: [])
        var wcdmaCell = NetworkStatus()
        var wcdmaSignal = SignalStatus()
        ATParsers.mergeQENG(wcdma, into: &wcdmaCell, signal: &wcdmaSignal)
        check("AT+QENG WCDMA 取 RSCP（-88 dBm，而非 ECIO -6）",
              wcdmaSignal.rssiDBmOverride == -88 && wcdmaCell.channel == 10737)
    }

    let usbcfg = ATResponse(command: "AT+QCFG=\"usbcfg\"",
                            lines: ["+QCFG: \"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,0,0"],
                            final: .ok, unsolicited: [])
    let composition = ATParsers.qcfgComposite(from: usbcfg)
    check("usbcfg 组态解析（一代出厂 1,1,1,1,1,0,0）",
          composition?.vendorID == 0x2CA3 && composition?.flagString == "1,1,1,1,1,0,0")
    check("出厂组态识别为无音频功能", composition?.supportsVoice == false)

    // --- SIM 状态
    //
    // 没插卡时模块回的是 `+CME ERROR: 10/13`，根本没有 `+CPIN` 那一行。
    // 把"读不到"当成"需要 PIN"会让人去找一个不存在的 PIN 码，所以这几种
    // 回答必须落到不同的状态上。
    func simStatus(_ lines: [String], final: ATFinal = .ok,
                   qsimstat: [String]? = nil) -> SIMStatus {
        let cpin = ATResponse(command: "AT+CPIN?", lines: lines, final: final, unsolicited: [])
        let detect = qsimstat.map {
            ATResponse(command: "AT+QSIMSTAT?", lines: $0, final: .ok, unsolicited: [])
        }
        return ATParsers.simStatus(fromCPIN: cpin, qsimstat: detect)
    }

    do {
        let ready = simStatus(["+CPIN: READY"])
        check("CPIN READY → 就绪", ready.ready && ready.state == .ready && !ready.pinRequired)
        check("就绪时不提示需要 SIM 卡", ready.label == "SIM 就绪" && ready.guidance.isEmpty)

        let missing = simStatus([], final: .cme(10), qsimstat: ["+QSIMSTAT: 1,0"])
        check("CME 10 → 判定为没有卡", !missing.ready && missing.state == .missing)
        check("CME 10 不误报「需要 SIM 卡」", !missing.pinRequired)
        check("CME 10 的文案说的是没检测到卡", missing.label.contains("未检测到 SIM 卡"))
        check("卡座检测位被采纳（没有卡）", missing.detectedInserted == false)
        check("没有卡时给出插卡动作", missing.guidance.contains("卡托"))
        // 卡座空着和卡没插好是两件要做的事：一个让客户去拿卡，一个让他重
        // 插。说反了，客户会对着一个空卡座来回去拆卡托。
        check("卡座空着时说的是「去插卡」，不是「卡没插好」",
              missing.guidance.contains("空的") && missing.guidance.contains("装进卡托"))
        // 模块没回答卡座检测（nil）时不能照抄上面那句 —— 那时它自己也不知
        // 道卡在不在，只能让人拔出来重插。
        let blindSlot = simStatus([], final: .cme(10))
        check("卡座检测读不到时说重插（\(blindSlot.guidance)）",
              blindSlot.detectedInserted == nil && blindSlot.guidance.contains("按到底再插回"))

        // 真机在没有卡时回的是 13（SIM failure），不是 10。
        let failure = simStatus([], final: .cme(13))
        check("CME 13 → 判定为读卡失败", failure.state == .failure && !failure.ready)
        check("CME 13 不误报「需要 SIM 卡」", !failure.pinRequired)

        let busy = simStatus([], final: .cme(14))
        check("CME 14 → 判定为卡忙", busy.state == .busy)

        // 开机后头几秒模块会回 3；这时卡的状态还是未知，不能当成没插卡。
        let early = simStatus([], final: .cme(3))
        check("CME 3（模块还没就绪）不判成没卡", early.state == .notReady)
        check("卡座说没有卡时，CME 3 判成没有卡", simStatus([], final: .cme(3), qsimstat: ["+QSIMSTAT: 1,0"]).state == .missing)

        let locked = simStatus(["+CPIN: SIM PIN"])
        check("CPIN SIM PIN → 需要 PIN", locked.state == .pinRequired && locked.pinRequired && !locked.ready)
        check("PIN 锁的原文被保留", locked.pinState == "SIM PIN")
        check("PUK 锁单独区分", simStatus(["+CPIN: SIM PUK"]).state == .pukRequired)
        check("NOT READY 不被当成 READY", simStatus(["+CPIN: NOT READY"]).state == .notReady)
        check("NOT INSERTED 判成没有卡", simStatus(["+CPIN: NOT INSERTED"]).state == .missing)
        check("读不到任何回答时是未知，不是需要 PIN", simStatus([], final: .error).state == .unknown)
        check("卡座检测命令不支持时被忽略", simStatus([], final: .error).detectedInserted == nil)
    }

    do {
        // `AT+CMEE=2` 让模块用文字回错误，数字表对不上时至少要认出常见的几个。
        check("CME 文字错误折回数字（SIM not inserted）",
              ATSession.finalResult(for: "+CME ERROR: SIM not inserted", stopOnPrompt: false) == .cme(10))
        check("CME 文字错误折回数字（SIM PIN required）",
              ATSession.finalResult(for: "+CME ERROR: SIM PIN required", stopOnPrompt: false) == .cme(11))

        check("CME 10 的人话解释提到卡没插好",
              (ATFailure.explain(.cme(10)) ?? "").contains("没检测到 SIM 卡"))
        check("CME 13 的人话解释提到读卡失败",
              (ATFailure.explain(.cme(13)) ?? "").contains("读取失败"))
        check("CMS 500 的人话解释提到卡和注册",
              (ATFailure.explain(.cms(500)) ?? "").contains("没插好"))
        check("NO DIALTONE 解释成没有注册",
              (ATFailure.explain(.other("NO DIALTONE")) ?? "").contains("没有注册到网络"))
        check("OK 没有可解释的错误", ATFailure.explain(.ok) == nil)
    }

    let clcc = ATResponse(command: "AT+CLCC",
                          lines: ["+CLCC: 1,1,4,0,0,\"+8613800138000\",129"],
                          final: .ok, unsolicited: [])
    let calls = CallService.parseCLCC(clcc)
    check("AT+CLCC 解析（来电振铃）", calls.first?.state == .ringing && calls.first?.direction == .incoming)

    // --- 数据链路不是通话
    //
    // 真机上 `AT+CLCC` 永远带着两行 `+CLCC: 1,1,0,1,0,"",128` /
    // `+CLCC: 2,1,0,1,0,"",128`：dir=1 来电方向、stat=0 通话中、mode=1 数据。
    // 这是模块自己的 ECM 数据链路，CHUP 清不掉，插着卡就一直在。当真通话收下的
    // 后果不是「显示得难看」：`current.state` 常驻通话中，`RING` 那条 URC 被
    // `isBusy` 挡掉，来电就不会响 —— 2026-09-24 真机复现的正是这一条。
    let ghostCLCC = ATResponse(command: "AT+CLCC",
                               lines: ["+CLCC: 1,1,0,1,0,\"\",128",
                                       "+CLCC: 2,1,0,1,0,\"\",128"],
                               final: .ok, unsolicited: [])
    let ghosts = CallService.parseCLCC(ghostCLCC)
    check("数据链路不算通话（两行 mode=1 被丢掉）", ghosts.isEmpty)
    check("没有语音通话时首选结果是空，不是「占线」", CallService.preferred(ghosts) == nil)

    // 数据链路和真通话同时出现：真通话必须是选中的那一路，否则拨号中/来电响铃
    // 都会被 ghost 的「通话中」压住（rank 里 active 排在 dialing/alerting 前面）。
    let mixedCLCC = ATResponse(command: "AT+CLCC",
                               lines: ["+CLCC: 1,1,0,1,0,\"\",128",
                                       "+CLCC: 2,1,0,1,0,\"\",128",
                                       "+CLCC: 3,0,3,0,0,\"10000\",129"],
                               final: .ok, unsolicited: [])
    let mixed = CallService.parseCLCC(mixedCLCC)
    check("数据链路与真通话并存时只剩真通话（\(mixed.count) 路）", mixed.count == 1)
    check("拨号中不会被数据链路的「通话中」压住",
          CallService.preferred(mixed)?.state == .alerting)
    check("来电响铃不会被数据链路的「通话中」压住",
          CallService.preferred(CallService.parseCLCC(ATResponse(
              command: "AT+CLCC",
              lines: ["+CLCC: 1,1,0,1,0,\"\",128",
                      "+CLCC: 2,1,4,0,0,\"+8613800138000\",129"],
              final: .ok, unsolicited: [])))?.state == .ringing)

    // --- Call waiting
    //
    // A second caller shows up as a *second* `+CLCC:` row while the first call
    // is still up. Picking the wrong row is what makes a waiting call vanish on
    // the next poll, so the choice itself is worth pinning down.
    let waitingCLCC = ATResponse(command: "AT+CLCC",
                                 lines: ["+CLCC: 1,1,0,0,0,\"+8613800138000\",129",
                                         "+CLCC: 2,1,5,0,0,\"+8613900139000\",129"],
                                 final: .ok, unsolicited: [])
    let twoCalls = CallService.parseCLCC(waitingCLCC)
    check("AT+CLCC 解析双通话（通话中 + 等待接听）",
          twoCalls.count == 2 && twoCalls[1].state == .waiting && twoCalls[1].number == "+8613900139000")
    check("两路通话时显示等待中的那路（否则轮询会把它抹掉）",
          CallService.preferred(twoCalls)?.state == .waiting)
    check("等待接听优先于来电响铃",
          CallService.preferred([CallInfo(index: 1, state: .ringing, number: "A"),
                                 CallInfo(index: 2, state: .waiting, number: "B")])?.number == "B")
    check("通话等待切换后显示正在通话的那路，而不是被保持的那路",
          CallService.preferred([CallInfo(index: 1, state: .held, number: "A"),
                                 CallInfo(index: 2, state: .active, number: "B")])?.number == "B")
    check("只有一路被保持时照常显示",
          CallService.preferred([CallInfo(index: 1, state: .held, number: "A")])?.number == "A")
    check("没有通话时返回空", CallService.preferred([]) == nil)

    // --- 通话记录
    //
    // 模块**不给**通话历史：`AT+CLCC` 报的只有「此刻在响 / 在通」的那几路，
    // 一代 QDC507 问不出过去。所以列表是 App 自己攒的 —— 什么时候起一条、
    // 什么时候结算、结算成哪一种结果，全在这几条里。真机上要是记漏了一通，
    // 客户看不出来（他记得自己打过，列表里没有就是「这软件不准」），所以拿
    // 夹具把它钉死。
    do {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dji4g-calllog-\(UUID().uuidString).json")
        let history = CallHistory(file: path)
        check("新装的机器上通话记录是空的", history.records.isEmpty)

        // 落盘排在自己的队列上（调用线程可能是 AT 那条），所以读文件之前得
        // 等它落下来 —— 这是夹具在等一次异步写，不是产品行为。
        //
        // 窗口是四秒，不是一秒。上面那一档一口气喂了五百口状态，队列里排着
        // 五百次写盘，机器一忙，一秒的光景读到的还是半路的那一份 —— 2026-09-29
        // 就误报过一次「读回来 -1 条」，重跑两次全绿。多等三秒只在真排队的
        // 时候才等，判据本身一个也没放松。
        func stored(where matches: ([CallRecord]) -> Bool) -> [CallRecord]? {
            for _ in 0..<400 {
                let read = CallHistory(file: path).records
                if matches(read) { return read }
                usleep(10_000)
            }
            return nil
        }

        // 呼出、接通、挂断。
        let answeredAt = Date().addingTimeInterval(-125)
        history.observe(CallInfo(index: 1, direction: .outgoing, state: .dialing,
                                 number: "10086", startedAt: answeredAt))
        history.observe(CallInfo(index: 1, direction: .outgoing, state: .active,
                                 number: "10086", startedAt: answeredAt))
        history.observe(CallInfo(index: 1, direction: .outgoing, state: .idle, number: ""))
        check("呼出接通记一条「已接通」",
              history.records.count == 1 && history.records[0].outcome == .answered)
        check("这一条留着号码和方向",
              history.records[0].number == "10086" && history.records[0].outgoing)
        check("接通时长从接通那一刻算起（记了 \(history.records[0].seconds) 秒）",
              abs(history.records[0].seconds - 125) <= 2)
        check("结果的四个字都是三个字，列表才对得齐",
              [CallOutcome.answered, .missed, .rejected, .failed]
                  .allSatisfy { $0.label.count == 3 })

        // 呼出没人接。
        history.observe(CallInfo(index: 1, direction: .outgoing, state: .alerting,
                                 number: "+8618800138001", startedAt: Date()))
        history.observe(CallInfo(index: 1, direction: .outgoing, state: .idle, number: ""))
        check("呼出没接通记「未接通」",
              history.records.count == 2 && history.records[1].outcome == .failed
                  && history.records[1].seconds == 0)

        // 来电、没人接。`CallService` 在响铃结束时会报 `idle`，号码那时已经被
        // 模块清掉 —— 记录得靠前面响铃那几拍攒下的号码活下来。
        history.observe(CallInfo(index: 1, direction: .incoming, state: .ringing,
                                 number: "+8613900139000"))
        history.observe(CallInfo(index: 1, direction: .incoming, state: .idle, number: ""))
        check("来电没人接记「没接到」",
              history.records.count == 3 && history.records[2].outcome == .missed
                  && history.records[2].number == "+8613900139000"
                  && !history.records[2].outgoing)

        // 来电、按拒接。
        history.observe(CallInfo(index: 1, direction: .incoming, state: .ringing,
                                 number: "+8613700137000"))
        history.markRejected()
        history.observe(CallInfo(index: 1, direction: .incoming, state: .idle, number: ""))
        check("按了拒接记「已拒接」，不是「没接到」",
              history.records.count == 4 && history.records[3].outcome == .rejected)

        // 来电、接起来、说完挂断。
        let pickedUp = Date().addingTimeInterval(-8)
        history.observe(CallInfo(index: 1, direction: .incoming, state: .ringing,
                                 number: "+8613600136000"))
        history.observe(CallInfo(index: 1, direction: .incoming, state: .active,
                                 number: "+8613600136000", startedAt: pickedUp))
        history.observe(CallInfo(index: 1, direction: .incoming, state: .idle, number: ""))
        check("来电接起来记「已接通」并带上时长",
              history.records.count == 5 && history.records[4].outcome == .answered
                  && history.records[4].seconds >= 7 && history.records[4].seconds <= 9)

        // 响铃中按「挂断」：对面看到的是被拒。记成「没接到」和事实相反。
        history.observe(CallInfo(index: 1, direction: .incoming, state: .ringing,
                                 number: "+8613500135000"))
        history.markHungUp()
        history.observe(CallInfo(index: 1, direction: .incoming, state: .idle, number: ""))
        check("响铃中按挂断也记「已拒接」",
              history.records.count == 6 && history.records[5].outcome == .rejected)

        // 通话中插进来的第二路：接起来之后两条各记各的，第一路的时长按时收掉。
        let firstLegAt = Date().addingTimeInterval(-60)
        history.observe(CallInfo(index: 1, direction: .outgoing, state: .active,
                                 number: "+8613800138000", startedAt: firstLegAt))
        history.observe(CallInfo(index: 2, direction: .incoming, state: .waiting,
                                 number: "+8613900139000"))
        check("等待中的第二路自己先不占一行",
              history.records.count == 6)
        history.markAnsweredWaiting()
        history.observe(CallInfo(index: 2, direction: .incoming, state: .active,
                                 number: "+8613900139000", startedAt: Date()))
        history.observe(CallInfo(index: 2, direction: .incoming, state: .idle, number: ""))
        check("接了第二路之后两条都在（现在是 \(history.records.count) 条）",
              history.records.count == 8)
        check("第一路按接通时长收掉",
              history.records[6].number == "+8613800138000"
                  && history.records[6].seconds >= 59 && history.records[6].seconds <= 61)
        check("第二路记的是后来那个号码",
              history.records[7].number == "+8613900139000"
                  && history.records[7].outcome == .answered)

        // 模块自己抖出来的空记录（号码没见到、也从没接通过）不记。
        history.observe(CallInfo(index: 1, direction: .unknown, state: .dialing, number: ""))
        history.observe(CallInfo(index: 1, direction: .unknown, state: .idle, number: ""))
        check("没号码也没接通过的「通话」不记", history.records.count == 8)

        // 上限：留最新的 200 条。
        for index in 0..<250 {
            history.observe(CallInfo(index: 1, direction: .outgoing, state: .dialing,
                                     number: "1000\(index)", startedAt: Date()))
            history.observe(CallInfo(index: 1, direction: .outgoing, state: .idle, number: ""))
        }
        check("攒到上限之后只剩最近 200 条（现在 \(history.records.count) 条）",
              history.records.count == 200)
        check("丢的是最旧的，最新那条还在",
              history.records.last?.number == "1000249" && history.records.first?.number == "100050")

        // 落盘：换一个实例读同一个文件，得看到同样的一列。客户早上打过的
        // 电话，晚上再打开还得在。
        let reopened = stored { $0.count == 200 && $0.last?.number == "1000249" }
        check("通话记录跨重启还在（读回来 \(reopened?.count ?? -1) 条）",
              reopened?.last?.number == "1000249" && reopened?.first?.number == "100050")

        history.clear()
        check("清空之后列表和文件都空了",
              history.records.isEmpty && stored { $0.isEmpty } != nil)

        check("时长写法：02:05 / 62:05（分钟不进位，和通话卡片同一个写法）",
              CallRecord.durationLabel(125) == "02:05"
                  && CallRecord.durationLabel(3725) == "62:05"
                  && CallRecord.durationLabel(32) == "00:32")
        let today = Date()
        check("今天那一通只写钟点",
              CallRecord(number: "10086", outgoing: true, outcome: .answered, at: today)
                  .timeLabel(now: today).count == 5)
        check("昨天那一通写「昨天」",
              CallRecord(number: "10086", outgoing: true, outcome: .answered,
                         at: Calendar.current.startOfDay(for: today).addingTimeInterval(-3600))
                  .timeLabel(now: today) == "昨天")

        // 结算出来的那一条要交回来：日志里那一行「通话记录 +1：…」就是它。
        // 没有这个返回值，客户报「记录不对」时只能靠猜是没记还是记错了。
        check("还没结束的那几拍不返回记录",
              history.observe(CallInfo(index: 1, direction: .outgoing, state: .dialing,
                                       number: "12345", startedAt: Date())) == nil)
        check("结束的那一下把结算好的记录交回来",
              history.observe(CallInfo(index: 1, direction: .outgoing, state: .idle,
                                       number: ""))?.number == "12345")

        // 诊断报告是会被发出来的（微信、邮件都会），日志里带号码的那两处
        // ——「通话状态：…」和「新短信 …」—— 都得脱敏之后再写。
        check("号码脱敏：留头三位和尾四位（\("+8618957549662".maskedAsPhoneNumber)）",
              "+8618957549662".maskedAsPhoneNumber == "+86****9662")
        check("短号不遮：客服号不是私人号码",
              "10086".maskedAsPhoneNumber == "10086"
                  && "+8610".maskedAsPhoneNumber == "+8610")
        check("遮完还认得出是哪一通（尾四位还在）",
              "+8613500139000".maskedAsPhoneNumber.hasSuffix("9000"))
        check("前后带空格也照样遮",
              "  13800138000  ".maskedAsPhoneNumber == "138****8000")
        try? FileManager.default.removeItem(at: path)
    }

    // --- Call audio
    //
    // 这里以前钉的是「响铃时自动把系统默认音频切到模块」。2026-09-25 的真机
    // 实测把那个结论拆成了两半：
    //
    //   · 「模块的 USB 声卡在通话里全零」（放 440 Hz 到 AS Interface 再录
    //     AC Interface、`AT+QAUDLOOP=1` 内部回环、QAUDMOD 六种模式各拨一通，
    //     81920 个样本没有一个非零）是**假**的 —— 全零是因为少了三步前置：
    //     厂商驱动、出厂语音校准、PCM 桥，见 `ModuleVoiceSetup`。补上之后两
    //     个方向都有真实语音，双向通话实测通了。
    //   · 「不许自动切默认设备」是**对**的，只是理由换了 —— 语音由
    //     `CallAudioBridge` 直接绑 `AC Interface` / `AS Interface` 送，全程
    //     不碰系统默认设备。把默认输入输出指到模块（两个各只有一个方向的
    //     端点）只会把客户的音乐和提示音一起搬走，对通话毫无帮助。
    //
    // 所以现在钉的是：**谁都不许自动动默认设备**。
    check("来电时不动系统默认音频（自动切换已取消）",
          AudioRouting.action(current: .ringing, isRouted: false) == .none)
    check("拨号中不动系统默认音频",
          AudioRouting.action(current: .dialing, isRouted: false) == .none)
    check("通话中不动系统默认音频",
          AudioRouting.action(current: .active, isRouted: false) == .none)
    check("已经在模块上时也不重复切",
          AudioRouting.action(current: .active, isRouted: true) == .none)
    check("通话结束后把客户手动切过去的设备还回去",
          AudioRouting.action(current: .idle, isRouted: true) == .restore)
    check("对端挂断后同样还回去",
          AudioRouting.action(current: .ended, isRouted: true) == .restore)
    check("空闲且没切过就不动音频",
          AudioRouting.action(current: .idle, isRouted: false) == .none)

    // --- 工厂锁（QADBKEY）解锁口令
    //
    // 下面第一对是真机上解锁成功的那一对：挑战值 27454934 → 口令 LWuf7OD1GJ1q/Lj。
    // 客户那台的挑战值未必相同，所以口令必须是**算**出来的、不能写死 ——
    // 写死的话客户那台会解不开，而且报错里看不出为什么。
    check("QADBKEY 口令推导（真机验证过的一对）",
          QADBKey.derive(challenge: "27454934") == "LWuf7OD1GJ1q/Lj")
    check("QADBKEY 换个挑战值就换个口令（说明不是写死的常量）",
          QADBKey.derive(challenge: "12345678").map { $0 != "LWuf7OD1GJ1q/Lj" } == true)
    check("QADBKEY 口令长 15 位",
          QADBKey.derive(challenge: "27454934")?.count == 15)
    check("QADBKEY 拒绝 7 位挑战值", QADBKey.derive(challenge: "1234567") == nil)
    check("QADBKEY 拒绝 9 位挑战值", QADBKey.derive(challenge: "123456789") == nil)
    check("QADBKEY 拒绝非数字挑战值", QADBKey.derive(challenge: "2745493a") == nil)
    check("QADBKEY 拒绝空挑战值", QADBKey.derive(challenge: "") == nil)

    // 真机踩过：模块回的是 `+QADBKEY: 27454934`，而调用方按 `"QADBKEY"` 前缀
    // 去找。行首的 `+` 一挡，挑战值就在报错里摆着却读不出来，界面报「读不到
    // ADB 挑战值」—— 这条守着那个坑。
    do {
        let reply = ATResponse(command: "AT+QADBKEY?", lines: ["+QADBKEY: 27454934"],
                               final: .ok, unsolicited: [])
        check("AT 解析：带 + 的信息行能被不带 + 的前缀读到",
              reply.firstValue(for: "QADBKEY") == "27454934")
        check("AT 解析：带 + 的信息行也能被带 + 的前缀读到",
              reply.firstValue(for: "+QADBKEY") == "27454934")
        let usbcfg = ATResponse(command: "AT+QCFG=\"usbcfg\"",
                                lines: ["+QCFG: \"usbcfg\",1,1,1,1,1,1,1,1,1,1,0"],
                                final: .ok, unsolicited: [])
        check("AT 解析：usbcfg 行两种前缀都能读",
              usbcfg.firstValue(for: "QCFG")?.hasPrefix("\"usbcfg\"") == true
              && usbcfg.firstValue(for: "+QCFG")?.hasPrefix("\"usbcfg\"") == true)
    }

    // --- usbcfg 的字段位置（adb 位）
    //
    // 现场那一串就是下面这个（真机 `AT+QCFG="usbcfg"` 的原样返回，行首的
    // `+QCFG:` 已经被 `firstValue` 掐掉了）。字段顺序见 README：
    //     name, vid, pid, diag, nmea, at, modem, network, adb, audio
    // adb 是**下标 8**。这一段守着两个真机上真的发生过的错：
    //   · 原实现写死「必须先找到冒号」，而 `firstValue` 的返回值里没有冒号
    //     → 永远返回 nil，界面报「读不到 usbcfg」，值就在报错里摆着；
    //   · 下标取成了 7（那是 network）。这台模块的 network 位是 1，于是
    //     「adb 位是 0」会被读成 1、解锁步骤被整段跳过，后面每一步都报
    //     「ADB 里看不到模块」，看着像数据线没插好。
    let realUsbcfg = "\"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,1,1"
    check("usbcfg：真机那一串读得出 adb 位（=1）",
          ModuleVoiceSetup.adbBit(inUsbcfg: realUsbcfg) == 1)
    check("usbcfg：连 `+QCFG:` 前缀一起传进来也读得出",
          ModuleVoiceSetup.adbBit(inUsbcfg: "+QCFG: \(realUsbcfg)") == 1)
    check("usbcfg：读的是 adb 位，不是 network 位",
          ModuleVoiceSetup.adbBit(inUsbcfg: "\"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,0,1") == 0)
    check("usbcfg：出厂那一串（adb 与 audio 都是 0）读出来是 0",
          ModuleVoiceSetup.adbBit(inUsbcfg: "\"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,0,0") == 0)
    check("usbcfg：写 adb 位只动那一位，VID/PID 和别的功能位一个都不少",
          ModuleVoiceSetup.usbcfg("\"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,0,0",
                                  settingAdbBit: 1)
          == "\"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,1,0")
    check("usbcfg：audio 位不会跟着被动",
          ModuleVoiceSetup.usbcfg("\"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,0,1",
                                  settingAdbBit: 1)
          == "\"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,1,1")
    check("usbcfg：组出来的命令里 `usbcfg` 这个名字只出现一次",
          ModuleVoiceSetup.usbcfgCommand("\"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,0,1",
                                         settingAdbBit: 1)
          == "AT+QCFG=\"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,1,1")
    check("usbcfg：带 `+QCFG:` 前缀的返回也能组出同一条命令",
          ModuleVoiceSetup.usbcfgCommand("+QCFG: \"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,0,1",
                                         settingAdbBit: 1)
          == "AT+QCFG=\"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,1,1")
    check("usbcfg：字段不够时返回 nil，而不是猜一位出来",
          ModuleVoiceSetup.adbBit(inUsbcfg: "\"usbcfg\",1,1,1") == nil
          && ModuleVoiceSetup.usbcfg("\"usbcfg\",1,1,1", settingAdbBit: 1) == nil)

    // --- 模块端点识别
    //
    // 这版模块把 UAC 拆成两个单向设备报上来，名字里带 AC/AS Interface。
    // 名字表里漏一个，界面就报「未检测到模块音频设备」，通话接得通却听不到声音。
    check("认得模块的录音端点（AC Interface）",
          VoiceService.matchesModuleName(AudioDevice(id: 1, name: "AC Interface", uid: "ac",
                                                     hasInput: true, hasOutput: false, transport: "USB")))
    check("认得模块的放音端点（AS Interface）",
          VoiceService.matchesModuleName(AudioDevice(id: 2, name: "AS Interface", uid: "as",
                                                     hasInput: false, hasOutput: true, transport: "USB")))
    check("不把内置麦克风当模块端点",
          !VoiceService.matchesModuleName(AudioDevice(id: 3, name: "Built-in Microphone", uid: "bi",
                                                      hasInput: true, hasOutput: false, transport: "BuiltIn")))
    check("不把内置扬声器当模块端点",
          !VoiceService.matchesModuleName(AudioDevice(id: 4, name: "Built-in Output", uid: "bo",
                                                      hasInput: false, hasOutput: true, transport: "BuiltIn")))

    // --- 体检脚本的解析
    //
    // 这一段是被真机打回来才补的：`adb shell` 回的是 **CRLF** 换行，而 Swift
    // 把 `\r\n` 当成一个 Character，`split(separator: "\n")` 一行都切不出来。
    // 后果是模块明明全就绪，体检却报「驱动未加载 / 校准未下发 / 桥未运行」，
    // 客户照着提示重启模块也没用。真机原始输出就长这样，按它钉住。
    let realProbe = "##modules\r\n1\r\n2\r\n##audio\r\n1\r\n##cards\r\n2\r\n"
        + "##procs\r\n1\r\n2\r\n##fifo\r\nyes\r\n"
    let crlfCounts = ModuleVoiceSetup(session: nil).parse(probe: realProbe)
    let lfCounts = ModuleVoiceSetup(session: nil)
        .parse(probe: realProbe.replacingOccurrences(of: "\r\n", with: "\n"))
    check("体检脚本在 CRLF 下读得出模块计数（adb 回的就是 CRLF）",
          crlfCounts.aprv3 == 1 && crlfCounts.voice == 2)
    check("体检脚本在 CRLF 下读得出 audio_enable",
          crlfCounts.audioEnable == "1")
    check("体检脚本在 CRLF 下读得出声卡和两个进程",
          crlfCounts.cards == 2 && crlfCounts.bridge == 1 && crlfCounts.alsaucm == 2)
    check("体检脚本在 CRLF 下读得出校准 FIFO", crlfCounts.fifo)
    check("换成 LF 换行结果一样（两种写法都得认）", crlfCounts == lfCounts)
    check("全就绪时五条前置条件都成立",
          crlfCounts.aprv3 > 0 && crlfCounts.voice > 0 && crlfCounts.cards > 0
          && crlfCounts.bridge > 0 && crlfCounts.alsaucm > 0 && crlfCounts.fifo
          && crlfCounts.audioEnable == "1")
    check("切行助手把 CRLF / LF / CR 都当换行",
          ModuleVoiceSetup.lines(in: "a\r\nb\rc\nd") == ["a", "b", "c", "d"])

    // --- 端到端体检
    //
    // The factory state is the case worth pinning down: the module ships with
    // the USB audio function off and a network mode macOS has no driver for, so
    // a fresh module answers calls with silence and never creates an interface.
    // Nothing in the system reports an error for either.
    func workingFacts() -> DoctorFacts {
        var facts = DoctorFacts()
        facts.transport = "USB 2CA3:4006"
        facts.atResponsive = true
        facts.firmware = "EG25GGBR07A08M2G"
        facts.simReady = true
        facts.simDetail = "已就绪"
        facts.registered = true
        facts.carrier = "中国电信"
        facts.apn = "CTNET"
        facts.smsStorage = "4/23"
        return facts
    }
    func makeComposition(audio: Bool) -> USBComposition {
        USBComposition(vendorID: 0x2CA3, productID: 0x4006,
                       diag: true, nmea: true, atPort: true, modem: true,
                       network: true, adb: false, audio: audio)
    }

    do {
        var factory = workingFacts()
        factory.usbnetMode = .rndis
        factory.composition = makeComposition(audio: false)
        let checks = Doctor.evaluate(factory)
        check("出厂组态：短信可用", Doctor.isReady(.sms, in: checks))
        // 出厂组态里模块声卡是关的，而这一项**不再**拦「来电与拨号」：真机实测
        // 里声卡开不开都听不到声音，通话能不能建立跟它没有关系。这条断言以前
        // 是反着的，正是那句不成立的话把客户送去点一个没用的开关。
        check("出厂组态：通话可用（拨号/接听不依赖模块声卡）", Doctor.isReady(.calls, in: checks))
        check("出厂组态：报告里仍然说得出模块声卡没开",
              checks.first { $0.title == "模块声卡" }?.state == .warn)
        check("模块声卡这一项不再拦任何能力",
              checks.first { $0.title == "模块声卡" }?.blocks.isEmpty == true)
        // 这句话的口径现在是：声卡是通话**语音**的载体，但光开着不够，还要
        // 装一次语音通路。两条都断言 —— 少任何一条都会退回到拿不成立的因果
        // 去指挥客户点按钮。
        check("模块声卡这一项说的是实话（不再承诺「开了就有声音」）",
              (checks.first { $0.title == "模块声卡" }?.detail ?? "").contains("一键安装"))
        // 指的按钮得跟屏幕上那颗同名：界面早就叫「一键安装」了，报告里还写
        // 全称的话，客户会去找一个按钮上根本没有的字。
        check("模块声卡这一项不再用旧按钮全称",
              !(checks.first { $0.title == "模块声卡" }?.detail ?? "").contains("一键安装通话语音"))
        check("模块声卡这一项不再说「不走 USB 声卡」",
              !(checks.first { $0.title == "模块声卡" }?.detail ?? "").contains("不走 USB"))
        check("出厂组态：联网不可用（不是 ECM）", !Doctor.isReady(.internet, in: checks))
        check("出厂组态：两项一次性设置合并成一条 prepare",
              Doctor.pendingFixes(checks).map { $0.split(separator: " ").dropFirst().first.map(String.init) ?? "" }
                == ["prepare"])
    }

    do {
        // 卡的提示必须跟着卡的状态走：没插卡时让人去查欠费是错的建议。
        var noCard = workingFacts()
        noCard.simReady = false
        noCard.simDetail = "未检测到 SIM 卡（卡座检测：没有卡）"
        noCard.simFix = "取出卡托，把卡按到底再插回"
        let noCardChecks = Doctor.evaluate(noCard)
        let simCheck = noCardChecks.first { $0.title == "SIM 卡" }
        check("没插卡时给的是插卡动作，不是查欠费",
              (simCheck?.fix ?? "").contains("插回") && !(simCheck?.fix ?? "").contains("欠费"))
        check("没插卡时不再单独报「未注册」（否则会让人去查天线）",
              noCardChecks.first { $0.title == "网络注册" }?.state == .skipped)
        check("没插卡时三项功能仍然都不可用",
              Capability.allCases.allSatisfy { !Doctor.isReady($0, in: noCardChecks) })
        check("没插卡时只有插卡这一条待办",
              Doctor.pendingFixes(noCardChecks).filter { $0.contains("卡") }.count == 1)
        // 报告不能只把「插卡」排在前面就完事：其余几步里有一半不用卡。
        let note = Doctor.noCardNote(noCard) ?? ""
        check("没插卡时报告末尾提醒：不用卡的步骤可以先做完（\(note.isEmpty ? "没有这句" : "有")）",
              note.contains("不需要卡") && note.contains("重启"))
        check("卡就绪之后没有这句提醒", Doctor.noCardNote(workingFacts()) == nil)
    }

    do {
        // 真机上踩到的坑：这几个子命令按固定下标取参，带上全局开关时下标右移、
        // 参数错位；不带开关时 `at` 反而把自己的命令词吃掉，只回一句「用法」——
        // 而 `dji4gctl at 'AT+CPIN?'` 正是交付清单里让客户照抄的第一条。
        check("at 取参：不带开关",
              argumentsAfter("at", in: ["at", "AT+CPIN?"]) == ["AT+CPIN?"])
        check("at 取参：带全局开关",
              argumentsAfter("at", in: ["--sim-nosim", "at", "AT+CPIN?"]) == ["AT+CPIN?"])
        check("sms-send 取参：号码与内容各就各位",
              argumentsAfter("sms-send", in: ["sms-send", "10086", "108"]) == ["10086", "108"])
        check("call-dial 取参：带全局开关",
              argumentsAfter("call-dial", in: ["--sim", "call-dial", "10000"]) == ["10000"])
        check("usbnet 取参：带全局开关",
              argumentsAfter("usbnet", in: ["--sim-nosim", "usbnet", "1"]) == ["1"])
        check("没给参数时取回空列表（交给调用方回用法）",
              argumentsAfter("at", in: ["at"]).isEmpty
                && argumentsAfter("apn", in: ["--sim", "doctor"]).isEmpty)
    }

    do {
        // 真机（DJI 一代 QDC507 里的 EG25-G）回的 QICSGP 只有五段，少掉的正是
        // context_type；模拟器和文档都是六段。原来按固定下标读 [2]，在真机上读到
        // 的是空用户名 —— 模块里明明存着 CTNET、也正在跑流量，报告却到处说
        // 「模块里还没有 APN」。
        check("真机五段形式读出 CTNET",
              ATParsers.apnField(fromQICSGP: "1,\"CTNET\",\"\",\"\",0") == "CTNET")
        check("文档六段形式照样读出 CTNET",
              ATParsers.apnField(fromQICSGP: "1,\"IP\",\"CTNET\",\"\",\"\",0") == "CTNET")
        check("六段里 context_type 写成数字也读得对",
              ATParsers.apnField(fromQICSGP: "1,3,\"CTNET\",\"user\",\"pass\",0") == "CTNET")
        check("两种形式下 APN 真为空时都不谎报一个出来",
              ATParsers.apnField(fromQICSGP: "1,\"\",\"\",\"\",0") == ""
                && ATParsers.apnField(fromQICSGP: "1,\"IP\",\"\",\"\",\"\",0") == "")
        check("字段少到读不出时不硬编一个 APN",
              ATParsers.apnField(fromQICSGP: "1") == nil)
    }

    do {
        // 真机上踩到的假警报：APN 读回空，但 en59 已经拿到 192.168.225.26、
        // 流量也在走。报告在「网卡与 IP」打勾、在「APN」判失败，还因此把整个
        // 「联网」判成不可用 —— 客户拿着它去查天线，查的是没坏的东西。
        var facts = workingFacts()
        facts.usbnetMode = .ecm
        facts.composition = makeComposition(audio: true)
        facts.interfaceName = "en59"
        facts.ipv4 = "192.168.225.26"
        facts.serviceName = "Baiwang"
        facts.serviceEnabled = true
        facts.hasModuleAudio = true
        facts.apn = ""
        let checks = Doctor.evaluate(facts)
        let apnCheck = checks.first { $0.title == "APN" }
        check("APN 读不到但网卡有 IP：APN 不判失败", apnCheck?.state == .ok)
        check("该状态下不再劝客户去配一个已经在用的 APN",
              Doctor.isReady(.internet, in: checks)
                && !Doctor.pendingFixes(checks).contains { $0.contains("apn") })
    }

    do {
        // 反过来：APN 没有、网卡也没有 IP。这才是真没配好，得劝。
        var facts = workingFacts()
        facts.apn = ""
        let checks = Doctor.evaluate(facts)
        let apnCheck = checks.first { $0.title == "APN" }
        check("APN 和网卡都没有：APN 判 warn 并挡住联网",
              apnCheck?.state == .warn && !Doctor.isReady(.internet, in: checks))
    }

    do {
        // USSD 的答案在模块那头是**十六进制写的 UCS2**（`60A8` 就是「您」），
        // 国内三家运营商全走这一档。解不出来，客户看到的是一串十六进制。
        let reply = ATParsers.ussdReply(
            from: "+CUSD: 0,\"60A876844F59989D4E3A00310032002E003300305143\",72")
        check("USSD：UCS2 十六进制解成中文（\(reply?.text ?? "nil")）",
              reply?.text == "您的余额为12.30元")
        check("USSD：会话状态照原样带出来", reply?.status == 0 && reply?.isComplete == false)
        // 「1234」这种纯数字的余额也是十六进制长相，别把它当编码解掉 ——
        // 解出来是 U+1234 那个埃塞俄比亚字母，客户只会看到乱码。
        check("USSD：纯数字答案不被当成 UCS2（\(ATParsers.ussdReply(from: "+CUSD: 0,\"1234\",15")?.text ?? "nil")）",
              ATParsers.ussdReply(from: "+CUSD: 0,\"1234\",15")?.text == "1234")
        check("USSD：只有状态、没有正文那种也认得出结束",
              ATParsers.ussdReply(from: "+CUSD: 2")?.isComplete == true)
        check("USSD：别的上报不会被误认",
              ATParsers.ussdReply(from: "+CMTI: \"ME\",3") == nil)
        // 2026-09-28 真机：数据通着、电话也能打，`AT+CUSD` 却回 30。那不是
        // 「没注册」，是电路域（`AT+CREG?` 报 0,3）被拒。文案要是照搬通话
        // 那一句，客户会一直以为是自己卡没插好。
        check("USSD：+CME ERROR: 30 说成「网络没有语音通道」",
              (ATFailure.explainUSSD(.cme(30)) ?? "").contains("语音通道"))
        check("USSD：别的错误码照样走通用解释",
              ATFailure.explainUSSD(.cme(10)) == ATFailure.explain(.cme(10)))
    }

    do {
        // 扫网那一行尾巴上还挂着「支持的频段」(0-1) 和「支持的制式」(0,2)，
        // 它们不是运营商。靠字段数挡掉，不然客户列表里会多出两条假的。
        let scanned = ATResponse(
            command: "AT+COPS=?",
            lines: ["+COPS: (2,\"CHINA TELECOM\",\"CT\",\"46011\"),(1,\"CHINA MOBILE\",\"CMCC\",\"46000\"),,(0-1),(0,2)"],
            final: .ok,
            unsolicited: [])
        let found = ATParsers.operators(fromCOPSScan: scanned)
        check("扫网：只挑出运营商两条（\(found.count) 条）", found.count == 2)
        check("扫网：当前那家认得出", found.first { $0.numeric == "46011" }?.isCurrent == true)
        check("扫网：按号码排序", found.map(\.numeric) == ["46000", "46011"])
    }

    do {
        // 体检报告会直接把命令塞给客户（「→ dji4gctl sms-storage SM」）。那条
        // 命令要是没写进 help，客户复制过去只会得到「未知命令」——
        // sms-storage 刚这样漏过一次，而它正是体检让客户去跑的那一条。
        // 加子命令时这个列表和 usageText 一起改。
        let dispatched = ["doctor", "usb", "status", "network", "sms-list", "sms-send",
                          "sms-storage", "call-dial", "voice", "prepare", "voice-enable",
                          "apn", "usbnet", "net-status", "net-enable", "net-disable",
                          "fontcheck", "ussd", "operators", "operator-set", "operator-auto",
                          "autostart", "at", "sim", "selftest", "help", "restore"]
        let missing = dispatched.filter { !usageText.contains($0) }
        check("help 里列全了所有子命令（缺：\(missing.joined(separator: " "))）",
              missing.isEmpty)
    }

    do {
        // 「恢复出厂」的基准就是这一串：一代模块出厂是 `1,1,1,1,1,0,0` ——
        // 网卡位开着，adb 位和音频位关着（`docs/NETWORKING.md`）。复原只撤
        // 本工具翻过的那两位，别的位一个都不许动。这条线写错的话，客户点完
        // 「恢复」拿到的不是出厂状态，而是第三种谁也没见过的状态，而且没有
        // 任何界面会告诉他哪里不对。
        let factoryLine = ATResponse(
            command: "AT+QCFG=\"usbcfg\"",
            lines: ["+QCFG: \"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,0,0"],
            final: .ok,
            unsolicited: [])
        let factory = ATParsers.qcfgComposite(from: factoryLine)
        check("出厂组态读出来是 1,1,1,1,1,0,0", factory?.flagString == "1,1,1,1,1,0,0")
        check("出厂组态里 adb 与音频都是关的",
              factory?.adb == false && factory?.audio == false)

        // 复原的动作 = 把这两位清零。网卡位得留着 —— 大疆的设备就是靠它上网的。
        var restored = factory
        restored?.adb = false
        restored?.audio = false
        check("复原后网卡位仍在", restored?.network == true)
        check("复原后组态回到出厂那一串",
              restored?.flagString == factory?.flagString)
    }

    do {
        // 只差一项时不该再劝用户跑一键配置：多写的那一项是没有必要的写入。
        var facts = workingFacts()
        facts.usbnetMode = .ecm
        facts.composition = makeComposition(audio: false)
        let fixes = Doctor.pendingFixes(Doctor.evaluate(facts))
        check("只差音频：给 voice-enable，不再劝一键配置",
              fixes.contains { $0.contains("voice-enable") }
                && !fixes.contains { $0.contains("prepare") })
    }

    do {
        var facts = workingFacts()
        facts.usbnetMode = .rndis
        facts.composition = makeComposition(audio: true)
        let fixes = Doctor.pendingFixes(Doctor.evaluate(facts))
        check("只差网络：给 usbnet，不再劝一键配置",
              fixes.contains { $0.contains("usbnet 1") }
                && !fixes.contains { $0.contains("prepare") })
    }

    do {
        var ready = workingFacts()
        ready.usbnetMode = .ecm
        ready.composition = makeComposition(audio: true)
        ready.interfaceName = "en17"
        ready.ipv4 = "10.42.7.19"
        ready.serviceName = "Baiwang"
        ready.serviceEnabled = true
        ready.hasModuleAudio = true
        let checks = Doctor.evaluate(ready)
        check("配置齐全：三项功能都可用",
              Capability.allCases.allSatisfy { Doctor.isReady($0, in: checks) })
        check("配置齐全：没有待执行项", Doctor.pendingFixes(checks).isEmpty)
    }

    do {
        // 网卡有 IP、服务却是关的 —— 这是最容易误判成"已经联网"的状态。
        var facts = workingFacts()
        facts.usbnetMode = .ecm
        facts.composition = makeComposition(audio: true)
        facts.interfaceName = "en17"
        facts.ipv4 = "10.42.7.19"
        facts.serviceName = "Baiwang"
        facts.serviceEnabled = false
        let checks = Doctor.evaluate(facts)
        check("有 IP 但 macOS 服务未启用：联网仍不可用", !Doctor.isReady(.internet, in: checks))
        check("该状态下提示 net-enable",
              Doctor.pendingFixes(checks).contains { $0.contains("net-enable") })
    }

    do {
        var facts = workingFacts()
        facts.usbnetMode = .ecm
        facts.composition = makeComposition(audio: true)
        facts.interfaceName = "en17"
        let checks = Doctor.evaluate(facts)
        check("ECM 已开但没拿到 IP：联网不可用", !Doctor.isReady(.internet, in: checks))
    }

    do {
        var missing = DoctorFacts()
        missing.atResponsive = false
        let checks = Doctor.evaluate(missing)
        check("没有模块：三项功能都不可用",
              Capability.allCases.allSatisfy { !Doctor.isReady($0, in: checks) })
        check("没有模块：报 USB 一条失败 + AT 一条失败",
              checks.count == 2 && checks[0].state == .fail && checks[1].state == .fail)
    }

    do {
        // USB 在、AT 不通：最容易被误判成"模块坏了"，所以要能把这一条单独说清楚，
        // 而不是让后面十几项跟着一起判失败。
        var dead = DoctorFacts()
        dead.transport = "USB 2CA3:4006"
        dead.atResponsive = false
        let checks = Doctor.evaluate(dead)
        check("AT 不通：USB 判过、AT 判失败，共两条",
              checks.count == 2 && checks[0].state == .ok && checks[1].state == .fail)
        check("AT 不通：三项功能都不可用",
              Capability.allCases.allSatisfy { !Doctor.isReady($0, in: checks) })
    }

    check("运营商查表（46011 → 中国电信）",
          CarrierCatalog.carrier(forMCCMNC: "46011").apn == "CTNET")

    // 有些固件把运营商名写成中文（面板上看到的就是这几个字）。认不出来时，
    // 卡插着、也注册上了，自动配 APN 那一步却是空转 —— 客户看到的是「有信号
    // 但上不了网」，而原因根本不在他身上。
    do {
        // 体检报告里那条修复建议要跟着卡走。写死 CTNET 的版本会让移动 / 联通 /
        // 广电的卡照抄电信的 APN —— 客户照着报告做，反而连不上。
        var mobile = workingFacts()
        mobile.carrier = "中国移动"
        mobile.apn = ""
        let mobileFixes = Doctor.pendingFixes(Doctor.evaluate(mobile))
        check("移动的卡：体检建议写 CMNET",
              mobileFixes.contains { $0.hasSuffix("apn CMNET") })

        var telecom = workingFacts()
        telecom.carrier = "中国电信"
        telecom.apn = ""
        let telecomFixes = Doctor.pendingFixes(Doctor.evaluate(telecom))
        check("电信的卡：体检建议写 CTNET",
              telecomFixes.contains { $0.hasSuffix("apn CTNET") })

        var unknown = workingFacts()
        unknown.carrier = ""
        unknown.apn = ""
        let unknownFixes = Doctor.pendingFixes(Doctor.evaluate(unknown))
        check("认不出运营商时给自动那条，不瞎指定一家",
              unknownFixes.contains { $0.hasSuffix("apn") })
    }

    check("中文运营商名也认（中国移动 → CMNET）",
          CarrierCatalog.carrier(forOperatorName: "中国移动")?.apn == "CMNET")
    check("中文运营商名也认（中国联通 → 3GNET）",
          CarrierCatalog.carrier(forOperatorName: "中国联通")?.apn == "3GNET")
    check("中文运营商名也认（中国电信 → CTNET）",
          CarrierCatalog.carrier(forOperatorName: "中国电信")?.apn == "CTNET")
    check("中文运营商名也认（中国广电 → CBNET）",
          CarrierCatalog.carrier(forOperatorName: "中国广电")?.apn == "CBNET")
    // 「中国移动香港」里也含「中国移动」四个字，别名表里它必须排在前面。
    // 顺序反了不会报错，只会把香港卡当成内地移动。
    check("香港移动不会被认成内地的中国移动（45412）",
          CarrierCatalog.carrier(forOperatorName: "中国移动香港")?.mccmnc == "45412")
    check("usbnet 模式判定（RNDIS 不适配 macOS）", USBnetMode.rndis.worksOnMac == false)

    // --- macOS network service parsing
    //
    // This is the half of "联网" that the modem knows nothing about: the
    // interface can be up with a valid IP while macOS still routes everything
    // over Wi-Fi, because the matching network service is off. Parsing the
    // service table is therefore load-bearing, and the transcript below is the
    // shape the reference machine produced (module on en17, service "Baiwang").
    let serviceOrder = """
    An asterisk (*) denotes that a network service is disabled.
    (1) Wi-Fi
    (Hardware Port: Wi-Fi, Device: en0)

    (2) Thunderbolt Bridge
    (Hardware Port: Thunderbolt Bridge, Device: bridge0)

    (*) Baiwang
    (Hardware Port: Baiwang, Device: en17)

    (3) iPhone USB
    (Hardware Port: iPhone USB, Device: en6)
    """
    check("网络服务解析（en17 → Baiwang，忽略被禁用的星号）",
          HostNetwork.parseServiceOrder(serviceOrder, device: "en17") == "Baiwang")
    check("网络服务解析（en0 → Wi-Fi）",
          HostNetwork.parseServiceOrder(serviceOrder, device: "en0") == "Wi-Fi")
    check("网络服务解析（无关接口返回空）",
          HostNetwork.parseServiceOrder(serviceOrder, device: "en9") == nil)
    check("网络服务解析（空输入不崩）",
          HostNetwork.parseServiceOrder("", device: "en0") == nil)

    // A port line terminates the name above it, so a device that does not
    // match must not inherit the previous entry's name.
    let noTrailingPort = """
    (1) Wi-Fi
    (Hardware Port: Wi-Fi, Device: en0)
    (2) Baiwang
    """
    check("网络服务解析（没有硬件端口行时不误配）",
          HostNetwork.parseServiceOrder(noTrailingPort, device: "en17") == nil)

    check("手动命令提示带 sudo 与引号",
          HostNetwork.manualCommand("Baiwang", true)
              == "sudo networksetup -setnetworkserviceenabled \"Baiwang\" on")

    // --- End-to-end against the in-memory module
    let simResults = runSimulatorSuite(check)
    passed += simResults.passed
    failed += simResults.failed

    let emptySlotResults = runEmptySlotSuite(check)
    passed += emptySlotResults.passed
    failed += emptySlotResults.failed

    let hkResults = runHongKongSuite(check)
    passed += hkResults.passed
    failed += hkResults.failed

    let loginResults = runLoginItemSuite(check)
    passed += loginResults.passed
    failed += loginResults.failed

    banner("通过 \(passed) 项，失败 \(failed) 项")
    // Machine-readable tail: install.sh reports the count to the customer, and
    // a number written into a shell script by hand goes stale — the "118 项"
    // it used to print had been wrong since the suite grew past it.
    print("SELFTEST ok=\(passed) fail=\(failed)")
    return failed == 0
}

/// Start-at-login is the one feature whose failure is invisible: a Mac that
/// reboots without the app looks the same as a Mac whose module is unplugged.
/// The parts that can be checked without writing to the real `~/Library` are
/// the plist it produces and the path arithmetic that decides what to point at.
func runLoginItemSuite(_ check: (String, @autoclosure () -> Bool) -> Void) -> (passed: Int, failed: Int) {
    banner("开机自启")
    var passed = 0
    var failed = 0
    func verify(_ name: String, _ condition: @autoclosure () -> Bool) {
        let value = condition()
        if value { passed += 1 } else { failed += 1 }
        check(name, value)
    }

    let app = URL(fileURLWithPath: "/Applications/DJI4G.app")
    let plist = LoginItem.plist(binaryPath: LoginItem.executablePath(inApp: app))

    verify("可执行文件指向 App 内的主程序",
          LoginItem.executablePath(inApp: app) == "/Applications/DJI4G.app/Contents/MacOS/DJI4GMenuBar")
    verify("plist 里的 Label 与包标识一致",
          plist.contains("<string>\(LoginItem.label)</string>"))
    verify("登录时自动运行（RunAtLoad 为真）",
          plist.contains("<key>RunAtLoad</key>\n\t<true/>"))
    // Two failures pull in opposite directions here. Quietly restarting an app
    // the user just chose to quit with the 退出 button is worse than not
    // starting it at all. But staying quiet after a *crash* is worse still:
    // nothing on screen changes, and every call that arrives from then on is a
    // missed one. `SuccessfulExit = false` is the only spelling that separates
    // them — launchd revives the job when it dies badly and leaves it alone
    // when it exits cleanly.
    verify("手动退出后不会被重新拉起（KeepAlive.SuccessfulExit 为假）",
          plist.contains("<key>KeepAlive</key>\n\t<dict>\n\t\t<key>SuccessfulExit</key>\n\t\t<false/>\n\t</dict>"))
    verify("崩溃后会被 launchd 重新拉起（KeepAlive 不是一刀切的 false）",
          !plist.contains("<key>KeepAlive</key>\n\t<false/>"))
    verify("plist 头两行是合法的 XML 声明与 DOCTYPE",
          plist.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist"))
    verify("路径能原样读回来",
          LoginItem.binaryPath(inPlist: plist) == "/Applications/DJI4G.app/Contents/MacOS/DJI4GMenuBar")

    // A home directory is allowed to contain any of these, and an unescaped one
    // makes launchd reject the file without saying so.
    let awkward = "/Users/a&b/My <Apps>/DJI4G.app/Contents/MacOS/DJI4GMenuBar"
    let escaped = LoginItem.plist(binaryPath: awkward)
    verify("路径里的 & 与 < 被转义", escaped.contains("a&amp;b") && escaped.contains("My &lt;Apps&gt;"))
    verify("转义后能原样读回来", LoginItem.binaryPath(inPlist: escaped) == awkward)

    verify("从 App 内的工具反推出 App 本体",
          LoginItem.appBundle(containing: URL(fileURLWithPath:
              "/Applications/DJI4G.app/Contents/Resources/dji4gctl"))
              == URL(fileURLWithPath: "/Applications/DJI4G.app"))
    verify("跟着软链找到真实位置（/usr/local/bin 那条）",
          LoginItem.appBundle(containing: URL(fileURLWithPath:
              "/Applications/DJI4G.app/Contents/Resources/dji4gctl").resolvingSymlinksInPath())
              == URL(fileURLWithPath: "/Applications/DJI4G.app"))
    // .build/release/dji4gctl must not register a login item pointing into a
    // scratch directory that will be gone tomorrow.
    verify("开发时的裸二进制不会被当成 App",
          LoginItem.appBundle(containing: URL(fileURLWithPath:
              "/Users/me/work/.build/release/dji4gctl")) == nil)
    verify("plist 落在 ~/Library/LaunchAgents",
          LoginItem.plistURL.path.hasSuffix("/Library/LaunchAgents/\(LoginItem.label).plist"))

    return (passed, failed)
}

/// Drives the whole stack — transport, AT session, SMS, calls, data — against
/// the in-memory EG25-G. A hung or mis-parsed command shows up here rather than
/// only when the module is plugged in.
func runSimulatorSuite(_ check: (String, @autoclosure () -> Bool) -> Void) -> (passed: Int, failed: Int) {
    var passed = 0
    var failed = 0
    func verify(_ name: String, _ condition: @autoclosure () -> Bool) {
        let value = condition()
        if value { passed += 1 } else { failed += 1 }
        check(name, value)
    }

    banner("模拟器端到端")

    let sim = SimulatedATTransport()
    let controller = ModemController(session: ATSession(factory: { sim }))
    do {
        try controller.connect()
    } catch {
        verify("连接模拟模块（\(error)）", false)
        return (passed, failed)
    }

    verify("型号识别", controller.identity.model.contains("EG25"))
    verify("IMEI 读取", controller.identity.imei == "860123456789012")
    verify("SIM 就绪", controller.sim.ready)
    verify("网络已注册", controller.network.dataRegistered)
    verify("运营商识别（46000 → 移动）", controller.network.carrier.shortName == "移动")
    verify("信号解析（CSQ 22 → -69 dBm）", controller.signal.rssiDBm == -69)
    verify("USB 组态读到出厂值", controller.data.status.composition?.flagString == "1,1,1,1,1,0,0")
    verify("出厂组态无模块声卡", controller.data.status.composition?.supportsVoice == false)
    verify("APN 可下发", (try? controller.data.configureAPN("CTNET")) != nil)
    verify("APN 可回读", (try? controller.data.readAPN()) ?? nil == "CTNET")
    // APN 是嵌进带引号 AT 字符串的字段：引号/逗号/换行/空串都必须挡在门外。
    verify("APN 拒绝引号", (try? controller.data.configureAPN("bad\"apn")) == nil)
    verify("APN 拒绝逗号", (try? controller.data.configureAPN("bad,apn")) == nil)
    verify("APN 拒绝换行", (try? controller.data.configureAPN("bad\napn")) == nil)
    verify("APN 拒绝空串", (try? controller.data.configureAPN("  ")) == nil)
    verify("APN 用户名拒绝引号", (try? controller.data.configureAPN("CTNET", username: "u\"x")) == nil)

    // 截图夹具钉住的字节数，轮询不许把它冲掉。这台机器上只要插着模块，
    // 真网卡的流量就会飘进截图：环形从「剩 43%」变成「剩 100%」，底部那行
    // 印的是别人电脑上的数字。钉住以后不管插不插模块，画面都一样。
    controller.data.overrideCounters(bytesIn: 172_000_000_000, bytesOut: 700_000_000)
    let pinnedStatus = controller.data.refreshStatus()
    verify("钉住的字节数刷新后仍在（\(pinnedStatus.bytesIn + pinnedStatus.bytesOut)）",
           pinnedStatus.bytesIn + pinnedStatus.bytesOut == 172_700_000_000)
    verify("钉住的计数来源跟着走（面板才印「模块计数」）",
           pinnedStatus.counterSource == .module)

    // 设置窗里那排运营商按钮：每个按钮必须带自己那一家的 APN。以前三个按钮
    // 传的是同一个调用、名字被丢掉，于是点哪一家都一样（而且没插卡时那条路
    // 直接静默返回 nil，点了什么都不会发生）。
    verify("运营商按钮自带各自的 APN",
           CarrierCatalog.mainlandChina.map(\.apn) == ["CMNET", "3GNET", "CTNET", "CBNET"])
    verify("按 AT+COPS? 的名字也能认出运营商（CHINA TELECOM → CTNET）",
           CarrierCatalog.carrier(forOperatorName: "CHINA TELECOM")?.apn == "CTNET")
    verify("名字里的杂音不影响识别（\"CHN-UNICOM\" → 3GNET）",
           CarrierCatalog.carrier(forOperatorName: "CHN-UNICOM")?.apn == "3GNET")
    do {
        let apn = try controller.applyCarrierAPN(force: true,
                                                 carrier: CarrierCatalog.carrier(forMCCMNC: "46011"))
        verify("点「电信」写进去的是 CTNET（\(apn)）", apn == "CTNET")
        verify("点「电信」之后回读一致", (try? controller.data.readAPN()) ?? nil == "CTNET")
    } catch {
        verify("点「电信」写进去的是 CTNET（\(error)）", false)
    }

    // Mailbox: one seeded message.
    let seeded = (try? controller.sms.refresh()) ?? []
    verify("收件箱读取（\(seeded.count) 条）", seeded.count == 1)
    verify("中文短信解码", seeded.first?.text == "模块就绪，这是一条模拟短信。")
    verify("发件人解析", seeded.first?.sender == "10086")
    verify("时间戳解析（\(seeded.first?.timestamp.map { "\($0)" } ?? "无")）",
           seeded.first?.timestamp != nil)

    // Sending: long Chinese text exercises the UCS-2 concat encoder and the
    // Ctrl-Z commit path.
    let longText = String(repeating: "这是一条很长的中文测试短信内容。", count: 6)
    let sentParts = (try? controller.sms.send(text: longText, to: "10086")) ?? 0
    verify("长短信发送（\(sentParts) 段）", sentParts >= 2)

    // The module stores what it sent; the mailbox should now hold both, and the
    // sent copy is an SMS-SUBMIT PDU that the codec has to recognise.
    let afterSend = (try? controller.sms.refresh()) ?? []
    verify("发件箱可读回（\(afterSend.count) 条）", afterSend.count == 2)
    verify("已发送长短信被重新拼接", afterSend.contains { $0.text == longText })

    // Receiving: a two-part message announced by +CMTI.
    sim.injectMultipartSMS(parts: ["这是第一段，", "这是第二段。"], from: "10690001")
    _ = controller.session.pollUnsolicited(timeout: 0.4)
    let afterIncoming = controller.sms.messages
    if !afterIncoming.contains(where: { $0.text == "这是第一段，这是第二段。" }) {
        for message in afterIncoming {
            print("      · [\(message.storageIndex)] \(message.sender)"
                  + " ref=\(message.reference.map(String.init) ?? "-")"
                  + "/\(message.totalParts.map(String.init) ?? "-")"
                  + "/\(message.partIndex.map(String.init) ?? "-")"
                  + " \(message.status) «\(message.text.prefix(16))»")
        }
    }
    verify("长短信自动合并（\(afterIncoming.count) 条）",
           afterIncoming.contains { $0.text == "这是第一段，这是第二段。" })
    verify("未读标记", afterIncoming.contains { $0.isUnread && $0.sender == "10690001" })

    // 「条数」和「格数」是两回事，但两本账必须能对上。
    //
    // 2026-09-26 真机上卡在这里：小屏写「6 条」，存储写「7/40」，中间那条短信像
    // 是丢了。查下来是 slot 3+4 是同一组长短信。数据没丢，但界面上两个数并排
    // 出现却对不上，客户只能自己猜 —— 所以这里钉住不变量：每条消息记的占格数之
    // 和，必须等于模块报的已用格数。不等就是真有短信没进列表，界面会报警
    // （见 `SMSDetail.reconciliation`）。
    let mergedLong = afterIncoming.first { $0.text == "这是第一段，这是第二段。" }
    verify("合并后记 2 格（\(mergedLong?.segmentCount ?? -1)）", mergedLong?.segmentCount == 2)
    let slots = afterIncoming.reduce(0) { $0 + $1.segmentCount }
    _ = try? controller.sms.refreshStorage()
    let used = controller.sms.storage.used
    verify("格数账对得上（列表 \(slots) 格 / 模块 \(used) 格）", slots == used)
    verify("没有解不开的 PDU（\(controller.sms.decodeFailures.count) 条）",
           controller.sms.decodeFailures.isEmpty)

    // Calls.
    sim.simulateIncomingCall(from: "+8613800138000")
    _ = controller.session.pollUnsolicited(timeout: 0.4)
    verify("来电振铃", controller.calls.current.state == .ringing)
    verify("来电号码", controller.calls.current.number == "+8613800138000")
    _ = try? controller.calls.answer()
    verify("接听", controller.calls.current.state == .active)

    // Call waiting, end to end: a second caller arrives while the first is up.
    sim.simulateIncomingCall(from: "+8613900139000")
    _ = controller.session.pollUnsolicited(timeout: 0.4)
    verify("通话中第二路来电显示为等待接听", controller.calls.current.state == .waiting)
    verify("等待来电号码", controller.calls.current.number == "+8613900139000")
    _ = try? controller.calls.refresh()
    verify("轮询后等待来电仍在（双 CLCC 行不会把它抹掉）",
           controller.calls.current.state == .waiting
           && controller.calls.current.number == "+8613900139000")
    _ = try? controller.calls.reject()
    verify("拒接等待来电后原通话继续（CHLD=0 不会挂断整通电话）",
           controller.calls.current.state == .active
           && controller.calls.current.number == "+8613800138000")

    sim.simulateIncomingCall(from: "+8613900139000")
    _ = controller.session.pollUnsolicited(timeout: 0.4)
    _ = try? controller.calls.answer()
    _ = try? controller.calls.refresh()
    verify("接听等待来电（CHLD=2 保持原通话并切到新的那路）",
           controller.calls.current.state == .active
           && controller.calls.current.number == "+8613900139000")

    sim.simulateRemoteHangup()
    _ = controller.session.pollUnsolicited(timeout: 0.4)
    verify("对方挂断后回到空闲", controller.calls.current.state == .idle)

    // Data.
    _ = try? controller.data.activatePDP()
    let counters = (try? controller.data.moduleCounters()) ?? nil
    verify("流量计数（AT+QGDCNT）", counters != nil)

    controller.disconnect()
    return (passed, failed)
}

/// The same stack as `runSimulatorSuite`, with an empty card slot. Everything
/// that does not touch the SIM has to keep working, and everything that does has
/// to fail with an answer a person can act on.
func runEmptySlotSuite(_ check: (String, @autoclosure () -> Bool) -> Void) -> (passed: Int, failed: Int) {
    var passed = 0
    var failed = 0
    func verify(_ name: String, _ condition: @autoclosure () -> Bool) {
        let value = condition()
        if value { passed += 1 } else { failed += 1 }
        check(name, value)
    }

    banner("模拟器端到端（卡座是空的）")

    let sim = SimulatedATTransport(scenario: .noSIM)
    let controller = ModemController(session: ATSession(factory: { sim }))
    do {
        try controller.connect()
    } catch {
        verify("连接没有卡的模拟模块（\(error)）", false)
        return (passed, failed)
    }

    verify("没有卡时报「未检测到 SIM 卡」", controller.sim.label.contains("未检测到 SIM 卡"))
    verify("没有卡时 state 是 missing", controller.sim.state == .missing)
    verify("没有卡时不误报需要 PIN", !controller.sim.pinRequired && controller.sim.state != .pinRequired)
    verify("卡座检测位读到了「没有卡」", controller.sim.detectedInserted == false)
    verify("提示里给出插卡动作", controller.sim.guidance.contains("卡托"))

    // 不碰卡的功能照常工作 —— 这正是"卡还没到"时用户要确认的部分。
    verify("型号照常读到", controller.identity.model.contains("EG25"))
    verify("IMEI 照常读到", controller.identity.imei == "860123456789012")
    verify("USB 组态照常读到", controller.data.status.composition?.flagString == "1,1,1,1,1,0,0")
    verify("信号照常读到", controller.signal.rssiDBm == -69)

    // 卡绑定操作失败，但失败信息要说得清是什么原因。
    do {
        try controller.calls.dial("10086")
        verify("没有卡时拨号应该失败", false)
    } catch {
        let text = "\(error)"
        verify("拨号失败信息提到 SIM（\(text)）", text.contains("SIM"))
        verify("拨号失败信息不再只有裸错误码", !text.hasPrefix("模块拒绝操作：+CME"))
    }

    do {
        _ = try controller.sms.send(text: "测试", to: "10086")
        verify("没有卡时发短信应该失败", false)
    } catch {
        let text = "\(error)"
        verify("发短信失败信息提到 SIM（\(text)）", text.contains("SIM"))
    }

    // APN：没卡时模块多半报不出运营商，自动那条路必须给出明确结果 —— 成功就
    // 报出 APN，失败就说清为什么，不能像以前那样返回 nil 静默什么都不做。
    do {
        let apn = try controller.applyCarrierAPN(force: true)
        verify("没卡时自动配 APN 也有明确结果（\(apn)）", !apn.isEmpty)
    } catch {
        verify("没卡时自动配 APN 说清了原因（\(error)）",
               "\(error)".contains("运营商") && "\(error)".contains("插卡"))
    }

    // 而运营商按钮在没卡时必须照样能用 —— 这是「卡还没到」时唯一能提前做对
    // 的一件事：先把 APN 写进去，卡一到就能联网。
    do {
        let apn = try controller.applyCarrierAPN(force: true,
                                                 carrier: CarrierCatalog.carrier(forMCCMNC: "46003"))
        verify("没卡时点「电信」也能写进 CTNET（\(apn)）", apn == "CTNET")
        verify("没卡时写完能回读", (try? controller.data.readAPN()) ?? nil == "CTNET")
    } catch {
        verify("没卡时点「电信」也能写进 CTNET（\(error)）", false)
    }

    // 读不到运营商时，模块里已有的 APN 不能被抹掉 —— 那是唯一能让它联网的东西。
    do {
        let kept = try controller.applyCarrierAPN(force: true, carrier: .unknown)
        verify("读不到运营商时保留模块里已有的 APN（\(kept)）",
               kept == "CTNET" && ((try? controller.data.readAPN()) ?? nil) == "CTNET")
    } catch {
        verify("读不到运营商时保留模块里已有的 APN（\(error)）", false)
    }

    // 既读不到运营商、模块里也没有 APN：必须抛错说清原因，而且不许瞎写。
    let blank = SimulatedATTransport(scenario: .noSIM)
    blank.carrierMCCMNC = ""
    blank.carrierName = ""
    let blankController = ModemController(session: ATSession(factory: { blank }))
    if (try? blankController.connect()) != nil {
        do {
            _ = try blankController.applyCarrierAPN(force: true)
            verify("读不到运营商又没 APN 时必须报错", false)
        } catch {
            verify("报错说清了是没插卡（\(error)）",
                   "\(error)".contains("运营商") && "\(error)".contains("插卡"))
        }
        verify("报错之后也没有往模块里瞎写",
               (((try? blankController.data.readAPN()) ?? nil) ?? "").isEmpty)
        // 同样地：看一眼当前 APN 不该改东西，也不该因为读不到而只说一句空话。
        let blankReport = apnReport(blankController)
        verify("读不到运营商时，看一眼 APN 的报告让人去插卡（\(blankReport.replacingOccurrences(of: "\n", with: " "))）",
               blankReport.contains("插卡"))
        verify("读不到运营商时，报告里也没有谎报一个 APN",
               (((try? blankController.data.readAPN()) ?? nil) ?? "").isEmpty)
        blankController.disconnect()
    } else {
        verify("连接空白模拟模块", false)
    }

    // `dji4gctl apn` 不带参数时是只读的。它以前走「自动配 APN」那条路：客户
    // 只是想看一眼当前值，模块里就被写进了 CMNET —— 对移动 / 联通 / 广电的卡
    // 来说，这一下正好是把原本对的 APN 改错，而客户什么都没点过。
    do {
        let before = (try? controller.data.readAPN()) ?? nil
        let report = apnReport(controller)
        let after = (try? controller.data.readAPN()) ?? nil
        verify("看一眼 APN 不会顺手改模块（\(before ?? "空") → \(after ?? "空")）", before == after)
        verify("看一眼 APN 报的是模块里的那个值（\(report.replacingOccurrences(of: "\n", with: " "))）",
               after.map { report.contains($0) } ?? true)
    }

    controller.disconnect()
    return (passed, failed)
}

/// 香港 SIM 兼容性：运营商表、IMSI 归属、漫游时 APN 跟卡走、+852 号码处理。
/// 全程跑在内存模拟模块上，不碰真机。
func runHongKongSuite(_ check: (String, @autoclosure () -> Bool) -> Void) -> (passed: Int, failed: Int) {
    var passed = 0
    var failed = 0
    func verify(_ name: String, _ condition: @autoclosure () -> Bool) {
        let value = condition()
        if value { passed += 1 } else { failed += 1 }
        check(name, value)
    }

    banner("香港 SIM 兼容（模拟）")

    // ── 1. 运营商表：APN 必须是对的，CMHK 不再是 CMNET、3HK 不再是 3gnet。
    verify("CMHK APN = cmhk（不再错配成 CMNET）",
           CarrierCatalog.carrier(forMCCMNC: "45412").apn == "cmhk")
    verify("3HK APN = mobile.lte.three.com.hk（不再错配成 3gnet）",
           CarrierCatalog.carrier(forMCCMNC: "45403").apn == "mobile.lte.three.com.hk")
    verify("SmarTone APN = smartone",
           CarrierCatalog.carrier(forMCCMNC: "45406").apn == "smartone")
    verify("CSL APN = mobile",
           CarrierCatalog.carrier(forMCCMNC: "45400").apn == "mobile")
    verify("香港按钮列表含 CMHK / 3HK / SmarTone / CSL / 1010",
           ["CMHK", "3HK", "SmarTone", "CSL", "1010"]
               .allSatisfy { s in CarrierCatalog.hongKong.contains { $0.shortName == s } })
    verify("大陆四家 APN 原样保留（CMNET/3GNET/CTNET/CBNET）",
           CarrierCatalog.mainlandChina.map(\.apn) == ["CMNET", "3GNET", "CTNET", "CBNET"])
    verify("MCC 454 归香港", CarrierCatalog.region(forMCC: "454") == .hongKong)
    verify("MCC 460 归大陆", CarrierCatalog.region(forMCC: "460") == .mainlandChina)

    // ── 2. IMSI 归属识别。
    verify("IMSI 45412 → CMHK", CarrierCatalog.carrier(forIMSI: "454120123456789").shortName == "CMHK")
    verify("IMSI 45403 → 3HK", CarrierCatalog.carrier(forIMSI: "454030123456789").shortName == "3HK")
    verify("IMSI 45406 → SmarTone", CarrierCatalog.carrier(forIMSI: "454060123456789").shortName == "SmarTone")
    verify("IMSI 45400 → CSL", CarrierCatalog.carrier(forIMSI: "454000123456789").shortName == "CSL")
    verify("IMSI 46000 → 移动", CarrierCatalog.carrier(forIMSI: "460001234567890").shortName == "移动")
    verify("未知 MCC（901）不给 APN（不猜）",
           CarrierCatalog.carrier(forIMSI: "901700123456789").apn.isEmpty)
    verify("空 IMSI 不给 APN", CarrierCatalog.carrier(forIMSI: "").apn.isEmpty)

    // ── 3. 香港卡在大陆漫游：APN 跟卡走，不跟驻留网络走。
    do {
        let sim = SimulatedATTransport()
        sim.imsi = "454120123456789"       // CMHK 卡
        sim.carrierMCCMNC = "46000"        // 驻留到大陆中国移动
        sim.carrierName = "CHINA MOBILE"
        sim.setRegistration(5)             // 漫游
        let controller = ModemController(session: ATSession(factory: { sim }))
        do { try controller.connect() }
        catch {
            verify("连接漫游模拟模块（\(error)）", false)
            return (passed, failed)
        }
        verify("SIM 归属识别为 CMHK", controller.sim.homeCarrier.shortName == "CMHK")
        verify("驻留网络识别为中国移动", controller.network.carrier.shortName == "移动")
        verify("识别为漫游", controller.network.isRoaming)
        do {
            let apn = try controller.applyCarrierAPN(force: true)
            verify("漫游时写的是 cmhk 不是 CMNET（\(apn)）", apn == "cmhk")
        } catch {
            verify("漫游时写的是 cmhk（异常：\(error)）", false)
        }
        controller.disconnect()
    }

    // ── 4. 识别不出运营商 → 不猜，拒绝写入。
    do {
        let sim = SimulatedATTransport()
        sim.imsi = "901700123456789"
        sim.carrierName = "SOME NETWORK"
        let controller = ModemController(session: ATSession(factory: { sim }))
        do { try controller.connect() }
        catch {
            verify("连接未知卡模拟模块（\(error)）", false)
            return (passed, failed)
        }
        verify("未知卡归属无 APN", controller.sim.homeCarrier.apn.isEmpty)
        let before = (try? controller.data.readAPN()) ?? nil
        _ = try? controller.applyCarrierAPN(force: true)
        let after = (try? controller.data.readAPN()) ?? nil
        verify("识别不出时不写 APN（\(before ?? "空") → \(after ?? "空")）", before == after)
        controller.disconnect()
    }

    // ── 5. +852 号码：拨号与短信都不强制 +86。
    do {
        let pdu = try PDUSubmit.encode(text: "hi", to: "+85291234567").first ?? ""
        let decoded = try PDUCodec.decodeSubmit(pdu)
        verify("+852 短信收件人往返（\(decoded.sender)）", decoded.sender == "+85291234567")
    } catch {
        verify("+852 短信往返（异常：\(error)）", false)
    }
    do {
        let sim = SimulatedATTransport()
        let controller = ModemController(session: ATSession(factory: { sim }))
        try controller.connect()
        try controller.calls.dial("+85291234567")
        verify("+852 拨号保留国际前缀（\(controller.calls.current.number)）",
               controller.calls.current.number == "+85291234567")
        controller.disconnect()
    } catch {
        verify("+852 拨号（异常：\(error)）", false)
    }

    return (passed, failed)
}

/// Decodes a sent (SMS-SUBMIT) PDU through the same code path the app uses,
/// so the round-trip test exercises production decoding rather than a rewrite.
func stripAndDecodeSubmit(_ tpdu: [UInt8], index: Int) -> SMSMessage {
    // decodeSubmit expects a whole PDU, so re-attach an empty service centre.
    let hex = "00" + PDUCodec.hex(from: tpdu)
    return (try? PDUCodec.decodeSubmit(hex, storageIndex: index)) ?? SMSMessage(storageIndex: index)
}

// MARK: - Presentation helpers

func printIdentity(_ controller: ModemController) {
    let identity = controller.identity
    field("型号", identity.displayName)
    field("固件", identity.revision.isEmpty ? "未知" : identity.revision)
    if !identity.firmwareBuild.isEmpty { field("构建", identity.firmwareBuild) }
    field("IMEI", identity.imei.isEmpty ? "未知" : identity.imei)
    // 认出来的命令族。这块模块的信号、温度、频段是从哪一套命令读出来的 ——
    // 客户那边读数是 `--` 的时候，第一眼要看的就是这一行对不对。
    field("命令族", controller.profile.displayName)
    if !identity.temperatures.isEmpty {
        field("温度", identity.temperatures.joined(separator: "°C / ") + "°C")
    }
}

func printSIM(_ controller: ModemController) {
    let sim = controller.sim
    field("SIM", sim.label)
    if !sim.ready, !sim.guidance.isEmpty { field("", "→ \(sim.guidance)") }
    if !sim.imsi.isEmpty { field("IMSI", sim.imsi) }
    if !sim.iccid.isEmpty { field("ICCID", sim.iccid) }
    if !sim.ownNumber.isEmpty { field("本机号码", sim.ownNumber) }
}

func printNetwork(_ controller: ModemController) {
    let network = controller.network
    let signal = controller.signal
    field("注册", network.reportedRegistration.label)
    field("运营商", network.carrier.name)
    field("制式", network.accessTechnology.isEmpty ? "未知" : network.accessTechnology)
    if !network.band.isEmpty { field("频段", network.band) }
    if let channel = network.channel { field("频点", "\(channel)") }
    field("信号", signal.label)
    if let rsrp = signal.rsrp { field("RSRP", String(format: "%.0f dBm", rsrp)) }
    if let rsrq = signal.rsrq { field("RSRQ", String(format: "%.0f dB", rsrq)) }
    if let sinr = signal.sinr { field("SINR", String(format: "%.1f dB", sinr)) }
    if let rssi = signal.rssiDBm { field("RSSI", "\(rssi) dBm") }
}

func printData(_ controller: ModemController) {
    let data = controller.data.status
    field("接口", data.interfaceName.isEmpty ? "未找到" : data.interfaceName)
    field("IPv4", data.ipv4Address.isEmpty ? "无" : data.ipv4Address)
    if let mode = data.usbnetMode { field("USB 网络", mode.technicalName) }
    if let composition = data.composition { field("USB 组态", composition.flagString) }
    if !data.apn.isEmpty { field("APN", data.apn) }
    field("Mac 网络服务", data.serviceLabel)
    field("已接收", DataStatus.format(data.bytesIn))
    field("已发送", DataStatus.format(data.bytesOut))
}

func printMessages(_ messages: [SMSMessage]) {
    guard !messages.isEmpty else {
        print("  （没有短信）")
        return
    }
    for message in messages {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        let stamp = message.timestamp.map { formatter.string(from: $0) } ?? "--"
        let flag = message.isUnread ? "●" : " "
        print("  \(flag) [\(message.storageIndex)] \(stamp)  \(message.sender)")
        print("      \(message.text.replacingOccurrences(of: "\n", with: "\n      "))")
    }
}

func printCall(_ calls: CallService) {
    let info = calls.current
    field("状态", info.state.label)
    if !info.number.isEmpty { field("号码", info.number) }
    if info.state == .active { field("时长", info.durationLabel) }
}

// MARK: - Doctor

/// Collects one snapshot for the report.
///
/// Every probe past the liveness check is individually optional: a module that
/// answers `AT` but fails `AT+CPMS?` should still produce a report that says so,
/// instead of aborting the run and hiding the other twelve answers.
func gatherDoctorFacts(_ controller: ModemController) -> DoctorFacts {
    var facts = DoctorFacts()
    guard controller.session.isOpen else { return facts }
    facts.transport = controller.session.channelDescription

    // Liveness first: without it every later probe fails for the same reason,
    // and six identical failures read worse than one.
    guard let probe = try? controller.session.send("AT", timeout: 3),
          probe.final == .ok else { return facts }
    facts.atResponsive = true

    _ = try? controller.refreshSIM()
    _ = try? controller.refreshNetwork()
    _ = try? controller.refreshSignal()
    _ = controller.refreshData()
    // `connect()` 里已经读过一次，但报告不该依赖别人先读过：这里读回空，就会
    // 变成客户面前那句「未设置，PDP 无法激活」。
    _ = try? controller.data.readAPN()

    facts.firmware = controller.identity.revision
    facts.imei = controller.identity.imei
    facts.simReady = controller.sim.ready
    facts.simDetail = controller.sim.ready ? "已就绪" : controller.sim.label
    facts.simFix = controller.sim.ready ? "" : controller.sim.guidance
    facts.registered = controller.network.dataRegistered
    facts.carrier = controller.network.carrier.name
    facts.signalDBm = controller.signal.label

    facts.usbnetMode = controller.data.status.usbnetMode
    facts.composition = controller.data.status.composition
    facts.apn = controller.data.status.apn
    facts.interfaceName = controller.data.status.interfaceName
    facts.ipv4 = controller.data.status.ipv4Address
    facts.serviceName = controller.data.status.serviceName
    facts.serviceEnabled = controller.data.status.serviceEnabled

    if let device = controller.voice.refreshStatus().moduleDevice {
        facts.hasModuleAudio = true
        facts.audioDeviceName = device.name
    }

    if let storage = try? controller.sms.refreshStorage(), storage.total > 0 {
        facts.smsStorage = storage.label
        facts.smsStorageFull = storage.isFull
    }
    if let messages = try? controller.sms.refresh() {
        facts.smsUnread = messages.filter(\.isUnread).count
    }
    return facts
}

func printDoctor(_ facts: DoctorFacts) -> Int32 {
    let checks = Doctor.evaluate(facts)
    for check in checks {
        print("  \(check.state.symbol) \(check.title)：\(check.detail)")
        if check.state.blocks, let fix = check.fix {
            print("      → \(fix)")
        }
    }

    print("")
    for capability in Capability.allCases {
        let ready = Doctor.isReady(capability, in: checks)
        print("  \(ready ? "可用" : "不可用")  \(capability.label)")
    }

    let fixes = Doctor.pendingFixes(checks)
    if fixes.isEmpty {
        print("")
        print("  三项功能都已就绪。")
        return 0
    }
    print("")
    print("  按顺序执行即可：")
    for (index, fix) in fixes.enumerated() {
        print("  \(index + 1). \(fix)")
    }
    // 没插卡的时候，前面那张表里好几步其实不用等卡。不写这一句，客户会
    // 把模块收起来等卡到 —— 而这几步正是趁没卡的时候做最省事。
    if let note = Doctor.noCardNote(facts) {
        print("")
        print("  \(note)")
    }
    return 1
}

// MARK: - Start at login

/// `dji4gctl autostart <on|off|status> [App 路径]`
///
/// The installer and the app's own settings window both end up here, so there
/// is one implementation of what "开机自启" means rather than a shell version
/// and a Swift version that drift apart.
func runAutostart() -> Int32 {
    banner("开机自启")
    let rest = arguments.drop { $0 != "autostart" }.dropFirst().filter { !$0.hasPrefix("--") }
    let action = (rest.first ?? "status").lowercased()

    switch action {
    case "status":
        return printAutostartStatus()

    case "on", "enable", "install":
        guard let app = resolveAppBundle() else {
            print("  ✗ 找不到 App 本体。")
            print("")
            print("    这个命令要知道给哪个 App 注册开机自启。自动找不到时手动指定：")
            print("      dji4gctl autostart on \"/Applications/DJI4G.app\"")
            return 1
        }
        let binary = LoginItem.executablePath(inApp: app)
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            print("  ✗ \(app.path) 里没有可执行的主程序：")
            print("      \(binary)")
            print("")
            print("    这台机器上可能还没装 App，或者路径给错了。")
            return 1
        }
        do {
            try LoginItem.install(app: app)
        } catch {
            print("  ✗ 写不进去：\(error)")
            return 1
        }
        field("程序", binary)
        field("文件", LoginItem.plistURL.path)
        print("")
        print("  ✓ 已开启。下次登录 macOS 会自动把它拉起来，不需要管理员密码。")
        print("    想立刻验证：重启一次，看菜单栏右上角有没有图标。")
        return 0

    case "off", "disable", "remove":
        let was = LoginItem.status().installed
        do {
            try LoginItem.remove()
        } catch {
            print("  ✗ 删不掉：\(error)")
            return 1
        }
        print(was ? "  ✓ 已关闭。重启后不会再自动运行。" : "  本来就没开，无需改动。")
        return 0

    default:
        print("  用法：dji4gctl autostart <on|off|status> [App 路径]")
        return 2
    }
}

func printAutostartStatus() -> Int32 {
    let status = LoginItem.status()
    field("状态", status.installed ? "已开启" : "未开启")
    if let path = status.binaryPath { field("程序", path) }
    field("文件", LoginItem.plistURL.path)
    field("说明", status.detail)
    if !status.installed {
        print("")
        print("  开启：dji4gctl autostart on")
    }
    return status.installed ? 0 : 1
}

/// Which app to register. An explicit argument wins; otherwise the path of the
/// running tool is walked back up to its bundle, so a copy installed anywhere
/// registers itself rather than a hard-coded /Applications path.
func resolveAppBundle() -> URL? {
    let rest = arguments.drop { $0 != "autostart" }.dropFirst().filter { !$0.hasPrefix("--") }
    if let explicit = rest.dropFirst().first {
        return URL(fileURLWithPath: explicit)
    }
    if let own = arguments.first, let derived = LoginItem.appBundle(containing: URL(fileURLWithPath: own)) {
        return derived
    }
    for candidate in ["/Applications/DJI4G.app", NSHomeDirectory() + "/Applications/DJI4G.app"]
    where FileManager.default.fileExists(atPath: candidate) {
        return URL(fileURLWithPath: candidate)
    }
    return nil
}

// MARK: - Commands

/// The one diagnostic that survives the module being held by another process:
/// it reads IORegistry only and never claims the device. Prints whatever is
/// attached and reports back whether anything was found.
@discardableResult
/// 谁占着 AT 接口 —— 只是给收尾提示用，没有就当没人占。
func heldATInterfaceOwner() -> String? {
    for inventory in USBInventory.readAll() {
        if let held = inventory.atInterface, held.isHeld { return held.owner }
    }
    return nil
}

func printUSBReport() -> Bool {
    let inventories = USBInventory.readAll()
    guard !inventories.isEmpty else {
        print("  没有检测到模块（USB 未插入，或不是认得的模块）")
        for identity in USBModuleIdentity.supported {
            print("    \(identity.hex)   \(identity.label)")
        }
        print("    认得的厂家：\(USBModuleIdentity.vendors.map { "\($0.name)（\(String(format: "%04X", $0.id))）" }.joined(separator: "、"))")
        return false
    }

    for inventory in inventories {
        field("模块", "\(inventory.identity.hex)   \(inventory.identity.label)")
        field("接口数", "\(inventory.interfaces.count)")
        if !inventory.holders.isEmpty {
            field("当前占用", inventory.holders.joined(separator: "、"))
        }
        print("")
        print("  接口   类别             端点   角色")
        for info in inventory.interfaces {
            let number = String(info.number).padding(toLength: 5, withPad: " ", startingAt: 0)
            let triplet = info.classTriplet.padding(toLength: 19, withPad: " ", startingAt: 0)
            let endpoints = String(info.endpointCount).padding(toLength: 7, withPad: " ", startingAt: 0)
            let held = info.isHeld ? "   ← 被 \(info.owner) 占用" : ""
            print("  \(number)\(triplet)\(endpoints)\(info.role.label)\(held)")
        }
        print("")
        field("模块声卡", inventory.hasAudioFunction ? "已开启" : "未开启（出厂状态）")
        field("USB 网卡", inventory.hasNetworkFunction ? "已开启" : "未开启（出厂状态）")

        if inventory.interfaces.contains(where: { $0.role == .unknown }) {
            print("")
            print("  · 「未知」是 usbcfg 里开着、但按类别认不出来的厂商接口。")
            print("    RNDIS 网卡（usbnet 0/2/3）就是这一类；切成 ECM 后它会变成 0x02，「USB 网卡」即显示为已开启。")
        }
    }

    if let heldAT = inventories.compactMap(\.atInterface).first(where: { $0.isHeld }) {
        print("")
        print("  ! AT 接口（接口 \(heldAT.number)）正被 \(heldAT.owner) 占用。")
        print("    菜单栏 App 运行时读不到模块，先退出它再执行其它命令。")
    }
    return true
}

/// `dji4gctl apn` 不带参数时的输出 —— 纯只读。
///
/// 这里以前走的是「自动配 APN」那条路：客户只是想看一眼当前值，模块里就被
/// 写进了 CMNET，而移动 / 联通 / 广电的卡照抄 CMNET 是连不上的。看一眼的前
/// 提下改东西，是这个分支最不该做的事。
func apnReport(_ controller: ModemController) -> String {
    if let existing = (try? controller.data.readAPN()) ?? nil, !existing.isEmpty {
        return "  当前 APN：\(existing)"
    }
    // 推荐按卡的归属配，不按驻留网络配：香港卡漫游时驻留是中国移动。
    let home = controller.sim.homeCarrier
    let carrier = home.apn.isEmpty ? controller.network.carrier : home
    if !carrier.apn.isEmpty {
        return "  模块里还没有 APN。这台模块认到的运营商是\(carrier.name)，\n"
            + "  写入：dji4gctl apn \(carrier.apn)"
    }
    return "  模块里还没有 APN，也读不到运营商（多半是还没插卡）。\n"
        + "  插卡后跑 dji4gctl apn 自动认运营商；\n"
        + "  或现在就指定一家：dji4gctl apn 移动 / 联通 / 电信 / 广电 / cmhk / 3hk"
}

func runOneShot(_ command: String, controller: ModemController) -> Int32 {
    // Two commands have to work before the module can be claimed: `usb` reads
    // IORegistry only, and `doctor` exists to explain why the claim failed.
    // Both therefore sit above the shared early exit.
    if command == "usb" {
        banner("USB 体检（只读，不占用模块）")
        return printUSBReport() ? 0 : 1
    }

    // Same reasoning as `usb`: this is a fact about the Mac, not about the
    // module. It has to answer on a machine where nothing is plugged in, which
    // is exactly when someone asks why the app did not come back after a reboot.
    if command == "autostart" {
        return runAutostart()
    }

    if command == "doctor" {
        banner("体检")
        do {
            try controller.connect()
        } catch {
            print("  ✗ USB 连接：\(error)")
            print("")
            _ = printUSBReport()
            print("")
            // 「线没插好」和「另一个 DJI4G 正开着」要的是相反的动作：一个去
            // 检查线，一个去退 App。`printUSBReport` 两种都印了，收尾这句不行。
            if let holder = heldATInterfaceOwner() {
                print("  模块其实已经连上了，只是 AT 接口正被 \(holder) 占用。")
                print("  退出正在运行的 DJI4G（点菜单栏图标 → 退出），再重跑这条命令。")
            } else {
                print("  模块没有连上。确认线插好，然后：")
                print("  system_profiler SPUSBDataType | grep -A 12 -i baiwang")
            }
            return 1
        }
        return printDoctor(gatherDoctorFacts(controller))
    }

    do {
        try controller.connect()
    } catch {
        print("连接模块失败：\(error)")
        print("看一下用法：dji4gctl help")
        return 1
    }

    do {
    switch command {
    case "status":
        banner("模块状态")
        printIdentity(controller)
        printSIM(controller)
        printNetwork(controller)
        _ = controller.refreshData()
        printData(controller)
        // `printCall` 读的是 `calls.current` 这份缓存，而这个命令是**一次性
        // 进程**：不先读一次 `AT+CLCC`，它会永远打印初始的「空闲」。2026-09-25
        // 真机排查时就是这样 —— 电话明明接通着（`+CLCC: 3,0,0,0,0,"10000",129`，
        // stat=0 即通话中），`status` 却报空闲，差点被当成通话链路坏了。
        _ = try? controller.refreshCalls()
        printCall(controller.calls)

    case "sms-list":
        banner("短信")
        let messages = try controller.sms.refresh()
        field("存储", controller.sms.storage.label)
        printMessages(messages)

    case "sms-send":
        let rest = argumentsAfter(command, in: arguments)
        let number = rest.first ?? ""
        let text = rest.dropFirst().joined(separator: " ")
        guard !number.isEmpty, !text.isEmpty else {
            print("用法：dji4gctl sms-send <号码> <内容>")
            return 2
        }
        banner("发送短信 → \(number)")
        let count = try controller.sms.send(text: text, to: number)
        print("  已提交 \(count) 条 PDU")

    case "sms-clear":
        banner("清空收件箱")
        let before = try controller.sms.refresh()
        if before.isEmpty {
            print("  收件箱本来就是空的。")
            break
        }
        print("  将要删除 \(before.count) 条（存在模块里，不是卡里）")
        try controller.sms.deleteAll()
        let after = try controller.sms.refresh()
        print("  ✓ 已清空：\(before.count) → \(after.count) 条")
        if !after.isEmpty {
            print("  ! 还剩 \(after.count) 条 —— 可能落在别的存储区，跑 dji4gctl sms-storage 看是哪个。")
        }

    case "sms-storage":
        banner("短信接收存储")
        let before = try controller.sms.refreshStorage()
        field("当前", "\(before.label)（\(before.isFull ? "已满" : "还有空位")）")
        guard let wanted = argumentsAfter(command, in: arguments).first else {
            print("")
            print("  用法：dji4gctl sms-storage <SM|ME|MT|SR>")
            print("  模块默认写 ME，那 23 个格子满了以后新短信会被网络直接丢掉。")
            print("  SIM 卡一般还有几十个空位，换过去即可：dji4gctl sms-storage SM")
            break
        }
        let after = try controller.sms.setStorage(wanted)
        print("")
        print("  ✓ 已切到 \(wanted.uppercased())，现在 \(after.label)")

    case "call-dial":
        let number = argumentsAfter(command, in: arguments).first ?? ""
        guard !number.isEmpty else {
            print("用法：dji4gctl call-dial <号码>")
            return 2
        }
        banner("拨号 → \(number)")
        try controller.calls.dial(number)
        print("  已发出，等待状态：\(controller.calls.current.state.label)")

    case "at":
        // 第二个参数是可选的等待秒数。`AT+COPS=?` 这类扫网命令按标准要跑
        // 二十秒到一分钟，写死 10 秒就只能看见「没回复」——那看不出模块是
        // 在忙、还是这条路本来就不通。
        var pieces = argumentsAfter(command, in: arguments)
        var wait: TimeInterval = 10
        if pieces.count > 1, let seconds = TimeInterval(pieces[pieces.count - 1]) {
            wait = seconds
            pieces.removeLast()
        }
        let raw = pieces.joined(separator: " ")
        guard !raw.isEmpty else {
            print("用法：dji4gctl at <命令> [等待秒数]")
            return 2
        }
        let response = try controller.session.send(raw, timeout: wait)
        print(response.lines.joined(separator: "\n"))
        print(response.final.text)

    case "ussd":
        let code = argumentsAfter(command, in: arguments).joined(separator: " ")
        guard !code.trimmingCharacters(in: .whitespaces).isEmpty else {
            print("用法：dji4gctl ussd <代码>（查话费 / 查流量那一类，例如 *100#）")
            return 2
        }
        banner("USSD → \(code)")
        let sentAt = Date()
        let response = try controller.sendUSSD(code)
        guard response.isOK else {
            print("  模块没有收下这条：\(ATFailure.explainUSSD(response.final) ?? response.final.text)")
            print("  模块原话：\(response.final.text)")
            return 1
        }
        // 答案不是这一步回来的：`AT+CUSD=1` 当场只回 OK，网络那句话随后才
        // 以 `+CUSD` 上报（TS 27.007 §7.15）。所以这儿得主动读着等它 ——
        // 这个命令是一次性进程，没有那条一秒一拍的轮询。
        if let reply = controller.waitForUSSD(since: sentAt, timeout: 20) {
            field("状态", reply.status == 0 ? "还有后续（多步菜单）" : "结束")
            field("编码", "\(reply.dcs)")
            print("  \(reply.text.isEmpty ? "（网络没有回正文）" : reply.text)")
            if !reply.raw.isEmpty, reply.raw != reply.text { field("原样", reply.raw) }
            return 0
        }
        print("  等了 20 秒没等到网络的答复。号码对不对？有些业务要更久。")
        return 1

    case "operators":
        banner("扫网")
        print("  这条要等二十秒到一分钟，模块会把周围所有频段搜一遍。")
        print("  搜的整段时间 AT 口都占着 —— 期间面板不回话，搜完自己恢复。")
        let found = try controller.scanOperators()
        guard !found.isEmpty else {
            // 和「超时」分开：这里是模块回了话、只是名单是空的。
            print("  模块回了话，但名单是空的：这一带它只认得到当前这一家（只吃一家")
            print("  的网络、或者被锁在一种制式上时就是这样）。")
            return 1
        }
        for row in found {
            var line = "  \(row.numeric)  \(row.label)"
            if row.isCurrent { line += "   ← 当前" }
            else if row.isForbidden { line += "   （禁用）" }
            print(line)
        }
        print("")
        print("  换一家：dji4gctl operator-set <号码>；交回自动：dji4gctl operator-auto")

    case "operator-set":
        let target = argumentsAfter(command, in: arguments).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else {
            print("用法：dji4gctl operator-set <46011>（号码从 dji4gctl operators 里抄）")
            return 2
        }
        banner("手动选网 → \(target)")
        let chosen = try controller.selectOperator(numeric: target)
        print("  \(chosen.isOK ? "已登记，等模块自己顶上去（十几秒）" : "模块没接受：\(chosen.final.text)")")
        return chosen.isOK ? 0 : 1

    case "operator-auto":
        banner("自动选网")
        let automatic = try controller.selectOperatorAutomatic()
        print("  \(automatic.isOK ? "已交回自动选网" : "模块没接受：\(automatic.final.text)")")
        return automatic.isOK ? 0 : 1

    case "network":
        banner("网络")
        _ = try controller.refreshSignal()
        _ = controller.refreshData()
        printNetwork(controller)
        printData(controller)
        for note in controller.data.diagnostics() { print("  · \(note)") }

    case "voice-provision":
        // 通话语音的一键安装：解锁 ADB → 加载厂商驱动 → 下发语音校准 →
        // 起 PCM 桥 → 打开 audio_enable。做完跑 audio-bridge 就能验。
        //
        // 不带 --install 时只体检、不改模块 —— 客户机上先看清楚缺什么再动手。
        banner("通话语音安装")
        let provision = ModuleVoiceSetup(session: controller.session)
        let wantsInstall = arguments.contains("--install")

        func reportProvision(_ status: ModuleVoiceSetup.Status) {
            field("adb", status.adbBinary ?? "找不到")
            field("模块可达", status.moduleReachable ? "是" : "否")
            field("adb 已解锁", status.adbUnlocked ? "是" : "否")
            field("语音驱动", status.driversLoaded ? "已加载" : "未加载")
            field("语音校准", status.calibrated ? "已下发" : "未下发")
            field("PCM 桥", status.bridgeRunning ? "在跑" : "未运行")
            field("audio_enable", status.audioEnabled ? "1" : "0")
            field("声卡", status.soundCardPresent ? "已出现" : "未出现")
            print("")
            if status.ready {
                print("  ✓ 通话语音已就绪。拨通后跑 dji4gctl audio-bridge 6 看上下行电平。")
            } else {
                print("  当前：\(status.summary)")
                for issue in status.issues { print("    · \(issue)") }
                if !wantsInstall {
                    print("")
                    print("  补齐这些步骤：dji4gctl voice-provision --install")
                }
            }
        }

        if wantsInstall {
            do {
                let final = try provision.install { progress in
                    switch progress {
                    case .step(let name): print("  … \(name)")
                    case .done(let name): print("  ✓ \(name)")
                    }
                }
                print("")
                reportProvision(final)
                if !final.ready { return 1 }
            } catch {
                print("  ! \(error)")
                print("")
                reportProvision(provision.inspect())
                return 1
            }
        } else {
            reportProvision(provision.inspect())
        }

    case "voice":
        banner("模块声卡")
        // 这一节以前写的是「一代模块的通话语音不走 USB 声卡」。2026-09-25
        // 的真机实测推翻了那个结论：声卡是**通话语音的通道**，只是固件默认
        // 不建 DSP 通路，得先按 `voice-provision` 把那五步做完。
        print("  注：声卡就是通话语音的通道。出厂固件不建通路，先跑 dji4gctl voice-provision。")
        print("")
        let status = controller.voice.refreshStatus()
        field("系统默认音频", status.label)
        for device in AudioDevices.all().filter({ $0.transport == "USB" }) {
            field("设备", "\(device.name) [in:\(device.hasInput ? "是" : "否") out:\(device.hasOutput ? "是" : "否")]")
        }
        if let composition = (try? controller.voice.moduleComposition()) ?? nil {
            field("模块声卡", composition.audio ? "已开启" : "未开启（需要 usbcfg 最后一位 = 1）")
        }

    case "voice-enable":
        banner("开启模块声卡")
        let before = try controller.voice.moduleComposition()
        field("原组态", before?.flagString ?? "读不到")
        if before?.audio == true {
            print("  音频功能已经开着，无需改动。")
            break
        }
        let updated = try controller.voice.enableAudioFunction(reboot: true)
        field("回读组态", updated.flagString)
        if updated.audio {
            print("  已写入：音频功能已开启。")
        } else {
            print("  ! 模块回读仍是「未开启」——这次写入没有生效。")
            print("    再跑一次；仍然无效就先看原始返回：dji4gctl at 'AT+QCFG=\"usbcfg\"'")
        }
            print("  模块正在重启（USB 会断开约 20 秒），之后跑 dji4gctl voice 确认声卡出现。")

    case "voice-disable":
        banner("关闭模块声卡（在 iPhone / iPad 上用）")
        let before = try controller.voice.moduleComposition()
        field("原组态", before?.flagString ?? "读不到")
        if before?.audio == false {
            print("  音频功能本来就关着，无需改动。")
            break
        }
        let updated = try controller.voice.disableAudioFunction(reboot: true)
        field("回读组态", updated.flagString)
        if updated.audio {
            print("  ! 模块回读仍是「已开启」——这次写入没有生效，再跑一次。")
        } else {
            print("  已写入：音频功能已关闭。手机外放恢复正常。")
            print("  Mac 上要用通话语音时，跑 dji4gctl voice-enable 开回来。")
        }
            print("  模块正在重启（USB 会断开约 20 秒）。")

    case "audio-bridge", "bridge":
        // 真机调试用的入口：把两条链路跑起来，每秒报一次电平。App 里走的是
        // 同一个 CallAudioBridge，所以这里能验的，App 里就是那个行为。
        banner("通话音频桥")
        let seconds = argumentsAfter(command, in: arguments).first.flatMap { Double($0) } ?? 20
        let bridge = CallAudioBridge()
        bridge.onEvent = { print("  · \($0)") }
        do {
            let endpoints = try CallAudioBridge.resolveEndpoints()
            field("麦克风", "\(endpoints.microphone.name)（\(Int(endpoints.microphone.nominalSampleRate ?? 0)) Hz）")
            field("扬声器", "\(endpoints.speaker.name)（\(Int(endpoints.speaker.nominalSampleRate ?? 0)) Hz）")
            field("模块录音", "\(endpoints.moduleInput.name)（\(Int(endpoints.moduleInput.nominalSampleRate ?? 0)) Hz）")
            field("模块放音", "\(endpoints.moduleOutput.name)（\(Int(endpoints.moduleOutput.nominalSampleRate ?? 0)) Hz）")
            print("")
            try bridge.start()
        } catch {
            print("  ! \(error)")
            print("  提示：模块的声卡要先加载驱动才会出现（见 dji4gctl voice-provision）。")
            break
        }
        print("  已启动，跑 \(Int(seconds)) 秒。说话看「上行」，对方说话看「下行」。")
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, bridge.isRunning {
            Thread.sleep(forTimeInterval: 1)
            let levels = bridge.refreshLevels()
            let up = String(format: "%.3f", levels.up)
            let down = String(format: "%.3f", levels.down)
            let upBar = String(repeating: "#", count: min(40, Int(levels.up * 120)))
            let downBar = String(repeating: "#", count: min(40, Int(levels.down * 120)))
            let ring = bridge.ringDepthMilliseconds
            print("  上行 \(up) \(upBar)")
            print("  下行 \(down) \(downBar)")
            print("  缓冲 \(String(format: "%.1f", ring.up)) / \(String(format: "%.1f", ring.down)) ms")
        }
        print(bridge.diagnostics)
        bridge.stop()

    case "apn":
        banner("APN")
        if let wanted = argumentsAfter(command, in: arguments).first {
            // 运营商简称/全称/APN 名都认：「apn 电信」和「apn CTNET」是一回事。
            // 香港那几家也进同一张表：「apn cmhk」按 CMHK 配，而不是把字面
            // "cmhk" 当 APN 写进去（那和直接手填 APN 是两条路）。
            let known = CarrierCatalog.mainlandChina + CarrierCatalog.hongKong
            if let carrier = known.first(where: {
                $0.name == wanted || $0.shortName == wanted
                    || $0.apn.caseInsensitiveCompare(wanted) == .orderedSame
            }) {
                let apn = try controller.applyCarrierAPN(force: true, carrier: carrier)
                print("  已写入 \(apn)（\(carrier.name)）")
            } else {
                try controller.data.configureAPN(wanted)
                print("  已设置为 \(wanted)")
            }
        } else {
            // 只读，见 apnReport：查看不该顺手动模块。
            print(apnReport(controller))
        }

    case "net-status", "net-enable", "net-disable":
        banner("Mac 网络服务")
        _ = controller.refreshData()
        let data = controller.data.status
        guard data.hasInterface else {
            field("接口", "未找到")
            print("  模块没有网卡。先确认已切到 ECM（dji4gctl usbnet 1）并重新插拔。")
            return 1
        }
        field("接口", data.interfaceName)
        field("IPv4", data.ipv4Address.isEmpty ? "无" : data.ipv4Address)

        if command == "net-status" {
            guard let service = controller.data.hostService(force: true) else {
                print("  macOS 还没有为该网卡建立网络服务，稍后重试。")
                return 1
            }
            field("服务名", service.name)
            field("状态", service.enabled ? "已启用（流量走模块）" : "未启用（流量仍走 Wi-Fi）")
            if !service.enabled {
                print("  启用：dji4gctl net-enable")
            }
            break
        }

        let wanted = command == "net-enable"
        do {
            let service = try controller.data.setHostService(enabled: wanted)
            field("服务名", service.name)
            field("状态", wanted ? "已启用" : "已停用，默认路由回到 Wi-Fi")
        } catch {
            field("失败", "\(error)")
            if let name = controller.data.hostService(force: true)?.name ?? Optional(data.serviceName) {
                print("  可在终端手动执行：")
                print("  " + HostNetwork.manualCommand(name, wanted))
            }
            return 1
        }

    case "usbnet":
        banner("USB 网络模式")
        guard let modeArg = argumentsAfter(command, in: arguments).first,
              let mode = USBnetMode(rawValue: Int(modeArg) ?? -1) else {
            let current = try controller.data.readUSBnetMode()
            field("当前", current?.technicalName ?? "未知")
            print("  用法：dji4gctl usbnet <0|1|2|3>（1 = ECM，macOS 可用）")
            break
        }
        let current = try controller.data.readUSBnetMode()
        field("当前", current?.technicalName ?? "未知")
        if current == mode {
            print("  已经是 \(mode.technicalName)，无需改动。")
            break
        }
        let stored = try controller.data.setUSBnetMode(mode, reboot: true)
        if stored == mode {
            print("  已写入 \(mode.technicalName)。")
        } else {
            print("  ! 模块回读仍是 \(stored.technicalName)——这次写入没有生效。")
            print("    再跑一次；仍然无效就先看原始返回：dji4gctl at 'AT+QCFG=\"usbnet\"'")
        }
        print("  模块正在重启（USB 会断开约 20 秒）。")
        if mode == .ecm {
            print("  回来后 macOS 会多出一张网卡，接着跑：dji4gctl net-status")
        }

    case "prepare":
        banner("一键配置：USB 网卡 + 模块声卡")
        let netBefore = try controller.data.readUSBnetMode()
        let compositionBefore = try controller.voice.moduleComposition()
        field("usbnet", netBefore?.label ?? "未知")
        field("usbcfg", compositionBefore?.flagString ?? "读不到")

        let netDone = netBefore == .ecm
        let audioDone = compositionBefore?.audio == true
        if netDone, audioDone {
            print("")
            print("  两项都已开启，模块不需要改动。")
            print("  接着确认 macOS 侧：dji4gctl net-status")
            break
        }

        var failures: [String] = []
        print("")
        if !netDone {
            let stored = try controller.data.setUSBnetMode(.ecm, reboot: false)
            if stored == .ecm {
                print("  ✓ usbnet 已写入 ECM")
            } else {
                print("  ! usbnet 回读是 \(stored.label)，写入没有生效")
                failures.append("usbnet")
            }
        }
        if !audioDone {
            let stored = try controller.voice.enableAudioFunction(reboot: true)
            if stored.audio {
                print("  ✓ usbcfg 已写入，模块声卡已开启")
            } else {
                print("  ! usbcfg 回读是 \(stored.flagString)，音频仍未开启")
                failures.append("usbcfg")
            }
        } else {
            // Only usbnet changed, so nothing has asked for a reboot yet — and
            // usbnet is one of the settings that needs one to take effect.
            _ = try? controller.session.send("AT+CFUN=1,1", timeout: 3)
        }

        print("")
        if failures.isEmpty {
            print("  模块正在重启（USB 会断开约 20 秒）。回来后依次执行：")
            print("    dji4gctl usb         # 确认多出「模块声卡」「USB 网卡」")
            print("    dji4gctl net-status  # 确认 macOS 给模块建了网卡和网络服务")
        } else {
            print("  \(failures.joined(separator: " / ")) 写入没有生效，模块不会变。")
            print("  再跑一次；仍然无效就先看原始返回：")
            print("    dji4gctl at 'AT+QCFG=\"usbnet\"'")
            print("    dji4gctl at 'AT+QCFG=\"usbcfg\"'")
        }

    case "restore":
        // 把模块恢复成出厂状态 —— 卸载 App 之前跑这一条。
        //
        // 只撤本工具动过的三样东西：装进模块的三个文件、换过的 USB 网络模式、
        // 组态里被翻起来的那两位（adb 与音频）。固件、模块的系统、卡里的东西
        // 一概不碰 —— 「复原不需要刷机」说的就是这件事。
        banner("恢复模块出厂状态")
        var problems: [String] = []

        // 1) 模块里装进去的文件。ADB 连不上就跳过：没装过通话语音的模块本来
        //    就没有这些文件，那不算失败。
        let cleanup = ModuleVoiceSetup(session: controller.session).removeStagedFiles()
        if let reason = cleanup.skippedReason {
            field("模块里的文件", "跳过（\(reason)）")
        } else {
            field("模块里的文件", cleanup.removedFiles.isEmpty
                  ? "没有要清的"
                  : "已清掉 \(cleanup.removedFiles.count) 个")
        }
        if !cleanup.stoppedProcesses.isEmpty {
            field("已停进程", cleanup.stoppedProcesses.joined(separator: "、"))
        }
        if !cleanup.unloadedModules.isEmpty {
            field("已卸模块", cleanup.unloadedModules.joined(separator: "、"))
        }

        // 2) 上网模式：出厂就是 0。这条不写回去，模块插回大疆的设备是认得出
        //    来但不一定能上网 —— 大疆侧的 USB 网络驱动要的就是出厂那一种。
        let netBefore = try controller.data.readUSBnetMode()
        if netBefore == .rndis {
            field("上网模式", "出厂状态，无需改动")
        } else if let stored = try? controller.data.setUSBnetMode(.rndis, reboot: false),
                  stored == .rndis {
            field("上网模式", "已写回出厂")
        } else {
            field("上网模式", "没写进去")
            problems.append("上网模式")
        }

        // 3) 组态：adb 位与音频位归 0，其余位和 VID/PID 原样保留。
        let compositionBefore = try controller.voice.moduleComposition()
        if let before = compositionBefore, !before.adb, !before.audio {
            field("USB 组态", "出厂状态，无需改动")
        } else if let stored = try? controller.voice.restoreFactoryFunction(reboot: false),
                  !stored.adb, !stored.audio {
            field("USB 组态", "已写回出厂（\(stored.flagString)）")
        } else {
            field("USB 组态", "没写进去")
            problems.append("USB 组态")
        }

        // 4) 上面三条都写在模块自己的存储里，要重启一次才生效。
        _ = try? controller.session.send("AT+CFUN=1,1", timeout: 3)

        print("")
        if problems.isEmpty {
            print("  ✓ 已恢复出厂状态。模块插回大疆的设备可以直接用。")
            print("    还要在这台电脑上用，跑 dji4gctl prepare 会重新配好。")
        } else {
            print("  \(problems.joined(separator: " / ")) 没有写进去，再跑一次 dji4gctl restore。")
        }
        print("  模块正在重启（USB 会断开约 20 秒）。")

    default:
        print("未知命令：\(command)")
        printUsage()
        controller.disconnect()
        return 2
    }
    } catch {
        print("执行失败：\(error)")
        controller.disconnect()
        return 1
    }

    controller.disconnect()
    return 0
}

/// 用法全文。抽成常量是为了让自检能钉住它：体检报告会直接把命令塞给客户
/// （「→ dji4gctl sms-storage SM」），那条命令没写进这里，客户复制过去只会
/// 得到一句「未知命令」—— `sms-storage` 刚这样漏过一次。
///
/// **加子命令时这里和下面那个 switch 要一起改**，自检里有一项专盯这件事。
let usageText = """
    dji4gctl — 大疆一代 4G 模块（QDC507 / EG25-G）控制台

    用法：dji4gctl [--sim] [--sim-nosim] <命令> [参数]

      doctor                 端到端体检：逐项检查并给出该执行的命令
      usb                    只读 USB 体检：接口布局与占用者（不需独占模块）
      status                 模块、SIM、网络、流量总览
      network                网络与联网诊断
      sms-list               列出短信
      sms-send <号码> <内容>  发送短信
      sms-clear              清空收件箱（模块里存的那一份，不是卡里的）
      sms-storage [SM|ME|MT|SR]
                             查看或更换短信接收存储。带参数时换过去，
                             不带参数只显示当前是哪个和用法。
                             存储满了以后新短信会被网络直接丢掉，
                             默认的 ME 只有 23 条，换到 SM 一般有 40 条左右
      call-dial <号码>        拨打电话
      voice                  查看模块声卡与系统默认音频
      prepare                一键开启 USB 网卡 + 模块声卡（只重启一次）
      restore                把模块恢复成出厂状态：清掉装进去的文件、把换过的
                             上网模式和打开的声卡都撤回去。卸载 App 之前跑，
                             跑完模块插回大疆的设备直接能用
      voice-enable           开启模块声卡（会重启模块）
      voice-disable          关闭模块声卡（会重启模块）。插 iPhone / iPad
                             时用：模块枚举成 USB 声卡会顶掉手机外放，
                             刷视频听歌全没声；关掉就恢复
      apn [名称]             查看或设置 APN
                             （名称：移动 / 联通 / 电信 / 广电，或任意 APN 字符串）
      usbnet <0|1|2|3>       切换 USB 网络模式（会重启模块）
      fontcheck [App路径]    检查这一份 app 自己带得动点阵字（发版前必跑）
      net-status             查看 macOS 是否为模块启用了网络服务
      net-enable             启用模块网络服务（联网走模块）
      net-disable            停用模块网络服务（默认路由回到 Wi-Fi）
      autostart <on|off|status>
                             开机自启（登录时自动运行菜单栏 App）
      at <命令> [秒数]       发送原始 AT 命令（默认等 10 秒，扫网那种给 60）
      ussd <代码>            发一条 USSD（查话费 / 查流量那一类）。
                             代码自己填，国内三家都用 *100# 这种写法。
                             答案要等几秒才回来，这条命令会一直等到它
      operators              扫一遍周围能看到的运营商（要等 20-60 秒，
                             这期间模块整段时间占着 AT 口，搜完自己恢复）
      operator-set <号码>    手动登记到某一家（号码从 operators 里抄）
      operator-auto          交回自动选网
      sim                    在模拟器上交互演示（无需硬件）
      selftest               运行无需硬件的自检
      help                   就是这份用法（等价于 -h / --help）

    加 --sim 可在没有硬件时使用内置模拟器；
    加 --sim-nosim 模拟"还没插卡"的状态（其余功能照常）。
    """

func printUsage() {
    print(usageText)
}

// MARK: - Interactive

func runInteractive(controller: ModemController) -> Int32 {
    print("正在连接模块…")
    do {
        try controller.connect()
    } catch {
        print("连接模块失败：\(error)")
        print("提示：确认模块已插好；或用 dji4gctl --sim sim 在模拟器上体验。")
        return 1
    }
    print("已连接：\(controller.session.channelDescription)")
    controller.startPolling()

    controller.onEvent = { event in
        switch event {
        case .incomingSMS(let message):
            print("\n📩 新短信 \(message.sender)：\(message.text)")
        case .call(let info) where info.state == .ringing:
            print("\n📞 来电：\(info.number)（输入 3 接听）")
        case .call(let info) where info.state == .active:
            print("\n☎️ 通话中：\(info.number)")
        case .transportLost(let detail):
            print("\n⚠️ 模块连接断开：\(detail)")
        default:
            break
        }
    }

    while true {
        print("""

        ── DJI 4G 控制台 ────────────────────────────
          1  模块状态
          2  短信
          3  通话
          4  网络
          5  模块声卡
          6  原始 AT 命令
          0  退出
        """)
        print("请选择：", terminator: "")
        guard let choice = readLine()?.trimmingCharacters(in: .whitespaces) else { break }

        switch choice {
        case "0", "q", "quit", "exit":
            controller.stopPolling()
            controller.disconnect()
            print("已断开。")
            return 0

        case "1":
            banner("模块状态")
            printIdentity(controller)
            printSIM(controller)
            _ = try? controller.refreshNetwork()
            _ = try? controller.refreshSignal()
            printNetwork(controller)
            _ = controller.refreshData()
            printData(controller)

        case "2":
            banner("短信")
            do {
                _ = try controller.sms.refreshStorage()
                let messages = try controller.sms.refresh()
                field("存储", controller.sms.storage.label)
                printMessages(messages)
            } catch {
                print("  读取失败：\(error)")
            }
            print("""
              s 发送   d <序号> 删除   r 刷新   D 全部删除   回车 返回
            """)
            print("操作：", terminator: "")
            let action = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
            if action == "s" {
                print("  收件人：", terminator: "")
                let number = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
                print("  内容：", terminator: "")
                let text = readLine() ?? ""
                if !number.isEmpty, !text.isEmpty {
                    do {
                        let count = try controller.sms.send(text: text, to: number)
                        print("  已提交 \(count) 条 PDU")
                    } catch {
                        print("  发送失败：\(error)")
                    }
                }
            } else if action.hasPrefix("d ") {
                if let index = Int(action.dropFirst(2).trimmingCharacters(in: .whitespaces)) {
                    try? controller.sms.delete(index: index)
                    print("  已删除 \(index)")
                }
            } else if action == "D" {
                try? controller.sms.deleteAll()
                print("  已清空")
            } else if action == "r" {
                _ = try? controller.sms.refresh()
            }

        case "3":
            banner("通话")
            _ = try? controller.refreshCalls()
            printCall(controller.calls)
            print("""
              d <号码> 拨号   a 接听   r 拒接   h 挂断   t <数字> 发送按键
            """)
            if activeSimulator != nil {
                print("              i 模拟来电（通话中再来一个就是等待来电）   回车 返回")
            } else {
                print("              回车 返回")
            }
            print("操作：", terminator: "")
            let action = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
            if action.hasPrefix("d ") {
                let number = String(action.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                do { try controller.calls.dial(number); print("  已拨号 \(number)") }
                catch { print("  拨号失败：\(error)") }
            } else if action == "a" {
                do { try controller.calls.answer(); print("  已接听") }
                catch { print("  接听失败：\(error)") }
            } else if action == "r" {
                do { try controller.calls.reject(); print("  已拒接") }
                catch { print("  拒接失败：\(error)") }
            } else if action == "h" {
                do { try controller.calls.hangup(); print("  已挂断") }
                catch { print("  挂断失败：\(error)") }
            } else if action == "i", let sim = activeSimulator {
                print("  来电号码：", terminator: "")
                let number = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
                sim.simulateIncomingCall(from: number.isEmpty ? "+8613900139000" : number)
                _ = controller.session.pollUnsolicited(timeout: 0.5)
                print("  当前通话状态：\(controller.calls.current.state.label)")
            } else if action.hasPrefix("t ") {
                try? controller.calls.sendDTMF(String(action.dropFirst(2)))
            }

        case "4":
            banner("网络")
            _ = try? controller.refreshNetwork()
            _ = try? controller.refreshSignal()
            _ = controller.refreshData()
            printNetwork(controller)
            printData(controller)
            for note in controller.data.diagnostics() { print("  · \(note)") }
            print("\n  a 自动配置 APN   回车 返回")
            print("操作：", terminator: "")
            if readLine()?.trimmingCharacters(in: .whitespaces) == "a" {
                do {
                    let apn = try controller.applyCarrierAPN(force: true)
                    print("  已设置 APN：\(apn)")
                } catch {
                    print("  设置失败：\(error)")
                }
            }

        case "5":
            banner("模块声卡")
            print("  注：这里切的是系统默认设备。通话语音走的是 dji4gctl audio-bridge，"
                  + "不经过这里；语音没通先跑 dji4gctl voice-provision --install。")
            let status = controller.voice.refreshStatus()
            field("系统默认音频", status.label)
            let usb = AudioDevices.all().filter { $0.transport == "USB" }
            if usb.isEmpty { print("  没有 USB 声卡设备") }
            for device in usb {
                field("设备", "\(device.name)（输入 \(device.hasInput ? "有" : "无") / 输出 \(device.hasOutput ? "有" : "无")）")
            }
            if let composition = (try? controller.voice.moduleComposition()) ?? nil {
                field("模块声卡", composition.audio ? "已开启" : "未开启")
            }
            print("\n  a 切到模块声卡   o 恢复系统默认   e 开启模块声卡   回车 返回")
            print("操作：", terminator: "")
            switch readLine()?.trimmingCharacters(in: .whitespaces) {
            case "a":
                do { _ = try controller.voice.activate(); print("  已切换") }
                catch { print("  失败：\(error)") }
            case "o":
                print(controller.voice.deactivate() ? "  已恢复" : "  没有需要恢复的（不是这个 App 切过去的）")
            case "e":
                do {
                    let updated = try controller.voice.enableAudioFunction(reboot: true)
                    print("  回读组态：\(updated.flagString)"
                          + (updated.audio ? "，模块正在重启" : "，音频仍未开启"))
                } catch {
                    print("  失败：\(error)")
                }
            default:
                break
            }

        case "6":
            print("  AT 命令（回车返回）：", terminator: "")
            let raw = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
            if !raw.isEmpty {
                do {
                    let response = try controller.session.send(raw, timeout: 10)
                    for line in response.lines { print("  \(line)") }
                    print("  \(response.final.text)")
                } catch {
                    print("  失败：\(error)")
                }
            }

        default:
            print("无效选项")
        }
    }
    return 0
}

/// 这一条不碰模块：它验的是「这一份 app 自己带不带得动点阵字」。
///
/// 2026-09-25 一位客户装的那一版点开面板就闪退，根因就是资源包找不到
/// —— SwiftPM 的 Bundle.module 只认 app 根目录和编译那台机器的 .build
/// 目录，而资源躺在 Contents/Resources 里。开发机上 .build 恰好在，所以
/// 一直没露馅。发版前在打包机上跑，客户机上也能跑给自己看。
func runFontCheck() -> Int32 {
    banner("点阵字资源")
    let appPath = argumentsAfter("fontcheck", in: arguments).first ?? "/Applications/DJI4G.app"
    let app = URL(fileURLWithPath: appPath)
    guard FileManager.default.fileExists(atPath: app.path) else {
        field("App", "不存在：\(app.path)")
        return 1
    }
    field("App", app.path)
    let dirs = AppResources.searchDirectories(inAppBundle: app)
    guard let hit = AppResources.url(forResource: "doto", withExtension: "ttf",
                                     bundleName: AppResources.menuBarBundleName,
                                     directories: dirs) else {
        field("字体", "没找到")
        print("  ✗ 这份 app 里没有点阵字 —— 面板一点就会崩，请重新安装。")
        for dir in dirs { print("    · 找过 \(dir.path)") }
        return 1
    }
    field("字体", hit.path.replacingOccurrences(of: app.path + "/", with: ""))
    if let size = (try? FileManager.default.attributesOfItem(atPath: hit.path)[.size]) as? Int {
        field("大小", "\(size) 字节")
    }
    print("  ✓ 这一份 app 自己找得到点阵字，点开面板不会因此崩。")
    return 0
}

// MARK: - Entry point

if arguments.contains("selftest") {
    exit(runSelfTest() ? 0 : 1)
}

// 和 selftest 同理：验的是 app 自己带不带得动点阵字，不需要模块。
// 打包时模块正被菜单栏 App 占着，硬去连只会得到一句「读不到 USB 接口」。
if arguments.contains("fontcheck") {
    exit(runFontCheck())
}

// Usage is the one thing that must never need the module: whoever is reading
// it is usually reading it *because* the module is not answering.
if let first = arguments.first, ["help", "-h", "--help", "usage"].contains(first) {
    printUsage()
    exit(0)
}

if arguments.contains("sim") || arguments.isEmpty {
    let controller = makeController()
    exit(runInteractive(controller: controller))
}

let command = arguments.first { !$0.hasPrefix("--") } ?? ""
if command.isEmpty {
    printUsage()
    exit(2)
}
exit(runOneShot(command, controller: makeController()))
