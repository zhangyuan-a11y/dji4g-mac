import Foundation
import CoreAudio
import AudioToolbox

public struct AudioDevice: Equatable, Identifiable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
    public let hasInput: Bool
    public let hasOutput: Bool
    public let transport: String

    /// 公开出来，好让无硬件的自检能造几个假设备来钉名字匹配；截图用的
    /// `seedModuleDevice` 走的也是这条。
    public init(id: AudioDeviceID, name: String, uid: String,
                hasInput: Bool, hasOutput: Bool, transport: String) {
        self.id = id
        self.name = name
        self.uid = uid
        self.hasInput = hasInput
        self.hasOutput = hasOutput
        self.transport = transport
    }

}

public enum CoreAudioError: Error, CustomStringConvertible {
    case propertyFailed(String, OSStatus)
    case deviceMissing(String)
    /// 模块对 usbcfg 回了 OK，回读却是老样子 —— 少数固件会这样。单独一个
    /// 分支，好让界面说的是「这次写入没生效」，而不是含糊的「操作失败」。
    case compositionRejected(String)

    public var description: String {
        switch self {
        case .propertyFailed(let name, let status): return "读取音频属性 \(name) 失败（\(status)）"
        case .deviceMissing(let name): return "找不到音频设备 \(name)"
        // 组态字符串（`flags`）是给诊断看的，界面上不再出现 —— 文案改成白话
        // 之后这个关联值没人读了，Swift 会为 `let flags` 报一条警告。
        case .compositionRejected:
            return "模块没有接受这次设置。把模块拔下来重新插一次，再点一遍。"
        }
    }
}

/// Thin wrapper over the CoreAudio HAL: device discovery plus switching the
/// system default input/output. Everything the module needs for voice is a
/// standard USB Audio Class device, so no kernel extension is involved.
public enum AudioDevices {

    public static func all() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard let name = stringProperty(id, kAudioObjectPropertyName),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioDevice(id: id,
                               name: name,
                               uid: uid,
                               hasInput: channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0,
                               hasOutput: channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0,
                               transport: transportName(id))
        }
    }

    public static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    @discardableResult
    public static func setDefault(_ id: AudioDeviceID, input: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        return status == noErr
    }

    public static func device(id: AudioDeviceID) -> AudioDevice? {
        all().first { $0.id == id }
    }

    // MARK: - Property helpers

    static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func transportName(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return "" }
        switch value {
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBuiltIn: return "内建"
        case kAudioDeviceTransportTypeBluetooth: return "蓝牙"
        case kAudioDeviceTransportTypeVirtual: return "虚拟"
        case kAudioDeviceTransportTypeAggregate: return "聚合"
        default: return "其他"
        }
    }
}

public struct VoiceStatus: Equatable {
    public var moduleDevice: AudioDevice?
    public var usingModuleForInput: Bool = false
    public var usingModuleForOutput: Bool = false
    public var previousInput: AudioDeviceID?
    public var previousOutput: AudioDeviceID?

    public init() {}

    public var isRouted: Bool { usingModuleForInput && usingModuleForOutput }
    public var label: String {
        if let moduleDevice {
            return isRouted ? "已切到 \(moduleDevice.name)" : "已识别 \(moduleDevice.name)"
        }
        return "未检测到模块音频设备"
    }
}

public enum AudioRoutingAction: Equatable {
    /// 通话结束、设备还留在模块上：还给客户原来的默认设备。
    case restore
    case none
}

/// 决定通话状态变化时要不要动系统默认音频设备。
///
/// ★ 结论是「不要动」。通话语音由 `CallAudioBridge` 直接绑到模块的
/// `AC Interface` / `AS Interface` 上取送，全程不碰系统默认设备 —— 客户
/// 正在放的微信语音、音乐、提示音都留在原来的扬声器上，不会因为我们接电话
/// 而换地方。这是刻意选的设计，不是没做。
///
/// 演进过程（两次踩坑，别把结论倒回去）：
///
/// 1. 最早写的是「一响铃就把麦克风和扬声器切到模块」。但模块的 UAC 拆成两个
///    单向设备（`AC Interface` 只有输入、`AS Interface` 只有输出），把系统
///    默认输入输出指过去，等于让客户的音乐和提示音改道去一块既不播报、
///    也不录音的设备，现象是「装了这个工具以后电脑没声音了」。
/// 2. 随后的实测得出「一代模块的通话语音根本不走 USB 声卡，数学上全零」——
///    放 440 Hz 到 `AS Interface` 再录 `AC Interface`、`AT+QAUDLOOP=1` 内部
///    回环、`QAUDMOD` 六种模式各拨一通，81920 个样本没有一个非零。
///    **这个结论在 2026-09-25 被推翻了：它全零是因为少了三步前置**（见
///    `CallAudioBridge`），做完之后两个方向都有信号，双向通话实测通了。
///
/// 下面这个动作仍然要留着：`ModemController` 断开连接时、以及客户**自己**
/// 按过「切到模块」之后，通话结束都要把系统默认设备还回去，否则会把客户
/// 留在那个单向设备上。
public enum AudioRouting {
    public static func action(current: CallState, isRouted: Bool) -> AudioRoutingAction {
        if current.isBusy { return .none }
        return isRouted ? .restore : .none
    }
}

/// Routes call audio to the module — on request only.
///
/// The module only exposes a USB audio function when `AT+QCFG="usbcfg"` has its
/// audio flag set. Without it the AT side still dials and answers, but the
/// host has no microphone or speaker to attach to the call.
///
/// 本机这一版（一代 DJI 4G，EG25GGBR07A08M2H）组态里 audio 位是 1、声卡也
/// 在。声卡存在**不等于**通话有声音：模块固件默认不建 DSP 语音通路，必须
/// 先解锁 ADB、`insmod` 厂商两个驱动、再走一遍出厂语音校准，通话语音才会
/// 真正送进 `AC Interface` / `AS Interface`（完整步骤见 `CallAudioBridge`）。
/// 少了这几步，声卡在、电平恒为 0 —— 这就是早先「一代模块没声音」的来源。
///
/// `activate()` 依然只是那个手动按钮（「把系统默认设备指过去」），正常通话
/// 不靠它。真正的语音通路是 `CallAudioBridge`，它直接绑设备、不动默认设备。
public final class VoiceService {
    private let session: ATSession
    private let lock = NSLock()

    /// Screenshot / demo only — see `DataService.overrideHostState` for the
    /// same idea. Whether the module exposes a UAC function is a fact about the
    /// USB tree, and the in-memory module cannot produce one, so the render
    /// harness states it directly. The live paths never call this.
    private var seededDevice: AudioDevice?
    /// 钉住「宿主一个模块音频设备都看不到」。和 `seededDevice` 是一对：那个钉
    /// 「看得到、长这样」，这个钉「看不到」。客户为插手机把 usbcfg 最后一位关掉
    /// 之后就是这一档 —— 不钉的话，截图机上正好插着一台声卡开着的模块，那一行
    /// 会从这台机器读出 `已识别 AC Interface`，和图上「声卡是关着的」自相矛盾。
    private var seededAbsent = false
    private var savedInput: AudioDeviceID?
    private var savedOutput: AudioDeviceID?

    public private(set) var status = VoiceStatus()
    public var onStatusChange: ((VoiceStatus) -> Void)?

    /// Names the EG25-G UAC function exposes across firmware revisions.
    ///
    /// 本机实测（QDC507GLEFM21）补进来的三个：模块把 UAC 拆成**两个**
    /// CoreAudio 设备报上来，各自只有一个方向 —— `AC Interface`（只有输入，
    /// 对端 → Mac）和 `AS Interface`（只有输出，Mac → 对端），厂商串是 `BAIWANG`。
    /// 这三个名字原先一个都不在表里，而下面的兜底又要求「同一个设备同时有
    /// 输入和输出」，于是真机上永远匹配不到，界面一直报「未检测到模块音频设备」，
    /// `activate()` 跟着抛错 —— 通话接得通，声音却从来没接上过。
    public static let nameHints = ["EG25", "Quectel", "DJI", "QDC", "4G Module",
                                   "LTE Audio", "USB Audio Device",
                                   "AC Interface", "AS Interface", "BAIWANG"]

    public init(session: ATSession) {
        self.session = session
    }

    // MARK: - Discovery

    /// Screenshot / demo only: pretend the module's audio function is present
    /// and already carrying the call, which is the state the app reaches once
    /// `enableAudioFunction` has run and a call is up.
    public func seedModuleDevice(name: String) {
        lock.lock()
        seededDevice = AudioDevice(id: 0, name: name, uid: "seeded-module-audio",
                                   hasInput: true, hasOutput: true, transport: "USB")
        seededAbsent = false
        lock.unlock()
    }

    /// Screenshot / demo only: the other half of `seedModuleDevice` — state that
    /// the host sees **no** module audio device at all, which is what macOS
    /// reports once `usbcfg`'s audio flag is 0.
    public func seedNoModuleDevice() {
        lock.lock()
        seededDevice = nil
        seededAbsent = true
        lock.unlock()
    }

    public func refreshStatus() -> VoiceStatus {
        var fresh = VoiceStatus()
        lock.lock()
        let seeded = seededDevice
        let absent = seededAbsent
        lock.unlock()
        if seeded != nil {
            fresh.moduleDevice = seeded
            fresh.usingModuleForInput = true
            fresh.usingModuleForOutput = true
        } else if absent {
            // 刻意空着：这一档要画的正是「一个都认不到」。
        } else {
            let pair = Self.findModulePair()
            fresh.moduleDevice = pair.device
            // 拆成两个设备时，「切过去了没有」要分别问两边 —— 拿一个 id
            // 去比输入和输出，在单设备固件上碰巧对，在这版上永远是 false。
            if let input = pair.input {
                fresh.usingModuleForInput = AudioDevices.defaultDevice(input: true) == input.id
            }
            if let output = pair.output {
                fresh.usingModuleForOutput = AudioDevices.defaultDevice(input: false) == output.id
            }
        }
        fresh.previousInput = savedInput
        fresh.previousOutput = savedOutput
        lock.lock()
        status = fresh
        lock.unlock()
        onStatusChange?(fresh)
        return fresh
    }

    /// 模块的 USB 音频。老固件合成一个双方向设备报；本机这版拆成
    /// 「只有输入」和「只有输出」两个，所以按一对来认。
    public struct ModuleAudioPair {
        public let input: AudioDevice?
        public let output: AudioDevice?
        /// 给「模块在不在」这类只关心有无的调用方用。
        public var device: AudioDevice? { input ?? output }
        public var isComplete: Bool { input != nil && output != nil }
    }

    /// 设备的名字像不像模块的 UAC 端点。`CallAudioBridge` 也用它来挑端点。
    ///
    /// 公开出来是为了能在无硬件的自检里钉住它：这张名字表以前既没有
    /// `AC Interface` 也没有 `AS Interface`，而兜底又要求「同一个设备同时有
    /// 输入和输出」，于是真机上永远匹配不到，界面一直报「未检测到模块音频设备」。
    /// 通话接得通、声音却从来没接上，根因就在这一行。
    public static func matchesModuleName(_ device: AudioDevice) -> Bool {
        let name = device.name.lowercased()
        return nameHints.contains { name.contains($0.lowercased()) }
    }

    /// 认名字的那几个优先，认不出来再退到「任意单方向 USB 设备」。
    public static func findModulePair() -> ModuleAudioPair {
        let usb = AudioDevices.all().filter { $0.transport == "USB" }
        let named = usb.filter(matchesModuleName)

        if let combined = (named + usb).first(where: { $0.hasInput && $0.hasOutput }) {
            return ModuleAudioPair(input: combined, output: combined)
        }
        return ModuleAudioPair(input: named.first { $0.hasInput } ?? usb.first { $0.hasInput },
                               output: named.first { $0.hasOutput } ?? usb.first { $0.hasOutput })
    }

    // MARK: - Routing

    @discardableResult
    public func activate() throws -> VoiceStatus {
        let pair = Self.findModulePair()
        guard pair.device != nil else {
            throw CoreAudioError.deviceMissing("模块的 USB 声卡")
        }
        if savedInput == nil { savedInput = AudioDevices.defaultDevice(input: true) }
        if savedOutput == nil { savedOutput = AudioDevices.defaultDevice(input: false) }

        var ok = true
        if let input = pair.input { ok = AudioDevices.setDefault(input.id, input: true) && ok }
        if let output = pair.output { ok = AudioDevices.setDefault(output.id, input: false) && ok }
        guard ok else { throw CoreAudioError.deviceMissing("无法切换系统默认音频设备") }
        return refreshStatus()
    }

    /// 把系统默认输入/输出还给切过去之前的那两个设备。
    ///
    /// 返回「真的还了没有」。没经过 `activate()` 的时候 `savedInput` /
    /// `savedOutput` 都是 nil，这里什么都动不了 —— 而 `isRouted` 为真还有别的
    /// 来路（客户自己在系统设置里把模块设成了默认），那种情况不是这个 App 动
    /// 的，也不该由它改回去，更不该跟客户说「已经还回去了」。
    @discardableResult
    public func deactivate() -> Bool {
        let hadSaved = savedInput != nil || savedOutput != nil
        if let savedInput { AudioDevices.setDefault(savedInput, input: true) }
        if let savedOutput { AudioDevices.setDefault(savedOutput, input: false) }
        savedInput = nil
        savedOutput = nil
        _ = refreshStatus()
        return hadSaved
    }

    // MARK: - Module side

    /// Reads the USB composition so the caller can tell whether the audio
    /// function exists at all.
    public func moduleComposition() throws -> USBComposition? {
        let response = try session.send("AT+QCFG=\"usbcfg\"", timeout: 5)
        return ATParsers.qcfgComposite(from: response)
    }

    /// Rewrites the composition so the audio function is present. The module
    /// re-enumerates on the next reboot, which drops the AT channel until macOS
    /// finishes re-attaching the device.
    public func enableAudioFunction(reboot: Bool = true) throws -> USBComposition {
        try setAudioFunction(true, reboot: reboot)
    }

    /// Turns the audio function off.
    ///
    /// 为什么需要它：模块一旦枚举成 USB 声卡，**任何**宿主都会把音频输出切到
    /// 它身上 —— macOS 上这正是通话语音的载体，要的就是这个；但 iPhone / iPad
    /// 上模块没有喇叭，切过去的结果是整台设备像哑了一样（刷视频、听歌都没声）。
    /// 手机端本来也用不上模块声卡（iOS 不把那块给我们），所以对手机就该关掉。
    public func disableAudioFunction(reboot: Bool = true) throws -> USBComposition {
        try setAudioFunction(false, reboot: reboot)
    }

    /// 把音频位设成 `on`，其余位（含 adb）原样保留。
    ///
    /// adb 位必须一起保住：装通话语音时打开的 adb 就写在同一串 usbcfg 里，
    /// 这里整串覆盖要是把它抹了，下次打电话就没声音，而且提示是「ADB 未解锁」，
    /// 很难联想到这里。
    public func setAudioFunction(_ on: Bool, reboot: Bool = true) throws -> USBComposition {
        var updated = try currentComposition()
        updated.audio = on
        return try writeComposition(updated, reboot: reboot)
    }

    /// 把组态写回出厂那一档：**adb 位和音频位都归 0**，其余位与 VID/PID 原样。
    ///
    /// 一代模块出厂就是 `1,1,1,1,1,0,0`（`docs/NETWORKING.md`）：网卡位开着，
    /// adb 和音频关着。本工具只翻过这两位（装通话语音翻 adb、开模块声卡翻
    /// 音频），复原也就只该动这两位 —— 客户手里可能是改过 VID/PID 的模块，
    /// 整串覆盖会把那些改动一起抹掉。
    ///
    /// 复原之后模块就是「没改装过」的样子，插回大疆的设备直接能用；要再回到
    /// Mac 上用，跑一遍 `dji4gctl prepare` 即可。
    public func restoreFactoryFunction(reboot: Bool = true) throws -> USBComposition {
        var updated = try currentComposition()
        updated.adb = false
        updated.audio = false
        return try writeComposition(updated, reboot: reboot)
    }

    /// 读当前组态；读不到就当成「模块没回应」报错，别把 nil 漏给调用方。
    private func currentComposition() throws -> USBComposition {
        guard let current = try moduleComposition() else {
            throw CoreAudioError.deviceMissing("模块没有回应，拔下来重新插一次再试")
        }
        return current
    }

    /// 把一整串组态写进模块并回读。回读的那一份才是准的 —— 有的固件会对一条
    /// 它其实不打算保存的 usbcfg 回 OK，只看自己发出去什么，两种情况分不开。
    private func writeComposition(_ updated: USBComposition,
                                  reboot: Bool) throws -> USBComposition {
        let command = String(format: "AT+QCFG=\"usbcfg\",0x%04X,0x%04X,%@",
                             updated.vendorID, updated.productID, updated.flagString)
        let response = try session.send(command, timeout: 8)
        guard response.final == .ok else { throw CallError.rejected(response.final) }

        // The composition the module stored, not the one that was sent: some
        // firmware answers OK to a usbcfg it then declines to keep, and a
        // caller reporting its own request cannot tell the two apart.
        let stored = (try? moduleComposition()) ?? nil

        if reboot {
            // Best effort: the AT port disappears as soon as this lands.
            _ = try? session.send("AT+CFUN=1,1", timeout: 3)
        }
        return stored ?? updated
    }
}
