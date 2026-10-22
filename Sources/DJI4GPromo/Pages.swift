import SwiftUI

// MARK: - 01 / 封面

struct PageCover: View {
    var width: CGFloat = 1200
    var height: CGFloat = 1600
    var heroHeight: CGFloat = 560
    var headlineSize: CGFloat = 86
    var showChips: Bool = true
    var inset: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PosterHeader(index: "01 / 06")
            Spacer(minLength: 26)

            HeroCard(shot: "panel-ringing", height: heroHeight)
                .frame(maxWidth: .infinity)

            Spacer(minLength: 26)
            Eyebrow(text: "full control")
            Spacer().frame(height: 22)

            Headline(lines: ["大疆 4G 模块，", "在 Mac 上真正能用。"], size: headlineSize)
            Spacer().frame(height: 20)
            Text("接打电话 · 收发短信 · 4G 上网，一个菜单栏全搞定。")
                .font(F.cn(31))
                .foregroundStyle(P.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            if showChips {
                Spacer(minLength: 26)
                HStack(spacing: 16) {
                    Chip(label: "CALLS", value: "接打电话")
                    Chip(label: "SMS", value: "收发短信")
                    Chip(label: "DATA", value: "4G 上网")
                    Chip(label: "TRAFFIC", value: "流量统计")
                }
                Spacer(minLength: 20)
                Text("※ 电话能拨、能接、能挂，通话两个方向都有声音（先点一次「一键安装」）；来电有弹窗。")
                    .font(F.cn(22))
                    .foregroundStyle(P.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 22)
            PosterFooter()
        }
        .padding(inset)
        .poster(width, height)
    }
}

// MARK: - 02 / 三件事

struct PageFeatures: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PosterHeader(index: "02 / 06")
            Spacer(minLength: 22)

            Eyebrow(text: "three things")
            Spacer().frame(height: 20)
            Headline(lines: ["一个模块，三件事。"], size: 76)
            Spacer().frame(height: 18)
            Text("不用拆机、不用刷固件，插上就能开始用。")
                .font(F.cn(29)).foregroundStyle(P.inkSoft)

            Spacer(minLength: 24)
            HStack(spacing: 16) {
                ShotTile(shot: "window-call-waiting", box: CGSize(width: 300, height: 300), crop: .top)
                ShotTile(shot: "panel-sms", box: CGSize(width: 300, height: 300), crop: .bottom)
                ShotTile(shot: "panel-network", box: CGSize(width: 300, height: 300), crop: .bottom)
            }

            Spacer(minLength: 6)
            NumberedRow(number: "01", label: "CALLING", title: "接打电话",
                        body_: "来电 Mac 弹窗提醒，接听 / 挂断 / 拒接都能点；用 Mac 的麦克风和扬声器通话。")
            NumberedRow(number: "02", label: "MESSAGING", title: "收发短信",
                        body_: "在 Mac 上直接收验证码，中文长短信自动拼接，未读有角标提醒。")
            NumberedRow(number: "03", label: "INTERNET", title: "4G 上网",
                        body_: "macOS 把模块认成一张网卡，走模块自己的流量，不动手机热点。")

            Spacer(minLength: 14)
            PosterFooter()
        }
        .padding(76)
        .poster(1200, 1600)
    }
}

// MARK: - 03 / 改前改后

struct CompareRow: View {
    var label: String
    var left: String
    var right: String
    /// 出厂状态本来就没有这一项时（比如「还原」），不该画一个叉。
    var marks: Bool = true

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text(label).font(F.dot(23)).tracking(1.4)
                .foregroundStyle(P.inkSoft).frame(width: 132, alignment: .leading)
            HStack(spacing: 10) {
                if marks {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(P.inkFaint)
                }
                Text(left).font(F.cn(25)).foregroundStyle(P.inkFaint).lineLimit(1)
            }
            .frame(width: 372, alignment: .leading)
            HStack(spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(P.green)
                Text(right).font(F.cn(25, .medium)).foregroundStyle(P.ink).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 23)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(P.hair).frame(height: 1) }
    }
}

struct PageCompare: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PosterHeader(index: "03 / 06")
            Spacer(minLength: 22)

            Eyebrow(text: "before / after")
            Spacer().frame(height: 20)
            Headline(lines: ["一块模块，", "改前和改后。"], size: 76)

            Spacer(minLength: 26)
            HStack(alignment: .bottom, spacing: 0) {
                Text("").frame(width: 132, alignment: .leading)
                Text("出厂状态").font(F.cn(23, .semibold)).foregroundStyle(P.inkFaint)
                    .frame(width: 372, alignment: .leading)
                Text("改装后").font(F.cn(23, .semibold)).foregroundStyle(P.greenDeep)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 12)
            Rectangle().fill(P.ink.opacity(0.55)).frame(height: 2)

            CompareRow(label: "USB", left: "只认大疆遥控器", right: "Mac 直接识别成网卡")
            CompareRow(label: "来电", left: "没有提醒", right: "Mac 弹窗 · 可接可挂")
            CompareRow(label: "短信", left: "看不到", right: "收发 · 中文长短信")
            CompareRow(label: "流量", left: "无法查看", right: "实时统计 · 本月用量")
            CompareRow(label: "还原", left: "—", right: "可改回原厂配置", marks: false)

            Spacer(minLength: 24)
            NoteCard(text: "不刷固件、不动硬件，只写配置。电话能拨、能接、能挂，通话两个方向都有声音（先点一次「一键安装」）；来电有弹窗提醒。")

            Spacer(minLength: 18)
            PosterFooter()
        }
        .padding(76)
        .poster(1200, 1600)
    }
}

// MARK: - 04 / 三步

struct StepRow: View {
    var number: String
    var title: String
    var body_: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            Text(number).font(F.dot(64)).foregroundStyle(P.green)
                .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(F.cn(38, .semibold)).foregroundStyle(P.ink)
                Text(body_).font(F.cn(28)).foregroundStyle(P.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail).font(F.dot(22)).tracking(1).foregroundStyle(P.greenDeep)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(P.hair).frame(height: 1) }
    }
}

struct PageSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PosterHeader(index: "04 / 06")
            Spacer(minLength: 22)

            Eyebrow(text: "how it works")
            Spacer().frame(height: 20)
            Headline(lines: ["四步，十分钟。"], size: 76)
            Spacer().frame(height: 18)
            Text("全程远程指导，你自己在家做完，不用寄模块。")
                .font(F.cn(29)).foregroundStyle(P.inkSoft)

            Spacer(minLength: 18)
            StepRow(number: "01", title: "插上模块",
                    body_: "用 USB-C 把一代大疆 4G 模块连到 Mac。",
                    detail: "指示灯亮起 = 模块已上电")
            StepRow(number: "02", title: "打开 DJI 4G 助手",
                    body_: "插上就认出来，不用选型号、不用配置。",
                    detail: "哪里不对当场告诉你，不用自己猜")
            StepRow(number: "03", title: "点「一键启用」",
                    body_: "自动把上网和声音都打开，模块重启约 10 秒。",
                    detail: "设置只做这一次，配置写在模块里")
            StepRow(number: "04", title: "装上通话语音",
                    body_: "点「通话」→「一键安装」，剩下自动做完。",
                    detail: "装一次长期有效 · 模块重启后补做一次")

            Spacer(minLength: 22)
            NoteCard(text: "换电脑、换系统都不用重来 —— 配置存在模块里，插上就是一台完整的 4G 上网卡。")

            Spacer(minLength: 18)
            PosterFooter()
        }
        .padding(76)
        .poster(1200, 1600)
    }
}

// MARK: - 05 / 兼容性

struct CompatRow: View {
    var label: String
    var value: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(F.dot(22)).tracking(1.6).foregroundStyle(P.inkSoft)
            Text(value).font(F.cn(31, .semibold)).foregroundStyle(P.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail).font(F.cn(25)).foregroundStyle(P.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(P.hair, lineWidth: 1)
                )
        )
    }
}

struct PageCompat: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PosterHeader(index: "05 / 06")
            Spacer(minLength: 22)

            Eyebrow(text: "compatibility")
            Spacer().frame(height: 20)
            Headline(lines: ["支持哪些设备？"], size: 76)

            Spacer(minLength: 26)
            HStack(spacing: 16) {
                CompatRow(label: "CHIP", value: "BAIWANG QDC507",
                          detail: "USB 2CA3:4006，基带 Quectel EG25-G")
                CompatRow(label: "MODULE", value: "一代大疆 4G 模块",
                          detail: "含带屏遥控器拆机模块")
            }
            Spacer().frame(height: 16)
            HStack(spacing: 16) {
                CompatRow(label: "HOST", value: "Mac（Intel / Apple 芯片）",
                          detail: "macOS 13 及以上，USB-C 直连")
                CompatRow(label: "ALSO", value: "iPad · Android · Linux",
                          detail: "同样能上网；通话和短信要在 Mac 上用")
            }

            Spacer(minLength: 24)
            NoteCard(text: "不确定手里的是不是一代？拍张模块照片发我，先免费帮你确认，不合适不收费。")

            Spacer(minLength: 18)
            PosterFooter()
        }
        .padding(76)
        .poster(1200, 1600)
    }
}

// MARK: - 06 / 服务承诺

struct ServiceBullet: View {
    var text: String
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(P.green)
            Text(text).font(F.cn(30)).foregroundStyle(P.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 17)
    }
}

struct PageService: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PosterHeader(index: "06 / 06")
            Spacer(minLength: 22)

            Eyebrow(text: "service")
            Spacer().frame(height: 20)
            Headline(lines: ["改一台，", "能一直用下去。"], size: 76)

            Spacer(minLength: 18)
            ServiceBullet(text: "远程指导，自己在家操作，不用寄模块")
            ServiceBullet(text: "一次设置长期生效，换电脑插上就用")
            ServiceBullet(text: "随时可以改回原厂状态，不留痕迹")
            ServiceBullet(text: "附赠流量统计、短信和拨号控制台")

            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 14) {
                Text("先确认，再动手。")
                    .font(F.cn(48, .bold))
                    .foregroundStyle(P.ink)
                Text("拍前把模块照片发我，确认是一代大疆 4G 模块、确实能改，再下单。\n改不了的，我不收这个钱。")
                    .font(F.cn(27))
                    .foregroundStyle(P.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Text("一代模块 · 通用 · 改完可还原")
                    .font(F.dot(21)).tracking(1.2).foregroundStyle(P.greenDeep)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(P.green.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(P.green.opacity(0.35), lineWidth: 1.5)
                    )
            )

            Spacer(minLength: 18)
            PosterFooter()
        }
        .padding(76)
        .poster(1200, 1600)
    }
}
