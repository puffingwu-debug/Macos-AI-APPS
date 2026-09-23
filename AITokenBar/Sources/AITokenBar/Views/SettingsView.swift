import SwiftUI
import ServiceManagement

@MainActor
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var store = UsageStore.shared

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("窗口") {
                Toggle("显示桌面悬浮窗", isOn: $settings.showWidget)
                    .onChange(of: settings.showWidget) { _, _ in
                        WidgetPanelController.shared.applyVisibility()
                    }
                Picker("窗口层级", selection: Binding(
                    get: { settings.level },
                    set: { settings.level = $0 }
                )) {
                    ForEach(WidgetLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .onChange(of: settings.level) { _, _ in
                    WidgetPanelController.shared.applyWindowTraits()
                }
                Toggle("拖到屏幕边缘时自动吸附", isOn: $settings.snapToEdges)
                Text("拖动到屏幕边缘或角落附近会像系统窗口一样吸附对齐，靠近时显示对齐预览。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack {
                    Text("不透明度")
                    Slider(value: $settings.opacity, in: 0.35...1.0)
                    Text(Fmt.percent(settings.opacity * 100))
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                Picker("外观密度", selection: Binding(
                    get: { settings.density },
                    set: { settings.density = $0 }
                )) {
                    ForEach(WidgetDensity.allCases) { density in
                        Text(density.title).tag(density)
                    }
                }
                Text(settings.density.blurb + "（当前宽度 \(Int(settings.density.width)) pt，悬浮窗底部「详情」按钮可快速切换）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle("菜单栏显示百分比", isOn: $settings.showMenuBarText)
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        updateLaunchAtLogin(newValue)
                    }
                if let loginError {
                    Text(loginError)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                }
            }

            Section("数据源") {
                Toggle("ChatGPT / Codex 用量", isOn: $settings.showCodex)
                Text("读取 ~/.codex 下的会话日志，与 ChatGPT 桌面端显示的剩余额度同源。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle("DeepSeek 余额与用量", isOn: $settings.showDeepSeek)
                Text("余额来自 api.deepseek.com/user/balance；token 用量统计自 ~/.dsh 会话日志。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("刷新") {
                HStack {
                    Text("本地日志扫描")
                    Slider(value: $settings.localInterval, in: 1...30, step: 1)
                    Text("\(Int(settings.localInterval)) 秒")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                HStack {
                    Text("余额接口刷新")
                    Slider(value: $settings.networkInterval, in: 30...600, step: 30)
                    Text("\(Int(settings.networkInterval / 60)) 分钟")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                Stepper("历史保留 \(settings.codexRetentionDays) 天", value: $settings.codexRetentionDays, in: 2...30)
                Text("扫描在本机完成，日志文件很大时会在多个刷新周期内逐步补全历史。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("DeepSeek API Key") {
                SecureField("sk-…（留空则自动读取）", text: $settings.deepSeekKeyOverride)
                HStack {
                    Text(store.deepseek.keySource.map { "当前来源：\($0)" } ?? "当前来源：未找到")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("立即刷新") { store.refreshNow() }
                }
                Text("未手动填写时，依次尝试环境变量 DEEPSEEK_API_KEY，以及 ~/.dsh/.credentials.yaml。Key 只保存在本机 UserDefaults 中，不会外发。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("DeepSeek 平台会话 Token（可选）") {
                SecureField("userToken（留空则仅显示余额与本机统计）", text: $settings.deepSeekPlatformToken)
                Text("填写后可显示 dashboard 上的「累计消费金额 / 消费金额 / API 请求次数 / Tokens」。获取方式：浏览器登录 platform.deepseek.com → 开发者工具 → Application → Local Storage → 复制 userToken 的 value。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("注意：这是平台的非官方私有接口，随时可能失效；不填写不影响其余功能，Token 仅保存在本机。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack {
                    if let error = store.deepseek.platformError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warning)
                    } else if store.deepseek.platform != nil {
                        Label("平台数据已连接", systemImage: "checkmark.seal")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.codex)
                    } else {
                        Text("未启用").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("立即刷新") { store.refreshNow() }
                }
            }

            Section("成本估算单价（元 / 百万 tokens）") {
                Picker("价格方案", selection: Binding(
                    get: { settings.pricingPreset },
                    set: { settings.pricingPreset = $0 }
                )) {
                    ForEach(PricingPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                if settings.pricingPreset == .custom {
                    HStack {
                        Text("缓存命中输入")
                        Spacer()
                        TextField("", value: $settings.pricingHit, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("缓存未命中输入")
                        Spacer()
                        TextField("", value: $settings.pricingMiss, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("输出")
                        Spacer()
                        TextField("", value: $settings.pricingOutput, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                } else {
                    LabeledContent("缓存命中输入", value: String(format: "¥%.2f", settings.pricing.cacheHitInput))
                    LabeledContent("缓存未命中输入", value: String(format: "¥%.2f", settings.pricing.cacheMissInput))
                    LabeledContent("输出", value: String(format: "¥%.2f", settings.pricing.output))
                }
                Text("以上为低谷价；高峰时段（周一至周五 09:00–12:00、14:00–18:00）自动按 2 倍计算。当前时段：\(ModelPricing.isPeak() ? "高峰" : "低谷")。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("恢复默认") { settings.resetPricing() }
                    Spacer()
                    Text("预估成本 \(Fmt.money(store.deepseek.estimatedCostToday)) / 今日")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section("关于") {
                LabeledContent("版本", value: "1.0")
                LabeledContent("本地扫描", value: "\(String(format: "%.0f", store.lastScanDuration * 1000)) ms")
                LabeledContent("ChatGPT 数据", value: store.codex.errorText ?? (store.codex.headlineWindow.map { "剩余 " + Fmt.percent($0.remainingPercent) } ?? "等待中"))
                LabeledContent("DeepSeek 数据", value: store.deepseek.errorText ?? "正常")
                Text("所有凭据与统计都停留在本机，本应用不向除 api.deepseek.com 之外的任何服务发起请求。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .onChange(of: settings.localInterval) { _, _ in store.settingsChanged() }
        .onChange(of: settings.networkInterval) { _, _ in store.settingsChanged() }
        .onChange(of: settings.deepSeekKeyOverride) { _, _ in store.refreshNow() }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "设置开机启动失败：\(error.localizedDescription)（请先把 App 移到「应用程序」目录）"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
