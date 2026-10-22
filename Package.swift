// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DJI4G",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CUSBAT",
            path: "Sources/CUSBAT",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .target(
            name: "CMacNet",
            path: "Sources/CMacNet",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .target(
            name: "DJI4GCore",
            dependencies: ["CUSBAT", "CMacNet"],
            path: "Sources/DJI4GCore",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .executableTarget(
            name: "dji4gctl",
            dependencies: ["DJI4GCore"],
            path: "Sources/dji4gctl"
        ),
        .executableTarget(
            name: "DJI4GPromo",
            dependencies: ["DJI4GCore"],
            path: "Sources/DJI4GPromo",
            resources: [.copy("Resources/doto.ttf")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "DJI4GMenuBar",
            dependencies: ["DJI4GCore"],
            path: "Sources/DJI4GMenuBar",
            resources: [.copy("Resources/doto.ttf")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                // 麦克风授权（`MicPermission`）读的就是它。缺了这个链接，
                // `AVCaptureDevice` 在运行期才会报找不到符号 —— 而那正是
                // 「装完第一次打开」这一刻，客户第一条电话之前。
                .linkedFramework("AVFoundation"),
                .linkedFramework("Network"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications")
            ]
        )
    ]
)
