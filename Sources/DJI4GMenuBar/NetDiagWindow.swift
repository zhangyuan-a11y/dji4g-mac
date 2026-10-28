import AppKit
import SwiftUI

/// 「网络诊断」窗口：复用 App 内置的 `dji4gctl net-diag`，不重复开发 AT 代码。
///
/// 默认只读：`dji4gctl net-diag` 只发 `?` 形式的查询命令，不改 APN、不拨号、
/// 不重启模块、不动默认路由。诊断结果是真实检查，不是模拟数据 —— 模拟器只在
/// 明确加 `--sim` 的开发/测试场景启用，正常使用不会触发。
struct NetDiagWindow: View {
    @Environment(\.openWindow) private var openWindow
    @State private var output: String = "点击「开始诊断」进行网络数据连接检查…"
    @State private var isRunning = false
    @State private var exportPath: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("网络诊断").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("只读，不改动任何设置")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.inkNote)
            }

            ScrollView {
                Text(output)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Theme.screen)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if !exportPath.isEmpty {
                Text("已导出：\(exportPath)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.inkNote)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                Button(isRunning ? "检测中…" : "开始诊断") { run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning)
                Button("导出诊断报告") { export() }
                    .disabled(isRunning || output.isEmpty)
                Button("复制诊断摘要") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
                .disabled(output.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 520, height: 420)
        .background(Theme.chrome)
        .onAppear { run() }
    }

    // MARK: - 运行诊断

    private func run() {
        isRunning = true
        output = "正在检测…"
        DispatchQueue.global(qos: .userInitiated).async {
            let text = NetDiagRunner.runNetDiag()
            DispatchQueue.main.async {
                output = text
                isRunning = false
            }
        }
    }

    private func export() {
        let text = output
        DispatchQueue.global(qos: .userInitiated).async {
            let path = NetDiagRunner.exportReport(text: text)
            DispatchQueue.main.async { exportPath = path }
        }
    }
}

/// 负责拉起内置 `dji4gctl net-diag`，以及把结果脱敏后打成 ZIP。
enum NetDiagRunner {

    /// App 内置的 dji4gctl。开发环境（SwiftPM 裸跑）里没有 Contents/Resources，
    /// 退回 PATH 上的那一份。
    static var binaryURL: URL? {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("dji4gctl")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }
        return URL(fileURLWithPath: "/usr/local/bin/dji4gctl")
    }

    /// 跑一次 `dji4gctl net-diag`，把 stdout+stderr 都带回来。
    static func runNetDiag() -> String {
        guard let binary = binaryURL, FileManager.default.isExecutableFile(atPath: binary.path) else {
            return "找不到内置诊断程序 dji4gctl。请重新安装。"
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["net-diag"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return "无法启动诊断程序：\(error)"
        }
        // dji4gctl net-diag 发十几条 AT，每条最多 6 秒；给它一个宽松上限，
        // 超时就停掉，别让窗口一直转。
        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: watchdog)
        defer { watchdog.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// 把诊断文本脱敏后写进一个 ZIP，放在桌面。
    static func exportReport(text: String) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let tag = stamp.string(from: Date())
        let dirName = "DJI4G-网络诊断-\(tag)"

        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dji4g-netdiag-\(tag)")
        let dir = work.appendingPathComponent(dirName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let redacted = Self.redact(text)
            let body = "DJI 4G 模块 · 网络诊断报告\n生成时间：\(Date())\n\n\(redacted)\n"
            try body.write(to: dir.appendingPathComponent("诊断报告.txt"),
                           atomically: true, encoding: .utf8)
            let zip = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Desktop/\(dirName).zip")
            if FileManager.default.fileExists(atPath: zip.path) {
                try FileManager.default.removeItem(at: zip)
            }
            // ditto 保留 UTF-8 中文名与可执行位；这里只是文本报告，权限无所谓。
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", dir.path, zip.path]
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return zip.path
        } catch {
            return "导出失败：\(error)"
        }
    }

    /// 脱敏：IMEI / ICCID / 手机号 / 国际号码。与命令行诊断工具同一套规则。
    static func redact(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "\\+[0-9]{11,15}",
                                             with: "[号码已隐藏]",
                                             options: .regularExpression)
        result = result.replacingOccurrences(of: "[0-9]{14,}",
                                             with: "[IMEI/ICCID已隐藏]",
                                             options: .regularExpression)
        result = result.replacingOccurrences(of: "1[3-9][0-9]{9}",
                                             with: "[手机号已隐藏]",
                                             options: .regularExpression)
        return result
    }
}
