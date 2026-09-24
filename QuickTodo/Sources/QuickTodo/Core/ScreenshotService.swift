import AppKit
import CoreGraphics
import Foundation

enum ScreenshotError: LocalizedError {
    case cancelled
    case noPermission
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "已取消截图"
        case .noPermission: return "缺少「屏幕录制」权限"
        case .failed(let reason): return reason
        }
    }
}

/// 区域截图。
///
/// 直接调用系统的 `/usr/sbin/screencapture -i`：这样用户拿到的是 macOS 原生的
/// 十字光标选区体验（含窗口高亮、按住空格移动选区、Esc 取消），
/// 比自绘一层遮罩更贴合系统习惯，也避免了维护一套截图覆盖窗口。
enum ScreenshotService {

    /// 是否已获得「屏幕录制」权限。
    /// 注意：这是针对**本 App** 的 TCC 授权，授权后需要重启 App 才生效（macOS 的既定行为）。
    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 触发系统授权弹窗（首次调用会弹，之后只返回当前状态）。
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// 打开系统设置的「屏幕录制」面板，引导用户手动勾选。
    static func openPermissionSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// 拉起系统截图工具，等待用户框选完成。
    ///
    /// - Returns: 截图临时文件 URL。调用方处理完（OCR）后**必须**删除它。
    static func captureRegion() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickTodo", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("shot-\(UUID().uuidString).png")

        let status = try await runScreencapture(to: target)

        // -i 模式被 Esc 取消时不会产生文件，退出码为非 0
        guard status == 0 else { throw ScreenshotError.cancelled }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
              let size = attributes[.size] as? Int, size > 0
        else {
            throw hasPermission ? ScreenshotError.cancelled : ScreenshotError.noPermission
        }
        return target
    }

    /// 用完即删，避免把用户屏幕内容留在磁盘上。
    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func runScreencapture(to target: URL) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i 交互式框选, -x 静音, -o 不投影
        process.arguments = ["-i", "-x", "-o", target.path]

        return try await withCheckedThrowingContinuation { continuation in
            // 只可能 resume 一次：run() 抛错时进程没起来，terminationHandler 不会被调用
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: ScreenshotError.failed("无法启动系统截图工具：\(error.localizedDescription)"))
            }
        }
    }
}
