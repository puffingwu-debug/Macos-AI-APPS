// swift-tools-version: 6.0
import PackageDescription

// QuickTodo — macOS 桌面悬浮待办客户端。
//
// 纯 SwiftPM 工程，不需要 Xcode 工程文件：`swift build` 即可编译，
// `./build.sh` 负责打包 .app（含 Info.plist 与 ad-hoc 签名）。
//
// 依赖为零：截图用系统 /usr/sbin/screencapture，OCR 用系统 Vision 框架，
// AI 解析走微信云开发的云函数（密钥不落客户端）。
let package = Package(
    name: "QuickTodo",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "QuickTodo",
            path: "Sources/QuickTodo",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
