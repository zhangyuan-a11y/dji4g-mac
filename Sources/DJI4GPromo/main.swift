import SwiftUI
import AppKit

/// 把一张海报画成 PNG。
///
/// 和 App 的截图渲染走同一条路：托管进一个屏幕外的无边框窗口，再 cacheDisplay
/// 到位图。不用 ImageRenderer，也不用无头浏览器 —— 这台机器上两者都不可用。
@MainActor
func render(_ view: some View, _ name: String,
            width: CGFloat, height: CGFloat, scale: CGFloat, to directory: URL) {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.contentView = hosting
    window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
    hosting.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        FileHandle.standardError.write(Data("位图分配失败：\(name)\n".utf8))
        return
    }
    bitmap.size = NSSize(width: width, height: height)
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("编码失败：\(name)\n".utf8))
        return
    }
    try? data.write(to: directory.appendingPathComponent("\(name).png"))
    print("\(name).png  \(Int(width * scale))×\(Int(height * scale))")
    window.contentView = nil
}

// MARK: - 电商图：把分屏竖着拼成一张长图（详情页用）

@MainActor
func stitch(_ files: [String], in directory: URL, to output: String) {
    var images: [CGImage] = []
    for name in files {
        let url = directory.appendingPathComponent("\(name).png")
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            FileHandle.standardError.write(Data("拼接缺图：\(name).png\n".utf8))
            return
        }
        images.append(image)
    }
    let width = images.map(\.width).max() ?? 0
    let height = images.reduce(0) { $0 + $1.height }
    guard width > 0, height > 0,
          let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    var top = height
    for image in images {
        top -= image.height
        context.draw(image, in: CGRect(x: 0, y: top, width: image.width, height: image.height))
    }
    guard let merged = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: merged).representation(using: .png, properties: [:])
    else { return }
    try? data.write(to: directory.appendingPathComponent("\(output).png"))
    print("\(output).png  \(width)×\(height)")
}

/// 量一屏内容到底多高：按宽度排一次版，读它想要的高度。
@MainActor
func measureHeight(_ view: some View, width: CGFloat) -> CGFloat {
    let hosting = NSHostingView(rootView: view.frame(width: width))
    hosting.layoutSubtreeIfNeeded()
    return hosting.fittingSize.height
}

/// 详情页的屏序：渲染和量高度都用这一份，别再各写一遍。
let detailScreens: [(String, String)] = [
    ("详情页-01-封面", "封面"),
    ("详情页-02-三个能力", "三个能力"),
    ("详情页-03-接打电话", "接打电话"),
    ("详情页-04-收发短信", "收发短信"),
    ("详情页-05-4G上网", "4G上网"),
    ("详情页-06-菜单栏面板", "菜单栏面板"),
    ("详情页-07-安装三步", "安装三步"),
    ("详情页-08-实拍场景", "实拍场景"),
    ("详情页-09-参数", "参数"),
    ("详情页-10-服务承诺", "服务承诺"),
]

_ = NSApplication.shared

// 顶层代码在这个工具链里不是 main-actor 隔离的，而 AppKit 必须是。
MainActor.assumeIsolated {

    let arguments = CommandLine.arguments
    guard let flag = arguments.firstIndex(of: "--out"), arguments.count > flag + 1 else {
        FileHandle.standardError.write(Data("用法：DJI4GPromo --out <输出目录>\n".utf8))
        exit(2)
    }
    let directory = URL(fileURLWithPath: arguments[flag + 1])
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let scale = ProcessInfo.processInfo.environment["DJI4G_RENDER_SCALE"]
        .flatMap(Double.init).map { CGFloat($0) } ?? 1.5

    if arguments.contains("--measure") {
        for (name, section) in detailScreens {
            let height = measureHeight(DetailSection(name: section, measureOnly: true), width: 750)
            let delta = height - 1000
            let verdict = delta > 0 ? "溢出 \(Int(delta.rounded()))" : "余 \(Int((-delta).rounded()))"
            print("\(name)  高 \(Int(height.rounded()))  \(verdict)")
        }
        exit(0)
    }

    let shopOnly = arguments.contains("--shop")
    let detailOnly = arguments.contains("--detail")

    if shopOnly || detailOnly {
        if shopOnly {
            // 电商主图：1:1，五张
            render(ShopMain1(), "主图-01-封面", width: 1200, height: 1200, scale: scale, to: directory)
            render(ShopMain2(), "主图-02-三大功能", width: 1200, height: 1200, scale: scale, to: directory)
            render(ShopMain3(), "主图-03-菜单栏", width: 1200, height: 1200, scale: scale, to: directory)
            render(ShopMain4(), "主图-04-你手上那块模块", width: 1200, height: 1200, scale: scale, to: directory)
            render(ShopMain5(), "主图-05-服务承诺", width: 1200, height: 1200, scale: scale, to: directory)
        }
        if detailOnly {
            // 详情页：750 宽，逐屏 750×1000，再拼一张长图
            for (name, section) in detailScreens {
                render(DetailSection(name: section), name, width: 750, height: 1000, scale: scale, to: directory)
            }
            stitch(detailScreens.map(\.0), in: directory, to: "详情页-完整长图")
        }
        exit(0)
    }

    // 闲鱼 / 小红书图文：3:4，六页
    render(PageCover(), "01-cover", width: 1200, height: 1600, scale: scale, to: directory)
    render(PageFeatures(), "02-features", width: 1200, height: 1600, scale: scale, to: directory)
    render(PageCompare(), "03-compare", width: 1200, height: 1600, scale: scale, to: directory)
    render(PageSteps(), "04-steps", width: 1200, height: 1600, scale: scale, to: directory)
    render(PageCompat(), "05-compat", width: 1200, height: 1600, scale: scale, to: directory)
    render(PageService(), "06-service", width: 1200, height: 1600, scale: scale, to: directory)

    // 商品主图：1:1
    render(PageCover(width: 1200, height: 1200, heroHeight: 560,
                     headlineSize: 76, showChips: false, inset: 68),
           "square-cover", width: 1200, height: 1200, scale: scale, to: directory)

    // 朋友圈 / 抖音：9:16
    render(PageCover(width: 1080, height: 1920, heroHeight: 700,
                     headlineSize: 80, inset: 72),
           "story-cover", width: 1080, height: 1920, scale: scale, to: directory)

    exit(0)
}
