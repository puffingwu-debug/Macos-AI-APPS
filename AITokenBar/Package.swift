// swift-tools-version: 6.0
import PackageDescription
import Foundation

// zstd is used to read DSH session logs (~/.dsh/sessions/**/session.v3.jsonl.zstd).
// It is linked statically so the produced .app has no runtime dependency on Homebrew.
let env = ProcessInfo.processInfo.environment
let zstdPrefix = env["ZSTD_PREFIX"] ?? "/opt/homebrew"
let disableZstd = env["TB_NO_ZSTD"] == "1"

var shimCSettings: [CSetting] = [.headerSearchPath("include")]
var shimLinkerSettings: [LinkerSetting] = []
if disableZstd {
    shimCSettings.append(.define("TB_NO_ZSTD"))
} else {
    shimCSettings.append(.unsafeFlags(["-I\(zstdPrefix)/include"]))
    shimLinkerSettings.append(.unsafeFlags(["\(zstdPrefix)/lib/libzstd.a"]))
}

let package = Package(
    name: "AITokenBar",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "CZstdShim",
            path: "Sources/CZstdShim",
            cSettings: shimCSettings,
            linkerSettings: shimLinkerSettings
        ),
        .executableTarget(
            name: "AITokenBar",
            dependencies: ["CZstdShim"],
            path: "Sources/AITokenBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
