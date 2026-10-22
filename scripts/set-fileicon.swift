// 给文件或文件夹挂上 Finder 自定义图标。
//
// 为什么不是 shell：Finder 的自定义图标存在两个扩展属性里（com.apple.ResourceFork
// 里的 icns 资源 + com.apple.FinderInfo 的 kHasCustomIcon 位），macOS 没有命令行
// 工具做这件事；xattr(1) 只能收字符串，几十万字节的图标塞不进命令行。这里直接
// 调 NSWorkspace.setIcon —— 系统自己的实现，图标缓存也顺手刷新了。
//
// 用法：set-fileicon <图标.icns> <目标> [目标...]
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    FileHandle.standardError.write("用法：set-fileicon <图标.icns> <目标> [目标...]\n".data(using: .utf8)!)
    exit(2)
}
guard let icon = NSImage(contentsOfFile: args[0]) else {
    FileHandle.standardError.write("读不出图标：\(args[0])\n".data(using: .utf8)!)
    exit(2)
}
var failed = false
for target in args.dropFirst() {
    guard FileManager.default.fileExists(atPath: target) else {
        FileHandle.standardError.write("跳过（不存在）：\(target)\n".data(using: .utf8)!)
        failed = true
        continue
    }
    let ok = NSWorkspace.shared.setIcon(icon, forFile: target, options: [])
    print("\(ok ? "已设图标" : "设置失败")：\(target)")
    if !ok { failed = true }
}
exit(failed ? 1 : 0)
