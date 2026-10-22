import Foundation

/// Start-at-login for the menu bar app.
///
/// The module lives on the back of a Mac so that a call or a text can land at
/// any hour, which only works if the app comes back by itself after a reboot.
/// Without this, the menu bar is simply empty after a restart and every call
/// during that window is a missed one — with no error anywhere to explain it.
///
/// A LaunchAgent is the mechanism rather than `SMAppService` (the macOS 13
/// API): `SMAppService` refuses to register an ad-hoc signed bundle, and every
/// copy this project ships is ad-hoc signed. A LaunchAgent is also entirely
/// user-level, so nothing here asks for an administrator password, and removal
/// is one `rm` with no leftover state.
///
/// Nothing in here calls `launchctl`. Dropping the plist into
/// `~/Library/LaunchAgents` is all that is required — launchd reads that
/// directory at login on its own — and *not* bootstrapping it now is
/// deliberate: `bootstrap` would start a second copy of the app beside the one
/// the installer just opened, leaving two icons fighting over the serial port.
public enum LoginItem {
    /// Matches the app's `CFBundleIdentifier`, so `launchctl` output and the
    /// file in `~/Library/LaunchAgents` are both greppable by the same string.
    public static let label = "local.dji4g.menubar"

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    public static var plistURL: URL {
        directory.appendingPathComponent("\(label).plist")
    }

    /// Where launchd drops whatever the app prints before it has a window.
    /// Kept because the one failure this feature has is silent by nature: the
    /// app not starting looks exactly like the feature working, until a call is
    /// missed.
    public static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DJI4G", isDirectory: true)
            .appendingPathComponent("menubar.log")
    }

    /// The executable to register: the app's own binary, never `dji4gctl`.
    public static func executablePath(inApp app: URL) -> String {
        app.appendingPathComponent("Contents/MacOS/DJI4GMenuBar").path
    }

    /// Walks up from an executable that lives inside an app bundle
    /// (`…/DJI4G.app/Contents/Resources/dji4gctl`) back to the bundle itself.
    /// Returns nil for a bare `.build/…` binary, which is what keeps the
    /// development path from registering a login item that points at a scratch
    /// directory.
    public static func appBundle(containing executable: URL) -> URL? {
        var url = executable.resolvingSymlinksInPath()
        for _ in 0..<3 { url = url.deletingLastPathComponent() }
        guard url.pathExtension == "app" else { return nil }
        // `deletingLastPathComponent` marks each result as a directory, which
        // gives it a trailing slash in `absoluteString` — and `URL` equality is
        // string equality, so the same bundle would compare unequal to one built
        // with `URL(fileURLWithPath:)`. Rebuild it flat so callers can compare
        // the result with `==` and get the answer they expect.
        return URL(fileURLWithPath: url.path)
    }

    /// The file that makes the feature work. Pure so the self test can read it
    /// without touching the real `~/Library`.
    public static func plist(binaryPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(xml(label))</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(xml(binaryPath))</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<dict>
        \t\t<key>SuccessfulExit</key>
        \t\t<false/>
        \t</dict>
        \t<key>StandardOutPath</key>
        \t<string>\(xml(logURL.path))</string>
        \t<key>StandardErrorPath</key>
        \t<string>\(xml(logURL.path))</string>
        </dict>
        </plist>
        """
    }

    /// Reads back the executable path from a plist. Deliberately a plain scan
    /// rather than `PropertyListSerialization`: this parses a file the app
    /// itself wrote, and the self test needs the same code path to be
    /// inspectable without a temporary file.
    public static func binaryPath(inPlist text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() where line.contains("<key>ProgramArguments</key>") {
            for follower in lines.dropFirst(index + 1) where follower.contains("<string>") {
                return unescape(follower
                    .replacingOccurrences(of: "<string>", with: "")
                    .replacingOccurrences(of: "</string>", with: "")
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    public struct Status: Equatable {
        public var installed = false
        /// Path recorded in the plist, whether or not it still exists.
        public var binaryPath: String?
        /// False when the app has been moved or deleted since it was enabled.
        public var binaryExists = false

        public init() {}

        /// One line for the panel, in the words a customer would use.
        public var detail: String {
            guard installed else { return "重启电脑后不会自动运行，来电和短信都收不到" }
            guard let path = binaryPath else { return "已开启，但记录的内容读不出来，建议关掉再开一次" }
            guard binaryExists else { return "指向的 App 已经不在了（\(path)），建议关掉再开一次" }
            return "重启电脑后自动运行，不用手动打开"
        }
    }

    /// Best-effort and never throws: a menu bar app that cannot read its own
    /// login item should say "关" rather than take the panel down with it.
    public static func status() -> Status {
        var status = Status()
        guard let text = try? String(contentsOf: plistURL, encoding: .utf8) else { return status }
        status.installed = true
        status.binaryPath = binaryPath(inPlist: text)
        if let path = status.binaryPath {
            status.binaryExists = FileManager.default.isExecutableFile(atPath: path)
        }
        return status
    }

    /// Writes the plist. Takes effect at the next login; see the type comment
    /// for why this does not also load it into the current session.
    @discardableResult
    public static func install(app: URL) throws -> Status {
        let binary = executablePath(inApp: app)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist(binaryPath: binary).write(to: plistURL, atomically: true, encoding: .utf8)
        return status()
    }

    /// Removes the plist, which is the whole feature.
    ///
    /// No `launchctl bootout` on purpose: if the running app *is* the agent's
    /// instance, that would quit the app the user is looking at, and the plist
    /// alone is already enough to keep it from coming back at the next login.
    public static func remove() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    // MARK: - XML

    /// A path can contain `&` or `<` (a home directory can, and Photos has
    /// opinions), and an unescaped one produces a plist launchd silently
    /// refuses to load.
    static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
