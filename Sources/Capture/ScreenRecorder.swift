import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit
import Combine

@MainActor
final class ScreenRecorder: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastCaptureAt: Date?

    private let store = FrameStore()
    private let windowTracker = WindowTracker()

    /// Cached list of available `SCDisplay`s. Refreshed periodically and on screen changes
    /// so we always know which display the user's active window is on.
    private var displays: [SCDisplay] = []
    private var lastDisplayRefresh: Date = .distantPast
    private var screenChangeObserver: NSObjectProtocol?

    private var contentFilter: SCContentFilter?
    private var streamConfig: SCStreamConfiguration?
    private var lastDisplayID: CGDirectDisplayID?

    private var timer: Timer?
    private var capturing = false
    private(set) var frameInterval: TimeInterval

    /// Source resolution given to ScreenCaptureKit. Stays at 2400 px wide so the High/Max
    /// quality presets in FrameStore aren't capped by source.
    private let sourceWidth = 2400

    init(frameInterval: TimeInterval) {
        self.frameInterval = frameInterval
    }

    func updateInterval(_ seconds: TimeInterval) {
        frameInterval = max(1, seconds)
        if isRunning {
            scheduleTimer()
        }
    }

    func start() async {
        guard !isRunning else { return }
        await refreshDisplays(force: true)
        guard !displays.isEmpty else {
            self.lastError = "No display available"
            return
        }
        self.isRunning = true
        self.lastError = nil
        installScreenChangeObserver()
        scheduleTimer()
        await captureOnce()
    }

    func stop() async {
        timer?.invalidate()
        timer = nil
        isRunning = false
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
        screenChangeObserver = nil
    }

    func toggle() async {
        if isRunning { await stop() } else { await start() }
    }

    private func installScreenChangeObserver() {
        guard screenChangeObserver == nil else { return }
        // Re-fetch the display list when the user plugs/unplugs a monitor or rearranges them.
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshDisplays(force: true) }
        }
    }

    private func refreshDisplays(force: Bool) async {
        if !force && Date().timeIntervalSince(lastDisplayRefresh) < 30 { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            self.displays = content.displays
            self.lastDisplayRefresh = Date()
        } catch {
            // Keep whatever we had; non-fatal.
            self.lastError = error.localizedDescription
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: frameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.captureOnce() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Picks the `SCDisplay` that contains the user's active context — first preference is the
    /// frontmost window's centre, fallback is the screen with the mouse pointer, fallback is
    /// the primary display. This means on a multi-monitor setup we capture whichever screen
    /// the user is actively working on, not just the laptop's built-in display.
    private func activeDisplay() -> SCDisplay? {
        guard !displays.isEmpty else { return nil }

        // 1. Frontmost window's centre.
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
           let windowDict = info.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }),
           let bounds = windowDict[kCGWindowBounds as String] as? [String: CGFloat] {
            let rect = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            let center = CGPoint(x: rect.midX, y: rect.midY)
            for d in displays {
                if CGDisplayBounds(d.displayID).contains(center) { return d }
            }
        }

        // 2. Mouse pointer's screen.
        let mouseLoc = NSEvent.mouseLocation     // AppKit coords (Y goes up from bottom-left).
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLoc) }),
           let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           let match = displays.first(where: { $0.displayID == displayID }) {
            return match
        }

        // 3. Fallback — the first display.
        return displays.first
    }

    private func reconfigureFilter(for display: SCDisplay) {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = streamConfig ?? SCStreamConfiguration()
        let ratio = Double(display.height) / Double(max(1, display.width))
        config.width = sourceWidth
        config.height = max(720, Int(Double(sourceWidth) * ratio))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = true
        config.showsCursor = true
        config.queueDepth = 3
        config.minimumFrameInterval = CMTime(seconds: frameInterval, preferredTimescale: 600)
        self.contentFilter = filter
        self.streamConfig = config
        self.lastDisplayID = display.displayID
    }

    private func captureOnce() async {
        guard isRunning, !capturing else { return }
        capturing = true
        defer { capturing = false }

        await refreshDisplays(force: false)
        guard let display = activeDisplay() else { return }
        if display.displayID != lastDisplayID || contentFilter == nil {
            reconfigureFilter(for: display)
        }

        guard let filter = contentFilter, let config = streamConfig else { return }
        do {
            // Skip if the frontmost app is in the excluded list — avoids capturing the
            // login window all night, screen-saver frames, etc.
            let snapshot = windowTracker.snapshot()
            if let bundle = snapshot.bundleID,
               SettingsStore.currentExcludedAppBundleIDs.contains(bundle) {
                return
            }
            let buffer = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config)
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }
            let now = Date()
            let win = snapshot
            let result = try await store.append(pixelBuffer: pixelBuffer, capturedAt: now)
            let frameID = try Database.shared.insertFrame(
                capturedAt: now,
                imagePath: result.relativePath,
                appBundleID: win.bundleID,
                windowTitle: win.title
            )
            self.lastCaptureAt = now

            let imageURL = Database.shared.framesDirectory.appendingPathComponent(result.relativePath)
            Task.detached(priority: .background) {
                await OCRProcessor.shared.process(frameID: frameID, imageURL: imageURL)
            }
        } catch {
            self.lastError = error.localizedDescription
        }
    }
}
