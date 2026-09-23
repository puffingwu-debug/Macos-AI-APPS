import Foundation
import SwiftUI

/// User-facing preferences, persisted in `UserDefaults`.
///
/// `UsageStore` reads these on the main actor and hands immutable values to the
/// background scanners, so nothing here needs to be thread safe by itself.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let d = UserDefaults.standard

    private enum Key {
        static let showWidget = "showWidget"
        static let alwaysOnTop = "alwaysOnTop"
        static let opacity = "widgetOpacity"
        static let density = "widgetDensity"
        static let level = "widgetLevel"
        static let snapToEdges = "snapToEdges"
        static let showCodex = "showCodex"
        static let showDeepSeek = "showDeepSeek"
        static let showMenuBarText = "showMenuBarText"
        static let networkInterval = "networkInterval"
        static let localInterval = "localInterval"
        static let deepSeekKey = "deepSeekAPIKey"
        static let deepSeekPlatformToken = "deepSeekPlatformToken"
        static let pricingPreset = "pricing.preset"
        static let pricingHit = "pricing.cacheHit"
        static let pricingMiss = "pricing.cacheMiss"
        static let pricingOutput = "pricing.output"
        static let codexRetentionDays = "codexRetentionDays"
        static let liveCodexEnabled = "liveCodexEnabled"
    }

    private init() {
        d.register(defaults: [
            Key.showWidget: true,
            Key.alwaysOnTop: true,
            Key.opacity: 0.92,
            Key.density: WidgetDensity.compact.rawValue,
            Key.level: WidgetLevel.floating.rawValue,
            Key.snapToEdges: true,
            Key.showCodex: true,
            Key.showDeepSeek: true,
            Key.showMenuBarText: true,
            Key.networkInterval: 60.0,
            Key.localInterval: 3.0,
            Key.deepSeekKey: "",
            Key.deepSeekPlatformToken: "",
            Key.pricingPreset: PricingPreset.flash.rawValue,
            Key.pricingHit: ModelPricing.flash.cacheHitInput,
            Key.pricingMiss: ModelPricing.flash.cacheMissInput,
            Key.pricingOutput: ModelPricing.flash.output,
            Key.codexRetentionDays: 8,
            Key.liveCodexEnabled: true,
        ])
    }

    @Published var showWidget: Bool = AppSettings.bool(Key.showWidget, true) { didSet { d.set(showWidget, forKey: Key.showWidget) } }
    @Published var alwaysOnTop: Bool = AppSettings.bool(Key.alwaysOnTop, true) { didSet { d.set(alwaysOnTop, forKey: Key.alwaysOnTop) } }
    @Published var opacity: Double = AppSettings.double(Key.opacity, 0.92) { didSet { d.set(opacity, forKey: Key.opacity) } }
    @Published var densityRaw: String = AppSettings.string(Key.density, WidgetDensity.compact.rawValue) {
        didSet { d.set(densityRaw, forKey: Key.density) }
    }
    @Published var levelRaw: String = AppSettings.string(Key.level, WidgetLevel.floating.rawValue) {
        didSet { d.set(levelRaw, forKey: Key.level) }
    }
    @Published var snapToEdges: Bool = AppSettings.bool(Key.snapToEdges, true) {
        didSet { d.set(snapToEdges, forKey: Key.snapToEdges) }
    }

    var density: WidgetDensity {
        get { WidgetDensity(rawValue: densityRaw) ?? .compact }
        set { densityRaw = newValue.rawValue }
    }

    var level: WidgetLevel {
        get { WidgetLevel(rawValue: levelRaw) ?? .floating }
        set { levelRaw = newValue.rawValue }
    }

    /// Cycles 迷你 → 精简 → 完整 → 迷你, used by the widget's own footer button.
    func cycleDensity() {
        switch density {
        case .mini: density = .compact
        case .compact: density = .full
        case .full: density = .mini
        }
    }

    func cycleLevel() {
        switch level {
        case .desktop: level = .floating
        case .floating: level = .normal
        case .normal: level = .desktop
        }
    }
    @Published var showCodex: Bool = AppSettings.bool(Key.showCodex, true) { didSet { d.set(showCodex, forKey: Key.showCodex) } }
    @Published var showDeepSeek: Bool = AppSettings.bool(Key.showDeepSeek, true) { didSet { d.set(showDeepSeek, forKey: Key.showDeepSeek) } }
    @Published var showMenuBarText: Bool = AppSettings.bool(Key.showMenuBarText, true) { didSet { d.set(showMenuBarText, forKey: Key.showMenuBarText) } }
    @Published var networkInterval: Double = AppSettings.double(Key.networkInterval, 60) { didSet { d.set(networkInterval, forKey: Key.networkInterval) } }
    @Published var localInterval: Double = AppSettings.double(Key.localInterval, 3) { didSet { d.set(localInterval, forKey: Key.localInterval) } }
    @Published var deepSeekKeyOverride: String = AppSettings.string(Key.deepSeekKey, "") { didSet { d.set(deepSeekKeyOverride, forKey: Key.deepSeekKey) } }
    /// Optional `userToken` from platform.deepseek.com — unlocks the dashboard's
    /// cumulative spend / request counts, which the official API does not expose.
    @Published var deepSeekPlatformToken: String = AppSettings.string(Key.deepSeekPlatformToken, "") { didSet { d.set(deepSeekPlatformToken, forKey: Key.deepSeekPlatformToken) } }
    @Published var liveCodexEnabled: Bool = AppSettings.bool(Key.liveCodexEnabled, true) { didSet { d.set(liveCodexEnabled, forKey: Key.liveCodexEnabled) } }
    @Published var codexRetentionDays: Int = AppSettings.int(Key.codexRetentionDays, 8) { didSet { d.set(codexRetentionDays, forKey: Key.codexRetentionDays) } }

    @Published var pricingPresetRaw: String = AppSettings.string(Key.pricingPreset, PricingPreset.flash.rawValue) {
        didSet { d.set(pricingPresetRaw, forKey: Key.pricingPreset) }
    }
    @Published var pricingHit: Double = AppSettings.double(Key.pricingHit, ModelPricing.flash.cacheHitInput) { didSet { d.set(pricingHit, forKey: Key.pricingHit) } }
    @Published var pricingMiss: Double = AppSettings.double(Key.pricingMiss, ModelPricing.flash.cacheMissInput) { didSet { d.set(pricingMiss, forKey: Key.pricingMiss) } }
    @Published var pricingOutput: Double = AppSettings.double(Key.pricingOutput, ModelPricing.flash.output) { didSet { d.set(pricingOutput, forKey: Key.pricingOutput) } }

    var pricingPreset: PricingPreset {
        get { PricingPreset(rawValue: pricingPresetRaw) ?? .flash }
        set { pricingPresetRaw = newValue.rawValue }
    }

    /// Preset prices when one is selected, otherwise the user's custom numbers.
    var pricing: ModelPricing {
        if let preset = pricingPreset.pricing { return preset }
        return ModelPricing(cacheHitInput: pricingHit, cacheMissInput: pricingMiss, output: pricingOutput)
    }

    func resetPricing() {
        pricingPreset = .flash
        pricingHit = ModelPricing.flash.cacheHitInput
        pricingMiss = ModelPricing.flash.cacheMissInput
        pricingOutput = ModelPricing.flash.output
    }

    // MARK: - Defaults helpers

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    private static func double(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }

    private static func int(_ key: String, _ fallback: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? fallback
    }

    private static func string(_ key: String, _ fallback: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? fallback
    }
}
