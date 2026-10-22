; Inno Setup 脚本：产出单个 DJI4G-Setup.exe
; 前置：先 publish 自包含版本（见 windows/README.md），再把 Quectel 官方驱动放到
;       driver\vendor\ 下，并把下面 #define QuectelDriver 改成实际文件名。

#define MyAppName "DJI 4G"
#define MyAppVersion "1.0.0"
#define MyAppExeName "DJI4G.exe"
; 客户无需装 .NET：自包含发布
#define PublishDir "..\DJI4G.Windows\bin\Release\net8.0-windows10.0.19041.0\win-x64\publish\"
; 官方驱动安装包（正式交付必填，放在 windows\driver\vendor\ 下）
#define QuectelDriver ""

[Setup]
AppId={{B1D2E3F4-4A5B-4C6D-8E9F-0A1B2C3D4E5F}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={autopf}\DJI4G
DefaultGroupName=DJI 4G
OutputDir=..\..\outputs\dji4g-windows
OutputBaseFilename=DJI4G-Setup
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=admin
DisableProgramGroupPage=yes

[Files]
Source: "{#PublishDir}*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
#if QuectelDriver != ""
Source: "..\driver\vendor\{#QuectelDriver}"; DestDir: "{tmp}"; Flags: deleteafterinstall
#endif

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "其他选项:"

[Registry]
; 开机自启（当前用户，无需管理员常驻）
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
    ValueType: string; ValueName: "DJI4G"; ValueData: """{app}\{#MyAppExeName}"""; \
    Flags: uninsdeletevalue

[Run]
; 装 AT 口驱动（官方签名驱动，静默安装）
#if QuectelDriver != ""
Filename: "{tmp}\{#QuectelDriver}"; Parameters: "/S"; \
    StatusMsg: "正在安装模块驱动…"; Flags: runhidden waituntilterminated
#endif
Filename: "{app}\{#MyAppExeName}"; Description: "启动 DJI 4G"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
