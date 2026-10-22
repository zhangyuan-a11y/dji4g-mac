import Foundation

/// 资源包查找。
///
/// SwiftPM 会给带资源的目标自动生成一个 `Bundle.module`，它只检查两个位置：
///
///   1. `Bundle.main.bundleURL/DJI4G_DJI4GMenuBar.bundle`
///      —— 对 .app 来说就是 `DJI4G.app/`，可打包脚本把资源放在
///      `Contents/Resources/` 下，这里必然落空；
///   2. 编译那一台机器上的 `.build/…/DJI4G_DJI4GMenuBar.bundle`
///      —— 绝对路径，写死在二进制里。
///
/// 于是 (1) 永远落空，(2) 只在开发机上成立。客户机上两条都不存在，
/// `Bundle.module` 直接 `fatalError` —— 2026-09-25 客户发回来的 25 份
/// 崩溃报告全是这一行，表现出来就是「点开面板就没了」；而本机因为 (2)
/// 恰好存在，一直没露馅。
///
/// 这里按 app 的真实布局自己找一遍。找不到不算错误：点阵字没了还有系统
/// 等宽字体顶着 —— 难看一点可以接受，闪退不行。
public enum AppResources {

    /// SwiftPM 的资源包名：`<package>_<target>.bundle`。
    public static let menuBarBundleName = "DJI4G_DJI4GMenuBar.bundle"

    /// 运行时按 app 的真实布局排出来的候选目录，可信的排前面。
    public static func searchDirectories() -> [URL] {
        var dirs: [URL] = []
        // app 里资源真正待的地方：DJI4G.app/Contents/Resources/
        if let resources = Bundle.main.resourceURL { dirs.append(resources) }
        // 跟着可执行文件走：DJI4G.app/Contents/MacOS/
        if let executable = Bundle.main.executableURL {
            dirs.append(executable.deletingLastPathComponent())
        }
        // SwiftPM 默认会看的位置（app 根目录），以及裸二进制直接跑（开发时）
        dirs.append(Bundle.main.bundleURL)
        // 注意：不要把「app 的上一级目录」放进来。那是 /Applications，一个
        // 放错地方的 doto.ttf 就能让这里误判成「资源在」，把真正的缺失盖住
        // —— 负向测试里 /tmp/doto.ttf 正是这么骗过一次。
        return dedupe(dirs)
    }

    /// 一个 .app 里该找哪些目录。给 `dji4gctl fontcheck` 用：客户机上也能
    /// 照 app 的布局验一遍，不必等人点开面板才知道会不会崩。
    public static func searchDirectories(inAppBundle app: URL) -> [URL] {
        dedupe([
            app.appendingPathComponent("Contents/Resources"),
            app.appendingPathComponent("Contents/MacOS"),
            app
        ])
    }

    /// 在候选目录里找资源。名字对不上时不硬认名字：目录里任意一个
    /// `.bundle` 里能找到目标文件就算数，免得下次改包名又崩一次。
    public static func url(forResource name: String,
                           withExtension ext: String,
                           bundleName: String = menuBarBundleName,
                           directories: [URL]) -> URL? {
        for dir in directories {
            if let bundle = Bundle(url: dir.appendingPathComponent(bundleName)),
               let hit = bundle.url(forResource: name, withExtension: ext) {
                return hit
            }
        }
        for dir in directories {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for entry in entries where entry.pathExtension == "bundle" {
                if let bundle = Bundle(url: entry),
                   let hit = bundle.url(forResource: name, withExtension: ext) {
                    return hit
                }
            }
        }
        // 也有把资源直接摊在 Contents/Resources 里的放法
        for dir in directories {
            let direct = dir.appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
        }
        return nil
    }

    /// 运行时取资源。找不到返回 nil —— 调用方必须能接受「没有」。
    public static func url(forResource name: String, withExtension ext: String) -> URL? {
        url(forResource: name, withExtension: ext,
            bundleName: menuBarBundleName,
            directories: searchDirectories())
    }

    static func dedupe(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for url in urls {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted { out.append(url) }
        }
        return out
    }
}
