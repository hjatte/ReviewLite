import SwiftUI
import AppKit
import Combine

@main
struct ReviewLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings {
            SettingsView().environmentObject(SettingsStore.shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private(set) var recorder: ScreenRecorder?
    private(set) var meetingMonitor: MeetingMonitor?
    private let retention = RetentionScheduler()

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try Database.shared.open()
        } catch {
            Log.storage.error("DB open failed: \(error.localizedDescription, privacy: .public)")
        }

        let interval = SettingsStore.shared.captureIntervalSeconds
        let recorder = ScreenRecorder(frameInterval: interval)
        self.recorder = recorder
        let monitor = MeetingMonitor()
        self.meetingMonitor = monitor
        self.menuBar = MenuBarController(recorder: recorder, meetingMonitor: monitor)

        SettingsStore.shared.$captureIntervalSeconds
            .removeDuplicates()
            .sink { [weak recorder] value in recorder?.updateInterval(value) }
            .store(in: &cancellables)

        retention.start()

        if PermissionsCoordinator.screenRecordingGranted() {
            Task { await recorder.start() }
        } else {
            _ = PermissionsCoordinator.requestScreenRecording()
            // Try again shortly after the user grants it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak recorder] in
                guard PermissionsCoordinator.screenRecordingGranted() else { return }
                Task { await recorder?.start() }
            }
        }

    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await recorder?.stop() }
        return .terminateNow
    }

    private var cancellables: Set<AnyCancellable> = []
}
