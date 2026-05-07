import Combine
import Foundation
import ServiceManagement

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var captureIntervalSeconds: Double {
        didSet { UserDefaults.standard.set(captureIntervalSeconds, forKey: Keys.captureInterval) }
    }
    @Published var retentionDays: Int {
        didSet { UserDefaults.standard.set(retentionDays, forKey: Keys.retentionDays) }
    }
    @Published var captureQuality: CaptureQuality {
        didSet { UserDefaults.standard.set(captureQuality.rawValue, forKey: Keys.captureQuality) }
    }
    /// Bundle IDs whose frames are skipped at capture time.
    /// Defaults to the lock screen and screen saver — black/idle frames waste disk.
    @Published var excludedAppBundleIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(excludedAppBundleIDs), forKey: Keys.excludedApps) }
    }
    @Published var aiProvider: AIProvider {
        didSet { UserDefaults.standard.set(aiProvider.rawValue, forKey: Keys.aiProvider) }
    }
    @Published var openAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(openAtLogin, forKey: Keys.openAtLogin)
            applyLoginItem()
        }
    }

    static let builtInExcludedApps: [String] = [
        "com.apple.loginwindow",
        "com.apple.ScreenSaverEngine"
    ]

    private enum Keys {
        static let captureInterval = "captureIntervalSeconds"
        static let retentionDays = "retentionDays"
        static let captureQuality = "captureQuality"
        static let excludedApps = "excludedAppBundleIDs"
        static let aiProvider = "aiProvider"
        static let openAtLogin = "openAtLogin"
    }

    private init() {
        let d = UserDefaults.standard
        self.captureIntervalSeconds = (d.object(forKey: Keys.captureInterval) as? Double) ?? 3.0
        self.retentionDays = (d.object(forKey: Keys.retentionDays) as? Int) ?? 30
        let raw = d.object(forKey: Keys.captureQuality) as? Int ?? CaptureQuality.medium.rawValue
        self.captureQuality = CaptureQuality(rawValue: raw) ?? .medium
        let stored = d.array(forKey: Keys.excludedApps) as? [String] ?? Self.builtInExcludedApps
        self.excludedAppBundleIDs = Set(stored)
        let providerRaw = d.string(forKey: Keys.aiProvider) ?? AIProvider.anthropic.rawValue
        self.aiProvider = AIProvider(rawValue: providerRaw) ?? .anthropic
        // Reflect the actual login-item state from the OS (rather than trusting UserDefaults
        // alone — the user might have removed it in System Settings).
        let savedToggle = (d.object(forKey: Keys.openAtLogin) as? Bool) ?? false
        self.openAtLogin = SMAppService.mainApp.status == .enabled || savedToggle
    }

    private func applyLoginItem() {
        let service = SMAppService.mainApp
        do {
            switch (openAtLogin, service.status) {
            case (true, .notRegistered), (true, .notFound):
                try service.register()
            case (false, .enabled), (false, .requiresApproval):
                try service.unregister()
            default:
                break
            }
        } catch {
            // Log but don't propagate — UI shows the toggle, OS may show a permission prompt.
            Log.app.error("Login item toggle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Read by FrameStore / ScreenRecorder from non-main contexts. UserDefaults is thread-safe.
    static var currentCaptureQuality: CaptureQuality {
        let raw = UserDefaults.standard.object(forKey: Keys.captureQuality) as? Int ?? CaptureQuality.medium.rawValue
        return CaptureQuality(rawValue: raw) ?? .medium
    }

    static var currentExcludedAppBundleIDs: Set<String> {
        let stored = UserDefaults.standard.array(forKey: Keys.excludedApps) as? [String] ?? builtInExcludedApps
        return Set(stored)
    }
}
