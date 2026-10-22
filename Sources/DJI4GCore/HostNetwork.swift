import Foundation

/// The macOS half of the ECM link — the part the modem knows nothing about.
///
/// Once the module is in ECM mode macOS builds an Ethernet interface for it,
/// but it also creates a *network service* and leaves that service **disabled**.
/// That default is deliberate: an always-on cellular service would otherwise
/// outrank Wi-Fi in the routing table the moment the module is plugged in, and
/// every packet on the machine would start costing mobile data. So "can I reach
/// the internet through the module" is two questions, not one:
///
///   1. does a BSD interface exist and did DHCP give it an address?
///   2. is the matching network service switched on?
///
/// The reference app answers both and keeps the service off until you turn 4G
/// on; it also turns it back off when you are done. `DataService` already
/// covers (1) with IOKit, but nothing in the modem can answer (2), so this is
/// the one piece of the stack that shells out instead of talking AT.
public enum HostNetwork {

    public struct Service: Equatable {
        public var name: String
        public var enabled: Bool
        /// The BSD interface the service is bound to, e.g. `en17`.
        public var device: String

        public var label: String { enabled ? "\(name) · 已启用" : "\(name) · 未启用" }
    }

    public enum HostNetworkError: Error, CustomStringConvertible {
        case toolMissing(String)
        case failed(command: String, status: Int32, output: String)
        case serviceNotFound(String)

        public var description: String {
            switch self {
            case .toolMissing(let path):
                return "找不到 \(path)"
            case .failed(let command, let status, let output):
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "\(command) 失败（退出码 \(status)）" : "\(command) 失败：\(detail)"
            case .serviceNotFound(let device):
                return "macOS 里没有绑定到 \(device) 的网络服务，模块可能还没被识别成网卡"
            }
        }
    }

    /// `networksetup` lives in /usr/sbin, which is not on the PATH of a
    /// Finder-launched app, so call it by absolute path.
    private static let tool = "/usr/sbin/networksetup"

    // MARK: - Queries

    /// Parses `networksetup -listnetworkserviceorder`, which prints pairs like
    ///
    ///     (2) Baiwang
    ///     (Hardware Port: Baiwang, Device: en17)
    ///
    /// Index and hardware-port text are localised, so match on the `Device:`
    /// token and take the service name from the line above it.
    public static func service(for device: String) -> Service? {
        guard !device.isEmpty,
              let output = try? run(["-listnetworkserviceorder"]),
              let name = parseServiceOrder(output, device: device) else { return nil }
        return Service(name: name, enabled: isEnabled(name), device: device)
    }

    /// Pulls the service name bound to `device` out of
    /// `networksetup -listnetworkserviceorder`.
    ///
    /// Split out from `service(for:)` so it can be checked against a captured
    /// transcript in the self-test; everything else here needs a real machine
    /// with a real module, and this is the part most likely to break when
    /// macOS changes its output.
    ///
    /// Services print as a name line followed by a hardware-port line:
    ///
    ///     (1) Wi-Fi
    ///     (Hardware Port: Wi-Fi, Device: en0)
    ///
    ///     (*) Baiwang
    ///     (Hardware Port: Baiwang, Device: en17)
    ///
    /// The service *name* is localised on a non-English system, so it is read
    /// from the name line verbatim rather than matched against a literal; the
    /// only fixed tokens are `Device:` and the parenthesised index, both of
    /// which `networksetup` prints in English. A disabled service is marked
    /// with `(*)`, but that marker is not trusted as the enabled state —
    /// `-getnetworkserviceenabled` is asked separately.
    public static func parseServiceOrder(_ output: String, device: String) -> String? {
        var pendingName: String?
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.contains("Device:") {
                if let bound = deviceToken(in: line), bound == device, let name = pendingName {
                    return name
                }
                // A port line always closes the name it belonged to, so a
                // mismatch must not leak into the next entry.
                pendingName = nil
                continue
            }

            pendingName = numberedName(line)
        }
        return nil
    }

    /// The service name macOS shows in System Settings for the module, e.g.
    /// "Baiwang". Empty when no service is bound to the interface yet.
    public static func serviceName(for device: String) -> String {
        service(for: device)?.name ?? ""
    }

    public static func isEnabled(_ name: String) -> Bool {
        guard let output = try? run(["-getnetworkserviceenabled", name]) else { return false }
        return output.lowercased().contains("enabled")
            && !output.lowercased().contains("disabled")
    }

    // MARK: - Mutations

    /// Enables or disables the module's network service.
    ///
    /// Needs an admin account; if the authorisation is denied `networksetup`
    /// prints to stderr and exits non-zero, and the caller is expected to hand
    /// the user the exact command to run by hand.
    public static func setEnabled(_ name: String, _ enabled: Bool) throws {
        let output = try runThrowing(["-setnetworkserviceenabled", name, enabled ? "on" : "off"])
        _ = output
    }

    public static func setEnabled(device: String, _ enabled: Bool) throws {
        guard let match = service(for: device) else {
            throw HostNetworkError.serviceNotFound(device)
        }
        try setEnabled(match.name, enabled)
    }

    /// The command to show the user when the app is not allowed to change it.
    public static func manualCommand(_ name: String, _ enabled: Bool) -> String {
        "sudo networksetup -setnetworkserviceenabled \"\(name)\" \(enabled ? "on" : "off")"
    }

    // MARK: - Process plumbing

    private static func numberedName(_ line: String) -> String? {
        guard line.hasPrefix("("), let close = line.firstIndex(of: ")") else { return nil }
        let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// Pulls `en17` out of `(Hardware Port: Baiwang, Device: en17)`.
    private static func deviceToken(in line: String) -> String? {
        guard let range = line.range(of: "Device:") else { return nil }
        // `Device: en0` has a space after the colon; skip it before taking the
        // token, or the scan stops on the very first character.
        let tail = line[range.upperBound...].drop { $0.isWhitespace }
        let token = tail.prefix { !$0.isWhitespace && $0 != ")" && $0 != "," }
        return token.isEmpty ? nil : String(token)
    }

    @discardableResult
    private static func run(_ arguments: [String]) throws -> String {
        try runThrowing(arguments)
    }

    /// How long any single `networksetup` call may take.
    ///
    /// This is not paranoia about a slow tool: `networksetup` goes through
    /// Authorization Services, and in an environment that cannot reach it the
    /// call does not fail — it blocks. A menu-bar app that blocks on a status
    /// poll stops redrawing and looks hung, so every call is bounded and a
    /// timeout is reported like any other failure.
    private static let timeout: TimeInterval = 6

    @discardableResult
    private static func runThrowing(_ arguments: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw HostNetworkError.toolMissing(tool)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // networksetup reads nothing, but a closed stdin keeps it from ever
        // blocking on a prompt if a future command does.
        process.standardInput = FileHandle.nullDevice

        try process.run()

        // Kill it if it goes away to think. `terminate` is SIGTERM, which
        // unblocks the read below whether the process was idle or waiting on a
        // dialog.
        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        // Drain before waiting: a child that fills the pipe buffer would
        // otherwise never exit and the wait would never return.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw HostNetworkError.failed(command: "networksetup " + arguments.joined(separator: " "),
                                          status: process.terminationStatus,
                                          output: text)
        }
        return text
    }
}
