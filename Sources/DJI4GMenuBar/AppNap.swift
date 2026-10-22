import Foundation

/// 让 macOS 别把这份 App 当成「没人用的后台程序」掐着。
///
/// 症状：面板偶尔会「卡住 4–5 秒」然后自己恢复，日志里留下
/// 「主线程卡住：N 秒没有响应」这一行 —— 可翻遍代码找不到任何一行能挡住
/// 主线程，因为挡它的不是代码。
///
/// 这个 App 是 `LSUIElement`，平时屏幕上没有窗口、没有声音，在 macOS 眼里
/// 就是个「闲着」的进程，于是被 App Nap 拎出来节流：主线程降优先级、定时器
/// 被合并到十几秒一次、整个进程都能被换出去。表现正是这次的样子 —— 系统日志
/// 里几个秒级的空档（进程一个字都没写进去），随后一次性恢复。
///
/// 修法两条一起上，少一条都可能被别的路径绕过：
///   1. `Info.plist` 里的 `NSAppSleepDisabled`（见 `scripts/make-app.sh` 和
///      `scripts/打包发布.sh`）—— 系统层直接不挑它节流；
///   2. 这里再持一张活动票据 —— 运行时那一半，不依赖装机时 plist 写没写对。
///
/// 票据松手就等于没持，所以存成 static，活到进程结束。
enum AppNap {
    private static var token: NSObjectProtocol?

    static func hold() {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            // `.userInitiatedAllowingIdleSystemSleep`：把 App Nap 关掉，但**不**
            // 拦客户合盖、到点休眠。要的是「别被降优先级」，不是「让客户的笔记本
            // 永远不睡」—— 真睡着了，接口那一路本来就有 `recoverStrandedInterface()`
            // 兜底重新认回来。
            options: [.userInitiatedAllowingIdleSystemSleep,
                      .suddenTerminationDisabled,
                      .automaticTerminationDisabled],
            reason: "持续与 4G 模块通话（来电、短信、数据）")
        AppLog.log("已关闭系统节流（App Nap）")
    }
}
