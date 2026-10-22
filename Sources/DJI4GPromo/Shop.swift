import SwiftUI
import AppKit
import DJI4GCore

// MARK: - 电商图：商品主图（1:1）+ 详情页（750 宽）
//
// 和 Promo.swift 共用同一套设计令牌（纸色 / 点阵 / 绿色），但版式不同：
// 主图要能当缩略图看，所以产品照片是主角、字号大、字少；
// 详情页要能顺着往下读，所以一屏一件事。
//
// 产品照片一律用真图：DJI 官方商店的产品照 + 论坛/实拍照片，
// 脚本不生成模块长什么样。

// MARK: - 素材（照片走 assets 根目录，界面截图走 ui/）

enum ShopAssets {
    private static var cache: [String: NSImage] = [:]

    /// 产品照 / 实拍图，放在 `DJI4G_PROMO_ASSETS` 根目录下。
    static func photo(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let image = NSImage(contentsOf: Assets.dir.appendingPathComponent("\(name).png")) else {
            FileHandle.standardError.write(Data("缺照片：\(name).png\n".utf8))
            return nil
        }
        cache[name] = image
        return image
    }

    /// 界面截图，和 Promo 共用 `ui/` 子目录。
    static func shot(_ name: String) -> NSImage? { Assets.shot(name) }
}

// MARK: - 排版组件

/// 产品照的白卡片：暖白底 + 发丝边 + 轻投影，产品在里面居中。
struct PhotoCard: View {
    var name: String
    var width: CGFloat
    var height: CGFloat
    /// 产品图自身的宽高比（不知道就传 nil，按卡片比例 fit）
    var aspect: CGFloat?
    var padding: CGFloat = 26
    var fill: NSImage.ResizingMode = .stretch

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.white)
            if let image = ShopAssets.photo(name) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(aspect ?? (width / height), contentMode: .fit)
                    .frame(width: width - padding * 2, height: height - padding * 2)
            }
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(P.hair, lineWidth: 1)
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.07), radius: 18, y: 8)
    }
}

/// 界面截图卡片：截图直接嵌白卡，不裁剪，按比例缩到框内。
struct ShotCard: View {
    var shot: String
    var width: CGFloat
    var height: CGFloat
    var padding: CGFloat = 18
    var caption: String?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let image = ShopAssets.shot(shot) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: width - padding * 2, height: height - padding * 2)
                }
            }
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(P.hair, lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.07), radius: 16, y: 7)

            if let caption {
                Text(caption)
                    .font(F.cn(30, .semibold))
                    .foregroundStyle(P.ink)
                    .padding(.top, 16)
            }
        }
    }
}

/// 实拍照卡片：整张图铺满卡片（裁切），用来做场景。
struct PhotoTile: View {
    var name: String
    var width: CGFloat
    var height: CGFloat
    var alignment: Alignment = .center

    var body: some View {
        ZStack {
            if let image = ShopAssets.photo(name) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height, alignment: alignment)
                    .clipped()
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(P.hair, lineWidth: 1))
    }
}

/// 一条卖点：点阵小标签 + 中文一行字。
struct PointRow: View {
    var label: String
    var title: String
    var size: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(F.dot(23)).tracking(2).foregroundStyle(P.greenDeep)
            Text(title).font(F.cn(size, .semibold)).foregroundStyle(P.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 承诺条：绿色对勾 + 一句话。
struct PromiseRow: View {
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ZStack {
                Circle().fill(P.green.opacity(0.13)).frame(width: 56, height: 56)
                Image(systemName: "checkmark").font(.system(size: 25, weight: .bold))
                    .foregroundStyle(P.greenDeep)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(F.cn(37, .semibold)).foregroundStyle(P.ink)
                Text(detail).font(F.cn(26)).foregroundStyle(P.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 真机菜单栏那条。截图是这台 Mac 上按 2 倍像素抓的，不是画的。
///
/// 2026-09-26 换过一次：上一版裁的是屏幕最右侧 800 点，正好把我们的图标
/// 漏在外面，海报上那条里根本没有自己。现在裁的是含着图标的一段，并在
/// 图标外面套一个绿框 —— 客户不需要自己找。
struct MenuBarStrip: View {
    var width: CGFloat
    var caption: String = "框里就是它：信号 + 4G"
    /// 原始条：1000×48 像素，代表屏幕上 500×24 点。
    private let sourceHeight: CGFloat = 48
    private let sourceWidth: CGFloat = 1000
    /// 图标在条内的位置（比例，量出来的）。
    private let itemX: ClosedRange<CGFloat> = 0.312...0.373
    private let itemY: ClosedRange<CGFloat> = 0.271...0.708

    var body: some View {
        let height = width * sourceHeight / sourceWidth
        let left = itemX.lowerBound * width
        let right = itemX.upperBound * width
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if let image = ShopAssets.photo("menubar-wide") {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: width, height: height)
                }
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(P.green, lineWidth: 2.5)
                    .frame(width: right - left + 16,
                           height: (itemY.upperBound - itemY.lowerBound) * height + 14)
                    .offset(x: left - 8, y: itemY.lowerBound * height - 7)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(P.hair, lineWidth: 1))

            Text(caption)
                .font(F.cn(23, .medium))
                .foregroundStyle(P.greenDeep)
                .padding(.leading, max(left - 8, 0))
        }
    }
}

// MARK: - 主图 01 / 让大疆 4G 模块在 Mac 上真正能用

struct ShopMain1: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PosterHeader(index: "01 / 05")
            Spacer(minLength: 16)
            PhotoCard(name: "product-front", width: 1064, height: 470, aspect: 924.0 / 416.0, padding: 44)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 16)
            Headline(lines: ["大疆 4G 模块，", "在 Mac 上真正能用。"], size: 82)
            Spacer(minLength: 14)
            Text("接打电话 · 收发短信 · 4G 上网")
                .font(F.cn(38, .medium)).foregroundStyle(P.inkSoft)
            Spacer(minLength: 18)
            HStack(spacing: 14) {
                Chip(label: "CALLS", value: "接打电话")
                Chip(label: "SMS", value: "收发短信")
                Chip(label: "DATA", value: "4G 上网")
            }
            Spacer(minLength: 16)
            PosterFooter()
        }
        .padding(68)
        .poster(1200, 1200)
    }
}

// MARK: - 主图 02 / 三件事，件件真机跑过

struct ShopMain2: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PosterHeader(index: "02 / 05")
            Spacer(minLength: 14)
            Eyebrow(text: "三件事")
            Spacer(minLength: 12)
            Headline(lines: ["接电话 · 收短信 · 上网"], size: 74)
            Spacer(minLength: 10)
            Text("下面三张都是真机截图，不是示意图。")
                .font(F.cn(30)).foregroundStyle(P.inkSoft)
            Spacer(minLength: 20)
            HStack(alignment: .top, spacing: 18) {
                ShotCard(shot: "window-call-waiting", width: 336, height: 400, caption: "接打电话")
                ShotCard(shot: "panel-sms", width: 336, height: 400, caption: "收发短信")
                ShotCard(shot: "panel-network", width: 336, height: 400, caption: "4G 上网")
            }
            Spacer(minLength: 18)
            NoteCard(text: "通话两个方向都有声音。第一次用之前点一次「一键安装」即可 —— 模块出厂不带这条通路。")
            Spacer(minLength: 14)
            PosterFooter()
        }
        .padding(60)
        .poster(1200, 1200)
    }
}

// MARK: - 主图 03 / 就在菜单栏里

struct ShopMain3: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PosterHeader(index: "03 / 05")
            Spacer(minLength: 14)
            Eyebrow(text: "菜单栏常驻")
            Spacer(minLength: 12)
            Headline(lines: ["插上模块，", "菜单栏右上角就有它。"], size: 76)
            Spacer(minLength: 12)
            Text("点一下展开控制面板，不用开别的窗口。")
                .font(F.cn(30)).foregroundStyle(P.inkSoft)
            Spacer(minLength: 22)
            VStack(alignment: .leading, spacing: 10) {
                Text("这台 Mac 的菜单栏（实拍）").font(F.cn(24, .medium)).foregroundStyle(P.inkSoft)
                MenuBarStrip(width: 1064)
            }
            Spacer(minLength: 22)
            HStack(alignment: .top, spacing: 22) {
                ShotCard(shot: "panel-module", width: 320, height: 500, padding: 16)
                VStack(alignment: .leading, spacing: 26) {
                    PointRow(label: "STATUS", title: "信号、注册、运营商一眼看到")
                    PointRow(label: "TRAFFIC", title: "本月用了多少，实时估算")
                    PointRow(label: "SWITCH", title: "4G 开关、应用路由都在这里")
                }
                .frame(width: 520, alignment: .leading)
            }
            Spacer(minLength: 14)
            PosterFooter()
        }
        .padding(60)
        .poster(1200, 1200)
    }
}

// MARK: - 主图 04 / 你手上那块模块

struct ShopMain4: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PosterHeader(index: "04 / 05")
            Spacer(minLength: 14)
            Eyebrow(text: "你手上那块模块")
            Spacer(minLength: 12)
            Headline(lines: ["它本来只服务无人机，", "现在还能服务你的 Mac。"], size: 70)
            Spacer(minLength: 20)
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 14) {
                    PhotoTile(name: "real-drone", width: 520, height: 380)
                    Text("装在大疆遥控器支架上").font(F.cn(28)).foregroundStyle(P.inkSoft)
                }
                VStack(spacing: 14) {
                    PhotoTile(name: "product-back", width: 520, height: 380, alignment: .center)
                    Text("一代 4G 模块（QDC507）").font(F.cn(28)).foregroundStyle(P.inkSoft)
                }
            }
            Spacer(minLength: 22)
            NoteCard(text: "模块本身不用改、不用拆。改的是它的 USB 工作方式，随时能改回出厂状态。")
            Spacer(minLength: 14)
            PosterFooter()
        }
        .padding(60)
        .poster(1200, 1200)
    }
}

// MARK: - 主图 05 / 承诺

struct ShopMain5: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PosterHeader(index: "05 / 05")
            Spacer(minLength: 14)
            Eyebrow(text: "服务承诺")
            Spacer(minLength: 12)
            Headline(lines: ["不改硬件，可以改回。"], size: 82)
            Spacer(minLength: 26)
            VStack(spacing: 30) {
                PromiseRow(title: "不用邮寄", detail: "模块在你手上，装完就用，全程不用寄来寄去")
                PromiseRow(title: "不动硬件", detail: "拧螺丝、拆壳、焊线，一样都不做")
                PromiseRow(title: "可以改回", detail: "跑一遍卸载工具就回原厂状态，无人机那边照常用")
                PromiseRow(title: "远程协助", detail: "真跑不通，我看你的诊断输出，一步步带你排")
            }
            Spacer(minLength: 22)
            PhotoCard(name: "product-angle", width: 620, height: 360, aspect: 448.0 / 245.0, padding: 24)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 14)
            PosterFooter()
        }
        .padding(64)
        .poster(1200, 1200)
    }
}
