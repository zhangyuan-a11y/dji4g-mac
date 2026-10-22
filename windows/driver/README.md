# Windows 驱动策略

模块 USB `2CA3:4006`，网络功能出厂就是 RNDIS（Windows 自带 `usb8023.sys`，插上即网卡，
**不需要装驱动**）。只有 **AT 口** 需要驱动，否则程序读不到模块。

## 首选：Quectel 官方签名驱动（免签名、免测试模式）

QDC507 是 Quectel EG25-G 的贴牌，官方驱动可用。装完后设备管理器会出现
`Quectel USB AT Port` / `Quectel USB NMEA Port` 等 COM 口，程序自动找 AT 口。

- 下载：Quectel 官网 `Windows USB Driver`（EG25-G 适用）。
- 安装：以管理员运行其 `Setup.exe`（或 `dpinst.exe`），插模块即识别。
- 这一步由安装包 `installer/DJI4G.iss` 在客户机上代跑（需管理员），客户不需要手动操作。

## 备用：自写 WinUSB INF（仅开发/内测）

`DJI4G_AT_WinUSB.inf` 是把 AT 接口绑到 WinUSB 的模板，让程序用
`Windows.Devices.Usb.UsbDevice` 直接发 AT。

- ⚠️ 自写内核驱动**默认不带微软签名**，客户机 64 位系统会拒绝安装，
  只有「测试签名模式」或买 EV 代码签名证书后才能给客户用。
- 所以**正式交付走 Quectel 官方签名驱动**，本 INF 只用于开发机和内测。
- 用之前先把 `%DeviceName%` / `MI_xx` 改成真机设备管理器里 AT 接口的实际值。
