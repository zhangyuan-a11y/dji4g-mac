import SwiftUI
import AppKit
import DJI4GCore

// MARK: - 电商详情页：750 宽，一屏一件事
//
// 主图是「缩略图就得看懂」，详情页是「顺着往下读」。
// 所以这里字号小一档、每屏一个主题，底部留白少一点。
// 产品照依旧用真图（DJI 官方产品照 + 实拍），界面截图全部来自真机。

// MARK: - 本页专用小组件

/// 按原始比例摆放的界面截图：宽度定死，高度自己算，不裁不糊。
struct ShotAspect: View {
    var name: String
    var width: CGFloat
    var radius: CGFloat = 18

    var body: some View {
        Group {
            if let image = ShopAssets.shot(name), image.size.width > 0 {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: width, height: width * image.size.height / image.size.width)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(P.hair, lineWidth: 1))
                    .shadow(color: .black.opacity(0.06), radius: 14, y: 6)
            } else {
                Color.clear.frame(width: width, height: width * 0.5)
            }
        }
    }
}

/// 详情页里的一条说明：绿点 + 一行字。
struct Bullet: View {
    var title: String
    var detail: String?
    var size: CGFloat = 28

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(P.green).frame(width: 9, height: 9).padding(.top, size * 0.42)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(F.cn(size, .semibold)).foregroundStyle(P.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(F.cn(size - 4)).foregroundStyle(P.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// 编号步骤：01 大字 + 标题 + 说明。
struct DetailStep: View {
    var number: String
    var title: String
    var detail: String
    var titleSize: CGFloat = 32
    var detailSize: CGFloat = 25

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Text(number).font(F.dot(38)).foregroundStyle(P.green)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(F.cn(titleSize, .semibold)).foregroundStyle(P.ink)
                Text(detail).font(F.cn(detailSize)).foregroundStyle(P.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 详情页屏头：左边小标 + 右边页码。
struct SectionHead: View {
    var label: String
    var page: String

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(P.green).frame(width: 11, height: 11)
            Text(label.uppercased()).font(F.dot(23)).tracking(2).foregroundStyle(P.greenDeep)
            Spacer()
            Text(page).font(F.dot(23)).foregroundStyle(P.inkFaint)
        }
    }
}

// MARK: - 九个屏

struct DetailSection: View {
    var name: String
    /// 只排版、不套固定画布：用来量这一屏到底多高。
    var measureOnly = false

    var body: some View {
        Group {
            if measureOnly {
                content.padding(56)
            } else {
                content.padding(56).poster(750, 1000)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch name {
        case "封面":          CoverSection()
        case "三个能力":       AbilitySection()
        case "接打电话":       CallSection()
        case "收发短信":       SmsSection()
        case "4G上网":        DataSection()
        case "菜单栏面板":     MenuSection()
        case "安装三步":       InstallSection()
        case "实拍场景":       SceneSection()
        case "参数":           SpeedSection()
        default:              PromiseSection()
        }
    }
}

// MARK: 01 封面

struct CoverSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(label: "DJI 4G 改装服务", page: "01 / 10")
            Spacer(minLength: 16)
            PhotoCard(name: "product-front", width: 638, height: 356,
                      aspect: 924.0 / 416.0, padding: 34)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 22)
            Text("大疆 4G 模块")
                .font(F.cn(60, .bold)).foregroundStyle(P.ink)
            Text("在 Mac 上真正能用")
                .font(F.cn(60, .bold)).foregroundStyle(P.ink)
                .padding(.top, 6)
            Spacer(minLength: 14)
            Text("接打电话 · 收发短信 · 4G 上网")
                .font(F.cn(32, .medium)).foregroundStyle(P.inkSoft)
            Spacer(minLength: 10)
            Text("一代模块 QDC507 · 免拆免改 · 可以改回")
                .font(F.cn(24)).foregroundStyle(P.inkFaint)
            Spacer(minLength: 22)
            HStack(spacing: 12) {
                Chip(label: "CALLS", value: "接打电话")
                Chip(label: "SMS", value: "收发短信")
                Chip(label: "DATA", value: "4G 上网")
            }
            Spacer(minLength: 0)
            PosterFooter()
        }
    }
}

// MARK: 02 三个能力

struct AbilitySection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(label: "它能做什么", page: "02 / 10")
            Spacer(minLength: 18)
            Text("模块插上 Mac，\n就多了三个能力。")
                .font(F.cn(50, .bold)).foregroundStyle(P.ink)
                .lineSpacing(8)
            Spacer(minLength: 30)
            VStack(alignment: .leading, spacing: 30) {
                DetailStep(number: "01", title: "接打电话",
                        detail: "来电直接弹窗，点一下接听；声音走 Mac 的扬声器和麦克风。")
                DetailStep(number: "02", title: "收发短信",
                        detail: "短信列表、会话、发送都在面板里，验证码不用掏手机。")
                DetailStep(number: "03", title: "4G 上网",
                        detail: "模块当网卡用，还能只让指定 App 走 4G，其余继续走 Wi-Fi。")
            }
            Spacer(minLength: 26)
            NoteCard(text: "模块本身不用改、不用拆，随时能改回出厂状态。")
            Spacer(minLength: 0)
            PosterFooter()
        }
    }
}

// MARK: 03 接打电话

struct CallSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(label: "功能一", page: "03 / 10")
            Spacer(minLength: 14)
            Text("接打电话").font(F.cn(52, .bold)).foregroundStyle(P.ink)
            Spacer(minLength: 8)
            Text("来电弹窗、通话界面、挂断都在 Mac 上完成。")
                .font(F.cn(26)).foregroundStyle(P.inkSoft)
            Spacer(minLength: 22)
            HStack(alignment: .top, spacing: 24) {
                ShotCard(shot: "window-call-waiting", width: 320, height: 328, padding: 14)
                VStack(alignment: .leading, spacing: 22) {
                    Bullet(title: "来电自动弹出", detail: "不用盯着模块，Mac 上直接提示", size: 26)
                    Bullet(title: "两个方向都有声音", detail: "对方听得到你，你也听得到对方", size: 26)
                    Bullet(title: "第一次用点一次", detail: "「一键安装」，之后长期有效", size: 26)
                }
                .frame(width: 326, alignment: .leading)
            }
            Spacer(minLength: 22)
            ShotAspect(name: "ring-card", width: 638)
            Spacer(minLength: 0)
            PosterFooter()
        }
    }
}

// MARK: 04 收发短信

struct SmsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(label: "功能二", page: "04 / 10")
            Spacer(minLength: 14)
            Text("收发短信").font(F.cn(52, .bold)).foregroundStyle(P.ink)
            Spacer(minLength: 8)
            Text("短信列表、会话、发送，都在控制面板里。")
                .font(F.cn(26)).foregroundStyle(P.inkSoft)
            Spacer(minLength: 22)
            HStack(alignment: .top, spacing: 24) {
                ShotCard(shot: "panel-sms", width: 300, height: 450, padding: 14)
                VStack(alignment: .leading, spacing: 22) {
                    Bullet(title: "收得到", detail: "验证码、通知短信直接进列表", size: 26)
                    Bullet(title: "发得出", detail: "在面板里直接回，不用换设备", size: 26)
                    Bullet(title: "看得清", detail: "会话按号码分组，翻起来快", size: 26)
                }
                .frame(width: 326, alignment: .leading)
            }
            Spacer(minLength: 22)
            NoteCard(text: "短信走模块里的那张卡，和手机上的短信互不影响。")
            Spacer(minLength: 0)
            PosterFooter()
        }
    }
}

// MARK: 05 4G 上网

struct DataSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(label: "功能三", page: "05 / 10")
            Spacer(minLength: 14)
            Text("4G 上网").font(F.cn(52, .bold)).foregroundStyle(P.ink)
            Spacer(minLength: 8)
            Text("模块当网卡用，面板里能开关、能分流。")
                .font(F.cn(26)).foregroundStyle(P.inkSoft)
            Spacer(minLength: 22)
            HStack(alignment: .top, spacing: 24) {
                ShotCard(shot: "panel-network", width: 300, height: 450, padding: 14)
                VStack(alignment: .leading, spacing: 22) {
                    Bullet(title: "一个开关", detail: "开就上网，关就回 Wi-Fi", size: 26)
                    Bullet(title: "应用路由", detail: "指定 App 走 4G，其余不受影响", size: 26)
                    Bullet(title: "流量有数", detail: "本月用量和实时速率都在面板上", size: 26)
                }
                .frame(width: 326, alignment: .leading)
            }
            Spacer(minLength: 22)
            NoteCard(text: "Wi-Fi 和 4G 可以同时开着，谁走哪条路由你自己定。")
            Spacer(minLength: 0)
            PosterFooter()
        }
    }
}

// MARK: 06 菜单栏与面板

struct MenuSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(label: "在哪里用它", page: "06 / 10")
            Spacer(minLength: 14)
            Text("菜单栏里就有它").font(F.cn(50, .bold)).foregroundStyle(P.ink)
            Spacer(minLength: 10)
            Text("下面这条是这台 Mac 菜单栏的实拍，不是示意图。")
                .font(F.cn(26)).foregroundStyle(P.inkSoft)
            Spacer(minLength: 20)
            MenuBarStrip(width: 638, caption: "框里就是它：信号 + 4G")
            Spacer(minLength: 26)
            HStack(alignment: .top, spacing: 24) {
                ShotCard(shot: "panel-module", width: 300, height: 450, padding: 14)
                VStack(alignment: .leading, spacing: 22) {
                    Bullet(title: "点一下展开", detail: "不用开别的窗口，菜单栏点开就是面板", size: 26)
                    Bullet(title: "状态一眼看清", detail: "信号、注册、运营商、当前网络", size: 26)
                    Bullet(title: "小字收起来", detail: "详细信息放在下拉里，默认只留关键几行", size: 26)
                }
                .frame(width: 326, alignment: .leading)
            }
            Spacer(minLength: 0)
            PosterFooter()
        }
    }
}

// MARK: 07 安装三步

struct InstallSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(label: "怎么装", page: "07 / 10")
            Spacer(minLength: 14)
            Text("装它只要三步").font(F.cn(50, .bold)).foregroundStyle(P.ink)
            Spacer(minLength: 26)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 34) {
                    DetailStep(number: "01", title: "双击安装",
                               detail: "解压后双击「双击安装.command」",
                               titleSize: 34, detailSize: 26)
                    DetailStep(number: "02", title: "插上模块",
                               detail: "插到 Mac 的 USB 口，等灯亮",
                               titleSize: 34, detailSize: 26)
                    DetailStep(number: "03", title: "打开开关",
                               detail: "菜单栏点一下，打开 4G",
                               titleSize: 34, detailSize: 26)
                }
                .frame(width: 330, alignment: .leading)
                // 2026-09-27：设置窗口瘦身之后（一屏只剩功能名 + 按钮），它比
                // 原来矮了近一半，孤零零挂在右栏上会显得这张图没画完。下面补
                // 一句说明它是什么，右栏才立得住。
                VStack(alignment: .leading, spacing: 16) {
                    ShotAspect(name: "window-setup", width: 342)
                    Text("装完打开就是这一屏：\n只有几个按钮，没有要读的说明。")
                        .font(F.cn(24)).foregroundStyle(P.inkSoft)
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 330, alignment: .leading)
                }
            }
            Spacer(minLength: 24)
            NoteCard(text: "要一台 Mac：Apple 芯片（M4 的 MacBook Air 也一样）或 Intel 都行。")
            Spacer(minLength: 0)
            PosterFooter()
        }
    }
}

// MARK: 08 实拍场景

struct SceneSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(label: "实拍", page: "08 / 10")
            Spacer(minLength: 14)
            Text("它本来在无人机上\n现在也服务你的 Mac").font(F.cn(44, .bold)).foregroundStyle(P.ink)
                .lineSpacing(8)
            Spacer(minLength: 24)
            PhotoTile(name: "real-rc", width: 638, height: 320)
            Spacer(minLength: 16)
            HStack(spacing: 16) {
                VStack(spacing: 10) {
                    PhotoTile(name: "real-drone", width: 311, height: 216)
                    Text("装在遥控器支架上").font(F.cn(23)).foregroundStyle(P.inkSoft)
                }
                VStack(spacing: 10) {
                    PhotoTile(name: "real-tiles", width: 311, height: 216)
                    Text("单独用也一样").font(F.cn(23)).foregroundStyle(P.inkSoft)
                }
            }
            Spacer(minLength: 0)
            PosterFooter()
        }
    }
}

// MARK: 09 参数

/// 速度卡：上行 / 下行。箭头 + 标签 + 大数字 + 一行注。
struct SpeedCard: View {
    var label: String
    var arrow: String
    var value: String
    var note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(arrow).font(F.cn(27, .bold)).foregroundStyle(P.green)
                Text(label).font(F.cn(26, .semibold)).foregroundStyle(P.ink)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(value).font(F.cn(54, .bold)).foregroundStyle(P.ink)
                Text("Mbps").font(F.cn(23, .medium)).foregroundStyle(P.inkFaint)
            }
            Text(note).font(F.cn(22)).foregroundStyle(P.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(P.hair, lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.05), radius: 12, y: 5)
    }
}

/// 参数表一行：左边名目，右边值，下面一条发丝线。
struct SpecRow: View {
    var label: String
    var value: String
    var last = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(label).font(F.cn(23)).foregroundStyle(P.inkFaint)
                    .frame(width: 126, alignment: .leading)
                Text(value).font(F.cn(25, .medium)).foregroundStyle(P.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9)
            if !last {
                Rectangle().fill(P.hair).frame(height: 1)
            }
        }
    }
}

struct SpeedSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(label: "硬指标", page: "09 / 10")
            Spacer(minLength: 14)
            Text("参数").font(F.cn(52, .bold)).foregroundStyle(P.ink)
            Spacer(minLength: 8)
            Text("下面每个数，都是在这台 Mac 上从模块里读出来的。")
                .font(F.cn(26)).foregroundStyle(P.inkSoft)
            Spacer(minLength: 18)
            HStack(alignment: .top, spacing: 18) {
                SpeedCard(label: "上行", arrow: "\u{2191}", value: "11–12",
                          note: "实测平均，短时最高 25")
                SpeedCard(label: "下行", arrow: "\u{2193}", value: "150",
                          note: "LTE Cat 4 的标称上限")
            }
            Spacer(minLength: 18)
            VStack(spacing: 0) {
                SpecRow(label: "模块型号", value: "QDC507 · 大疆一代 4G 模块")
                SpecRow(label: "基带芯片", value: "Quectel EG25-G")
                SpecRow(label: "网络制式", value: "FDD LTE · Cat 4")
                SpecRow(label: "标称速率", value: "上行 50 / 下行 150 Mbps")
                SpecRow(label: "USB", value: "ECM 免驱 · 识别码 2CA3:4006")
                SpecRow(label: "支持系统", value: "macOS · Apple 芯片与 Intel 都有原生版本")
                SpecRow(label: "通话语音", value: "装一次，之后即插即用", last: true)
            }
            Spacer(minLength: 12)
            NoteCard(text: "上行是 9 月 26 日实测的（当时信号 −96 dBm，偏弱）。下行 150 是模块标称上限，实际跑多少看信号和运营商。")
            Spacer(minLength: 0)
            PosterFooter()
        }
    }
}

// MARK: 10 服务承诺

struct PromiseSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(label: "服务承诺", page: "10 / 10")
            Spacer(minLength: 16)
            Text("不改硬件，可以改回").font(F.cn(48, .bold)).foregroundStyle(P.ink)
            Spacer(minLength: 30)
            VStack(spacing: 24) {
                PromiseRow(title: "不用邮寄", detail: "模块在你手上，装完就用")
                PromiseRow(title: "不动硬件", detail: "不拆壳、不焊线，只改它的 USB 工作方式")
                PromiseRow(title: "可以改回", detail: "想给无人机用，随时回到出厂状态")
                PromiseRow(title: "远程协助", detail: "真跑不通，我看诊断输出带你排")
            }
            Spacer(minLength: 22)
            PhotoCard(name: "product-front", width: 638, height: 268,
                      aspect: 924.0 / 416.0, padding: 22)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            PosterFooter()
        }
    }
}
