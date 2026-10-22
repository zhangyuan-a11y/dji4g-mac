import SwiftUI
import AppKit
import CoreText
import DJI4GCore

// MARK: - 可改的文案（品牌 / 页脚 / 每页标题都收在这里）

enum Copy {
    static let brand = "DJI 4G 改装服务"
    static let footer = "DJI4G · 一代模块 · 远程改装"
}

// MARK: - 设计令牌

enum P {
    static let paper     = Color(red: 0.949, green: 0.941, blue: 0.925)
    static let ink       = Color(red: 0.078, green: 0.086, blue: 0.090)
    static let inkSoft   = Color(red: 0.380, green: 0.396, blue: 0.408)
    static let inkFaint  = Color(red: 0.600, green: 0.612, blue: 0.620)
    static let green     = Color(red: 0.145, green: 0.722, blue: 0.376)
    static let greenDeep = Color(red: 0.055, green: 0.478, blue: 0.243)
    static let hair      = Color(red: 0.851, green: 0.843, blue: 0.824)
    static let screen    = Color(red: 0.055, green: 0.065, blue: 0.065)
}

// MARK: - 字体

enum F {
    static let doto: String = {
        guard let url = AppResources.url(forResource: "doto", withExtension: "ttf") else { return "" }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let list = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let name = CTFontDescriptorCopyAttribute(list[0], kCTFontFamilyNameAttribute) as? String
        else { return "" }
        return name
    }()

    /// 点阵字，产品 UI 用的就是它。
    static func dot(_ size: CGFloat) -> Font {
        doto.isEmpty ? .system(size: size, design: .monospaced) : .custom(doto, size: size)
    }
    /// 中文正文／标题。
    static func cn(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

// MARK: - 素材

enum Assets {
    static let dir = URL(fileURLWithPath:
        ProcessInfo.processInfo.environment["DJI4G_PROMO_ASSETS"] ?? "./work/promo/assets")
    private static var cache: [String: NSImage] = [:]

    static func shot(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let image = NSImage(contentsOf: dir.appendingPathComponent("ui/\(name).png")) else { return nil }
        cache[name] = image
        return image
    }
}

// MARK: - 底纹

/// 点阵底纹：产品的记谱法就是圆点，整张海报沿用同一套语汇。
struct DotField: View {
    var spacing: CGFloat = 36
    var radius: CGFloat = 1.7

    var body: some View {
        Canvas { context, size in
            let cols = Int(size.width / spacing) + 2
            let rows = Int(size.height / spacing) + 2
            var path = Path()
            for column in 0..<cols {
                for row in 0..<rows {
                    let x = CGFloat(column) * spacing
                    let y = CGFloat(row) * spacing
                    path.addEllipse(in: CGRect(x: x - radius, y: y - radius,
                                               width: radius * 2, height: radius * 2))
                }
            }
            context.fill(path, with: .color(P.ink.opacity(0.075)))
        }
    }
}

extension View {
    /// 一张固定尺寸的海报：暖白纸底 + 点阵底纹。
    func poster(_ width: CGFloat, _ height: CGFloat) -> some View {
        self
            .frame(width: width, height: height)
            .background {
                ZStack {
                    P.paper
                    DotField()
                }
            }
            .clipped()
    }
}

// MARK: - 通用组件

struct Eyebrow: View {
    var text: String
    var body: some View {
        HStack(spacing: 12) {
            Capsule().fill(P.green).frame(width: 30, height: 4)
            Text(text.uppercased()).font(F.dot(25)).tracking(2.4).foregroundStyle(P.greenDeep)
        }
    }
}

struct PosterHeader: View {
    var index: String?
    var body: some View {
        HStack(spacing: 13) {
            Circle().fill(P.green).frame(width: 15, height: 15)
            Text(Copy.brand).font(F.cn(27, .semibold)).foregroundStyle(P.ink)
            Spacer()
            if let index {
                Text(index).font(F.dot(27)).foregroundStyle(P.inkSoft)
            }
        }
    }
}

struct PosterFooter: View {
    var body: some View {
        HStack(spacing: 0) {
            Text(Copy.footer).font(F.dot(23)).tracking(1.2).foregroundStyle(P.inkFaint)
            Spacer()
            HStack(spacing: 9) {
                Circle().fill(P.green.opacity(0.85)).frame(width: 9, height: 9)
                Text("FOR macOS").font(F.dot(23)).tracking(1.2).foregroundStyle(P.inkFaint)
            }
        }
    }
}

struct Headline: View {
    var lines: [String]
    var size: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(F.cn(size, .bold))
                    .foregroundStyle(P.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct HeroCard: View {
    var shot: String
    var height: CGFloat
    var padding: CGFloat = 30

    var body: some View {
        Group {
            if let image = Assets.shot(shot) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: height)
            } else {
                Color.clear.frame(height: height)
            }
        }
        .padding(padding)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(P.hair, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 26, y: 12)
        )
    }
}

struct Chip: View {
    var label: String
    var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(F.dot(21)).tracking(1.4).foregroundStyle(P.inkSoft)
            Text(value).font(F.cn(30, .semibold)).foregroundStyle(P.ink).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(P.hair, lineWidth: 1)
                )
        )
    }
}

struct NoteCard: View {
    var text: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle().fill(P.green).frame(width: 10, height: 10).padding(.top, 11)
            Text(text)
                .font(F.cn(27))
                .foregroundStyle(P.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(P.green.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(P.green.opacity(0.28), lineWidth: 1)
                )
        )
    }
}

struct ShotTile: View {
    var shot: String
    var box: CGSize
    /// 面板类截图的上半段三张长得几乎一样，裁到底部才看得出是哪一屏。
    var crop: Alignment?

    var body: some View {
        Group {
            if let image = Assets.shot(shot) {
                if let crop {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: box.width, height: box.height, alignment: crop)
                        .clipped()
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: box.width, height: box.height)
                }
            } else {
                Color.clear.frame(width: box.width, height: box.height)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(P.hair, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.05), radius: 14, y: 6)
        )
    }
}

/// 编号 + 点阵小标题 + 中文说明，功能页和步骤页共用。
struct NumberedRow: View {
    var number: String
    var label: String
    var title: String
    var body_: String
    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            Text(number).font(F.dot(44)).foregroundStyle(P.green).frame(width: 66, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(label).font(F.dot(24)).tracking(2).foregroundStyle(P.inkSoft)
                    Text(title).font(F.cn(34, .semibold)).foregroundStyle(P.ink)
                }
                Text(body_).font(F.cn(26)).foregroundStyle(P.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(P.hair).frame(height: 1) }
    }
}
