import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var store: SettingsStore
    @State private var newExclusionInput: String = ""
    @State private var purgeResult: String?
    @State private var apiKeyInput: String = ""
    @State private var apiKeyStatus: String?

    /// Active hours per week assumed for the disk-usage estimate.
    /// 8 hours/day × 5 days = 40 — a typical work week. Real usage varies.
    private let assumedActiveHoursPerWeek: Double = 40

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: $store.openAtLogin)
                Text("Launch ReviewLite automatically when you log in. You can also manage this in System Settings → General → Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Capture") {
                HStack {
                    Text("Frame interval")
                    Spacer()
                    Stepper(value: $store.captureIntervalSeconds, in: 1...30, step: 1) {
                        Text("\(Int(store.captureIntervalSeconds)) s")
                            .monospacedDigit()
                    }
                    .frame(width: 160)
                }
                Text("How often to capture a screenshot. Lower = more detailed timeline, more disk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Quality") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Capture quality", selection: $store.captureQuality) {
                        ForEach(CaptureQuality.allCases) { q in
                            Text(q.label).tag(q)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    HStack {
                        Text("Output: \(Int(store.captureQuality.maxWidth)) px wide HEIC, q \(String(format: "%.2f", store.captureQuality.imageQuality))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("≈ \(weeklyEstimate)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                    }
                    Text("Estimate assumes ~\(Int(assumedActiveHoursPerWeek)) active hours/week at \(Int(store.captureIntervalSeconds))-second intervals. Real usage usually lands within ±50%.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Excluded apps") {
                ForEach(Array(store.excludedAppBundleIDs).sorted(), id: \.self) { bundleID in
                    HStack {
                        Image(systemName: "nosign").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(displayName(for: bundleID) ?? bundleID)
                                .font(.callout)
                            Text(bundleID)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button {
                            store.excludedAppBundleIDs.remove(bundleID)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 6) {
                    TextField("com.example.app", text: $newExclusionInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .onSubmit { addExclusion() }
                    Button("Add", action: addExclusion)
                        .disabled(trimmedInput.isEmpty)
                    Menu("Pick…") {
                        ForEach(runningAppCandidates(), id: \.bundleID) { app in
                            Button("\(app.name) — \(app.bundleID)") {
                                store.excludedAppBundleIDs.insert(app.bundleID)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 70)
                }

                HStack {
                    Button("Purge existing frames from excluded apps") {
                        purgeExistingFromExcluded()
                    }
                    .disabled(store.excludedAppBundleIDs.isEmpty)
                    if let purgeResult {
                        Text(purgeResult).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Text("Frames captured while one of these apps is frontmost are skipped. Useful for locked-screen captures (loginwindow), screen savers, password managers, etc.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Retention") {
                HStack {
                    Text("Keep history for")
                    Spacer()
                    Stepper(value: $store.retentionDays, in: 1...365, step: 1) {
                        Text("\(store.retentionDays) days")
                            .monospacedDigit()
                    }
                    .frame(width: 160)
                }
                Text("Frames and meetings older than this are automatically deleted (sweep runs at launch and every 6 hours).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI meeting summaries (optional)") {
                Picker("Provider", selection: $store.aiProvider) {
                    ForEach(AIProvider.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 8) {
                    SecureField("Paste \(store.aiProvider.displayName) API key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                    Button("Save") { saveAPIKey() }
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    if KeychainStore.has(store.aiProvider.keychainKey) {
                        Button("Remove") {
                            KeychainStore.set(nil, for: store.aiProvider.keychainKey)
                            apiKeyStatus = "Key removed."
                        }
                    }
                }

                HStack(spacing: 6) {
                    if KeychainStore.has(store.aiProvider.keychainKey) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("\(store.aiProvider.displayName) key saved.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "circle").foregroundStyle(.tertiary)
                        Text("No \(store.aiProvider.displayName) key set.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let status = apiKeyStatus {
                        Spacer()
                        Text(status).font(.caption).foregroundStyle(.green)
                    }
                }

                Text("Default model: \(store.aiProvider.defaultModel). When you click \"Generate minutes\" on a meeting, the transcript is sent to \(store.aiProvider.displayName) over HTTPS to produce structured minutes (Summary, Key Points, Decisions, Action Items, Open Questions). API charges are billed to your account by the provider. Audio is never sent — only the transcript text. The key is stored in the app's sandboxed preferences (only readable by ReviewLite, never by other apps).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Permissions") {
                HStack {
                    Text("Screen Recording")
                    Spacer()
                    Text(PermissionsCoordinator.screenRecordingGranted() ? "Granted" : "Not granted")
                        .foregroundStyle(PermissionsCoordinator.screenRecordingGranted() ? .green : .red)
                    Button("Open…") { PermissionsCoordinator.openScreenRecordingSettings() }
                }
                HStack {
                    Text("Microphone")
                    Spacer()
                    Button("Open…") { PermissionsCoordinator.openMicrophoneSettings() }
                }
                Text("ReviewLite needs Screen Recording for screenshots and system audio, and Microphone for your voice during meetings. Both are granted in System Settings → Privacy & Security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 520, minHeight: 460)
    }

    private var weeklyEstimate: String {
        let secondsPerWeek = assumedActiveHoursPerWeek * 3600
        let framesPerWeek = secondsPerWeek / max(1, store.captureIntervalSeconds)
        let kbPerWeek = framesPerWeek * store.captureQuality.estimatedKBPerFrame
        return formatBytes(kilobytes: kbPerWeek)
    }

    private func saveAPIKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if KeychainStore.set(trimmed, for: store.aiProvider.keychainKey) {
            apiKeyStatus = "Saved."
            apiKeyInput = ""
        } else {
            apiKeyStatus = "Save failed (check Keychain access)."
        }
    }

    private var trimmedInput: String {
        newExclusionInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addExclusion() {
        let id = trimmedInput
        guard !id.isEmpty else { return }
        store.excludedAppBundleIDs.insert(id)
        newExclusionInput = ""
    }

    private func purgeExistingFromExcluded() {
        let bundles = store.excludedAppBundleIDs
        Task.detached(priority: .userInitiated) {
            let removed = Database.shared.purgeFrames(matchingBundleIDs: bundles)
            await MainActor.run {
                purgeResult = removed == 0 ? "Nothing to purge." : "Removed \(removed) frame\(removed == 1 ? "" : "s")."
            }
        }
    }

    private func displayName(for bundleID: String) -> String? {
        if bundleID == "com.apple.loginwindow" { return "Login Window" }
        if bundleID == "com.apple.ScreenSaverEngine" { return "Screen Saver" }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
    }

    private struct AppEntry { let name: String; let bundleID: String }

    private func runningAppCandidates() -> [AppEntry] {
        let already = store.excludedAppBundleIDs
        return NSWorkspace.shared.runningApplications.compactMap { app -> AppEntry? in
            guard let bid = app.bundleIdentifier, !already.contains(bid),
                  app.activationPolicy != .prohibited else { return nil }
            return AppEntry(name: app.localizedName ?? bid, bundleID: bid)
        }
        .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func formatBytes(kilobytes: Double) -> String {
        let mb = kilobytes / 1024
        if mb >= 1024 {
            return String(format: "%.1f GB / week", mb / 1024)
        }
        return String(format: "%.0f MB / week", mb)
    }
}
