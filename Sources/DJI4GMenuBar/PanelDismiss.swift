import SwiftUI
import AppKit

/// 菜单栏下拉的收尾。
///
/// 这个文件原来住着两个东西：`PanelDots`（面板左上角那三颗自己画的红黄绿点，
/// 用来补下拉没有标题栏的缺）和一个帮面板窗口关门的 `AppWindow`。
///
/// 2026-09-29 客户在截图上一眼看出那三颗「细节不太对」：「你不要用你生成的，
/// 你要调用系统默认的这个窗口设计」。他说得对 —— 下拉是系统给的浮层，装不上
/// 真的交通灯，画得再像也是假的；能改的是**点开的是什么**。现在点一下菜单栏
/// 图标直接开那扇真窗口（`WindowID.panel`）：标题栏、三颗交通灯、拖动、关闭
/// 全是系统给的，一颗都不用自己画，`AppWindow` 也就跟着撤了。
///
/// 这里只剩一件小事：开窗之前，先把系统那扇下拉收回去。

/// 把菜单栏下拉收回去。
///
/// `MenuBarExtra` 没有官方的「关掉我自己」API —— SDK 里翻了，只有一个
/// `menuBarExtraStyle`，`@Environment(\.dismiss)` 对这个场景也不生效。能按的
/// 只剩它自己那扇窗：下拉是系统给的，窗口层级不是 `.normal`，宽度却是整个
/// 面板那么宽。这两条加在一起就是它，菜单栏图标自己那扇只有二十几个点宽，
/// 量不到 100，所以不会被误收 —— 把图标收没了就是事故。
///
/// 两条路都留着：先按层级找，一层都没命中的时候再看一眼当前 key。系统在不同
/// 版本上换过这扇窗的类名，认层级比认类名稳。
@MainActor
enum PanelDismiss {
    /// 这扇窗是不是「该被收掉的那一扇」（点菜单栏图标时要收的那扇下拉）。
    ///
    /// 判据是浮层 + 够宽，**外加**一条躲开：来电卡片同样是浮层、同样比 100 点
    /// 宽，铃声正响的时候把它一起收掉，客户面前的电话就无声无息地没了。名字
    /// 由 `RingAlert.windowIdentifier` 挂上（见那里）。
    static func isDismissable(_ window: NSWindow) -> Bool {
        guard window.isVisible, window.level != .normal, window.frame.width > 100
        else { return false }
        return window.identifier?.rawValue != RingAlert.windowIdentifier
    }

    /// 把菜单栏下拉收回去。
    ///
    /// 收的动作分两步，缺一不可：
    ///
    /// 一，请系统那颗按钮按一下 —— 让系统**自己**收。客户 2026-09-29 报的
    /// 「点完拨打，主页面缩回（再点图标要点两次才开）」就是只做了第二步：
    /// 我们按住窗口 `orderOut` 把下拉藏了，可 `MenuBarExtra` 内部那本
    /// 「现在开着」的账没跟着翻 —— 下一次点图标，系统按「开着」处理，
    /// 先把账翻回「关着」（第一下，看着没反应），再点才是真开（第二下）。
    /// 按它自己的按钮，窗口和账一起收：这一下点完，下一次点图标一次就开。
    ///
    /// 二，兜底 —— 万一哪个系统版本不吃这一按（按钮没拿到、动作没接上），
    /// 等一拍再看：窗口还挂在那儿就自己收。正常路径上这一步是空的。
    ///
    /// 没开着的下拉不碰：上面那按是**开关**，对着已经收好的下拉按下去，
    /// 反而会把下拉弹出来。
    static func menuBarExtra() {
        let targets = dismissableWindows()
        guard !targets.isEmpty else { return }

        if let button = statusBarButton() {
            button.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                for window in targets where window.isVisible { window.orderOut(nil) }
            }
            return
        }
        for window in targets { window.orderOut(nil) }
    }

    private static func dismissableWindows() -> [NSWindow] {
        let overlaid = NSApp.windows.filter(isDismissable)
        if !overlaid.isEmpty { return overlaid }
        if let key = NSApp.keyWindow, isDismissable(key) { return [key] }
        return []
    }

    /// 菜单栏那一格的按钮。
    ///
    /// 菜单栏项那扇窗挂在层 25（系统菜单栏那一层），宽只有二十几个点；下拉
    /// 是整块面板那么宽，够不着这个数 —— 两个条件一叠就是图标那一格。不认
    /// 类名：系统在不同版本上换过它的类名。
    private static func statusBarButton() -> NSButton? {
        for window in NSApp.windows {
            guard window.isVisible, window.level.rawValue == 25, window.frame.width < 100
            else { continue }
            if let found = firstButton(in: window.contentView) { return found }
        }
        return nil
    }

    private static func firstButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        for sub in view.subviews {
            if let found = firstButton(in: sub) { return found }
        }
        return nil
    }
}
