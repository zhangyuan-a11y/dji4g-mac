# DJI 4G 一代模块 · Windows 版（Win10 / Win11 / Win12）

给大疆一代 4G 模块（BAIWANG QDC507，基带 Quectel EG25-G，USB `2CA3:4006`）
用的 **Windows 托盘程序**。功能目标与 macOS 版一致：

| 功能 | Windows 靠什么实现 | 说明 |
| --- | --- | --- |
| 收发短信 | 纯 AT 命令（走 COM 口） | 与 Mac 版同一套逻辑，直接移植 |
| 电话（拨号/接听/挂断/来电提醒） | 纯 AT 命令 | 同上 |
| 通话记录 | AT 命令 + 程序自存 | 同上 |
| 通话声音（双向） | USB 音频 + Windows 声卡路由 | ⚠️ 最高风险项，必须先真机验证 |
| 上网 | RNDIS 网卡（Windows 原生驱动） | 出厂 `usbnet=0` 即 RNDIS，插上就认 |
| 开机自启 / 图标 / 通知 | 注册表 Run 键 + 托盘 + Toast | Windows 原生 |

## 一个关键认知：这是“第二套程序”，不是重编译

macOS 版里 Swift 能复用的是**纯逻辑**（AT 命令表、短信 PDU 编解码、运营商/APN
表、通话状态机、通话记录模型、模块状态解析）。这些在 Windows 上原样移植。

必须整套重写的只有平台相关部分：

| 部分 | macOS 实现 | Windows 实现 |
| --- | --- | --- |
| USB/AT 通道 | IOKit（`Sources/CUSBAT`） | COM 口（`System.IO.Ports`） |
| 网络服务控制 | `SystemConfiguration` | 无需控制，RNDIS 原生 |
| 通话音频 | CoreAudio + PCM 桥 | USB Audio + WASAPI 路由 |
| 界面 | SwiftUI 菜单栏 | WPF 托盘 + 悬浮窗 |
| 开机自启 | Login Item | 注册表 `HKCU\...\Run` |
| 单实例/通知 | macOS API | Mutex + Toast |

## 技术选型（已定）

- **C# / .NET 8 + WPF**：Windows 原生托盘程序，一个 `Setup.exe` 装完即用，无需登录/商店。
- **AT 通道**：优先走模块枚举出的 **COM 口**（Quectel 官方驱动装完后是“Quectel USB AT Port”）。
  驱动优先用 **Quectel 官方 WHQL 签名驱动**（免去自己买证书签名内核驱动），见 `driver/README.md`。
- **联网**：模块出厂 `usbnet=0`（RNDIS），Windows 自带 `usb8023.sys`，插上就是网卡。
  Mac 上切过的 ECM 在 Windows 不认，程序首次运行要把模块切回 RNDIS（`AT+QCFG="usbnet",0`）。
- **声音**：开 `usbcfg` 的 audio 位 → 模块枚举成 USB 声卡 → Windows 自带 `usbaudio2.sys`。
  这一步能不能直接带走通话语音，必须拿真机在 Win10 和 Win11 上各验一遍。
- **安装包**：Inno Setup，产出单个 `DJI4G-Setup.exe`，含程序 + 驱动引导 + 开机自启 + 图标。

## UI 适配原则（按 Windows 系统，不照搬 Mac）

- **系统原生标题栏**：右上角最小化 / 最大化 / 关闭由 Windows 自带，不自定义假按钮。
- **字体**：全站 `Segoe UI`（Win10/11 默认系统字体），不用 Mac 的 SF / 像素字体。
- **配色**：Win11 明色面板 + 系统蓝 `#005FB8`；Win11 上自动开 Mica 毛玻璃，Win10 回退纯色。
- **交互习惯**：关窗 = 缩回托盘；托盘图标双击打开面板；通知走 Windows Toast；
  窗口可拖动、可缩放，默认居中。
- 信息量克制：面板只放「状态 + 运营商 + 短信/电话/联网 + 刷新」，不做大段文字说明。

## 目录结构

```
windows/
├── README.md                 ← 本文件（架构 + 路线图）
├── DJI4G.Windows/            ← WPF 托盘程序（.NET 8）
│   ├── DJI4G.Windows.csproj
│   ├── App.xaml(.cs)         ← 单实例 + 托盘 + 悬浮窗
│   ├── MainWindow.xaml(.cs)  ← 主面板（骨架）
│   └── Core/
│       ├── AtChannel.cs      ← COM 口 AT 收发
│       ├── Modem.cs          ← 状态/通话/短信会话骨架
│       └── Carriers.cs       ← 运营商/APN 表（已从 Mac 版移植）
├── driver/                   ← 驱动策略（优先 Quectel 官方签名驱动）
└── installer/
    └── DJI4G.iss             ← Inno Setup 脚本（单个 Setup.exe）
```

## 里程碑（按真机风险排序）

1. **M0 · 能通 AT**：装 Quectel 驱动 → 找到 AT COM 口 → 读 IMEI/信号/注册状态。
2. **M1 · 三大件可用**：短信收发、拨号/接听/挂断、来电提醒、通话记录、状态面板。
3. **M2 · 联网**：首次运行切 RNDIS（`usbnet=0`）→ Windows 网卡 + 流量统计。
4. **M3 · 通话声音**：audio 位 + USB 声卡路由，Win10/Win11 真机双向通话验证（最高风险）。
5. **M4 · 安装包**：Inno Setup 出 `DJI4G-Setup.exe`，开机自启、图标、卸载齐全。
6. **M5 · 兼容面**：Win10 / Win11 双测；Win12 发布后补测（.NET 8 会继续支持）。

## 必须有一台 Windows 电脑

本仓库在 macOS 上维护，Windows 程序**必须在 Windows 10/11 真机**上编译、装驱动、
插模块验证（尤其是 M3 声音和 M4 安装包）。macOS 上无法产出/验证 Windows 可执行文件。

在 Windows 上第一次跑：

```powershell
# 装 .NET 8 SDK：https://dotnet.microsoft.com/download/dotnet/8.0
cd windows\DJI4G.Windows
dotnet build -c Release
# 出包：装 Inno Setup 后，用 installer\DJI4G.iss 生成 Setup.exe
```
