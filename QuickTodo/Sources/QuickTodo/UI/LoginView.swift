import SwiftUI

/// 微信扫码登录：把 `quicktodo://login?ticket=...` 画成二维码，
/// 用手机小程序「我的 → 扫码登录 Mac」扫一下即可完成授权。
struct LoginView: View {

    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("微信扫码登录")
                .font(.system(size: 13, weight: .semibold))
            Text("打开小程序「闪记待办」→ 我的 → 扫码登录 Mac")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 214, height: 214)

                switch state.login.phase {
                case .idle:
                    VStack(spacing: 8) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.secondary)
                        Button("生成二维码") { state.startLogin() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.accent)
                    }
                case .creating:
                    ProgressView().controlSize(.small)
                case .waiting:
                    if let image = state.login.qrImage {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 190, height: 190)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                case .failed(let message):
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Palette.warning)
                        Text(message)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                        Button("重试") { state.startLogin() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.accent)
                    }
                }
            }

            if state.login.phase.isWaiting {
                Text("二维码 \(state.login.secondsLeft) 秒后过期 · 等待手机确认…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if state.isLoggedIn {
                Label("已登录", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.accent)
            }

            HStack(spacing: 10) {
                if state.login.phase.isWaiting {
                    Button("刷新二维码") { state.startLogin() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if state.isLoggedIn {
                    Button("退出登录") { state.logout() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.high)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.accent)
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(width: 290)
        .onAppear {
            if !state.isLoggedIn, !state.login.phase.isWaiting {
                state.startLogin()
            }
        }
        .onDisappear {
            state.login.cancel()
        }
    }
}
