import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Mac 端「微信扫码授权登录」（契约 §4）。
///
/// 流程：Mac 生成 ticket → 画成二维码 → 小程序扫这个码 → 云函数把 openid 绑到 ticket
/// → Mac 轮询拿到 session token → 存 Keychain。
/// Mac 端全程不接触 AppSecret，也不需要微信开放平台账号。
@MainActor
final class LoginService: ObservableObject {

    enum Phase: Equatable {
        case idle
        case creating
        case waiting(ticket: String, expireAt: Int64)
        case failed(String)

        var isWaiting: Bool {
            if case .waiting = self { return true }
            return false
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var qrImage: NSImage?
    /// 剩余有效秒数，UI 倒计时用。
    @Published private(set) var secondsLeft: Int = 0

    private let api: QuickTodoAPI
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    /// 登录成功后回调：参数是 session token。
    var onSuccess: ((String, String) -> Void)?

    init(api: QuickTodoAPI) {
        self.api = api
    }

    deinit {
        pollTask?.cancel()
        tickTask?.cancel()
    }

    /// 开始一次扫码登录。
    func begin(baseURL: String, deviceName: String = Host.current().localizedName ?? "Mac") {
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .failed("请先填写云环境地址")
            return
        }
        cancel()
        phase = .creating
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let ticket = try await self.api.createLoginTicket(baseURL: baseURL, deviceName: deviceName)
                guard let value = ticket.ticket else {
                    self.phase = .failed("云端未返回 ticket")
                    return
                }
                self.qrImage = Self.makeQRCode(from: ticket.qrPayload ?? "quicktodo://login?ticket=\(value)")
                self.phase = .waiting(ticket: value, expireAt: ticket.expireAt ?? (Date.currentMillis + 300_000))
                self.startCountdown(expireAt: ticket.expireAt ?? (Date.currentMillis + 300_000))
                await self.poll(baseURL: baseURL, ticket: value)
            } catch {
                self.phase = .failed(Self.describe(error))
            }
        }
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        tickTask?.cancel()
        tickTask = nil
        qrImage = nil
        secondsLeft = 0
        if case .failed = phase { return }
        phase = .idle
    }

    // MARK: - 轮询

    private func poll(baseURL: String, ticket: String) async {
        // 5 分钟有效期，1.5s 一次轮询
        let deadline = Date().addingTimeInterval(300)
        while !Task.isCancelled && Date() < deadline {
            do {
                let result = try await api.pollLoginTicket(baseURL: baseURL, ticket: ticket)
                switch result.status {
                case "confirmed":
                    if let token = result.token, !token.isEmpty {
                        KeychainStore.saveToken(token)
                        phase = .idle
                        qrImage = nil
                        tickTask?.cancel()
                        onSuccess?(token, result.openid ?? "")
                        return
                    }
                case "expired":
                    phase = .failed("二维码已过期，请重新生成")
                    qrImage = nil
                    return
                default:
                    break
                }
            } catch let error as CloudError {
                // 单次网络抖动不打断轮询，只有明确的业务错误才终止
                if error.code != "network" && error.code != "http_502" && error.code != "http_503" {
                    phase = .failed(error.message)
                    return
                }
            } catch {
                // 忽略瞬时错误，继续轮询
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        if !Task.isCancelled, phase.isWaiting {
            phase = .failed("二维码已过期，请重新生成")
            qrImage = nil
        }
    }

    private func startCountdown(expireAt: Int64) {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let left = Int((expireAt - Date.currentMillis) / 1000)
                self.secondsLeft = max(0, left)
                if left <= 0 { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - 二维码绘制

    /// 用系统 CoreImage 生成二维码（无第三方依赖）。
    static func makeQRCode(from text: String, size: CGFloat = 190) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    private static func describe(_ error: Error) -> String {
        if let cloud = error as? CloudError { return cloud.message }
        return error.localizedDescription
    }
}
