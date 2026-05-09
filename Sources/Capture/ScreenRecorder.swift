import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage
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

    // MARK: - Adaptive capture state
    //
    // Idea: when the screen looks identical to the last capture for several frames in a row,
    // back off the capture rate (skip HEIC encode + DB insert + OCR spawn entirely) until
    // something changes. When change resumes, snap back to the user's chosen interval.
    //
    // The hash is computed on the raw pixel buffer BEFORE the HEIC step, so an idle screen
    // costs us roughly: one ScreenCaptureKit shot + one 8×8 CIContext render + one UInt64
    // compare. Negligible.
    private var lastFrameHash: UInt64?
    private var idleStreak: Int = 0

    /// After this many consecutive near-identical frames, switch to slow polling.
    private static let idleThreshold = 5

    /// How many bits of the 64-bit perceptual hash may differ before two frames are
    /// considered "different". A bit-for-bit match was too strict — a single moving
    /// cursor or a ticking clock would flip a couple of bits in the 8×8 hash and
    /// cause a full pipeline run on every capture. Tolerating a few bits collapses
    /// those minor changes into the dedupe path while still picking up real
    /// differences (new window, scroll, switching apps, etc.) reliably.
    private static let hashTolerance: Int = 4

    /// Slow-poll interval used while the screen is unchanged.
    /// 30 s feels about right — long enough that overnight idle costs near-zero, short enough
    /// that "I came back to the keyboard" is detected before the user notices anything.
    private static let slowInterval: TimeInterval = 30

    private static let hashContext = CIContext(options: [.useSoftwareRenderer: false])

    init(frameInterval: TimeInterval) {
        self.frameInterval = frameInterval
    }

    func updateInterval(_ seconds: TimeInterval) {
        frameInterval = max(1, seconds)
        if isRunning {
            scheduleNextTick()
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
        // Reset adaptive state on every start — first capture should always be treated as
        // a "change" so it gets stored.
        lastFrameHash = nil
        idleStreak = 0
        await captureOnce()
        scheduleNextTick()
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
            self.lastError = error.localizedDescription
        }
    }

    /// Schedules the NEXT capture using adaptive interval. Called once after each capture
    /// completes (vs a fixed-rate `repeats: true` Timer) so we can vary the cadence.
    private func scheduleNextTick() {
        timer?.invalidate()
        let interval = idleStreak >= Self.idleThreshold ? Self.slowInterval : frameInterval
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.captureOnce()
                if self.isRunning { self.scheduleNextTick() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func activeDisplay() -> SCDisplay? {
        guard !displays.isEmpty else { return nil }

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

        let mouseLoc = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLoc) }),
           let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           let match = displays.first(where: { $0.displayID == displayID }) {
            return match
        }

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
            // Skip if the frontmost app is in the excluded list.
            let snapshot = windowTracker.snapshot()
            if let bundle = snapshot.bundleID,
               SettingsStore.currentExcludedAppBundleIDs.contains(bundle) {
                return
            }
            let buffer = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config)
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }

            // Adaptive idle detection: hash the pixel buffer BEFORE the expensive HEIC encode
            // and DB write. If the screen looks roughly identical to the previous capture
            // (Hamming distance within tolerance), skip the whole pipeline and let
            // `scheduleNextTick` move us to slow polling.
            let hash = Self.pixelBufferHash(pixelBuffer)
            if let prev = lastFrameHash, (prev ^ hash).nonzeroBitCount <= Self.hashTolerance {
                idleStreak += 1
                return
            }
            idleStreak = 0
            lastFrameHash = hash

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

    /// 64-bit average-hash of an 8×8 grayscale render of the pixel buffer. Cheap perceptual
    /// fingerprint used to decide "is the screen unchanged since the last capture".
    private static func pixelBufferHash(_ buffer: CVPixelBuffer) -> UInt64 {
        let ci = CIImage(cvPixelBuffer: buffer)
        // Stretch-fit into 8×8 (square) — losing aspect is fine for hashing.
        let scaleX = 8.0 / ci.extent.width
        let scaleY = 8.0 / ci.extent.height
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        var bgra = [UInt8](repeating: 0, count: 8 * 8 * 4)
        bgra.withUnsafeMutableBytes { ptr in
            hashContext.render(
                scaled,
                toBitmap: ptr.baseAddress!,
                rowBytes: 8 * 4,
                bounds: CGRect(x: 0, y: 0, width: 8, height: 8),
                format: .BGRA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }

        var greys = [UInt8](repeating: 0, count: 64)
        var total = 0
        for i in 0..<64 {
            let b = bgra[i * 4]
            let g = bgra[i * 4 + 1]
            let r = bgra[i * 4 + 2]
            let grey = UInt8((Int(r) + Int(g) + Int(b)) / 3)
            greys[i] = grey
            total += Int(grey)
        }
        let avg = total / 64
        var hash: UInt64 = 0
        for (i, p) in greys.enumerated() where Int(p) > avg {
            hash |= UInt64(1) << UInt64(i)
        }
        return hash
    }
}
