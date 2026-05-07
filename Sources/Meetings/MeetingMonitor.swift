import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class MeetingMonitor: ObservableObject {
    enum Status: Equatable {
        case idle
        case recording(meetingID: Int64, app: String, startedAt: Date)
        case stopping
        case transcribing(meetingID: Int64)

        var isActive: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    /// A rule that recognises an in-call window for one app.
    /// `windowTitleContains` is matched case-insensitively as a substring; any match counts.
    /// An empty list means "the bundle ID alone is enough" (used for manual-only apps).
    struct Rule {
        let bundleID: String
        let windowTitleContains: [String]
    }

    @Published private(set) var status: Status = .idle
    /// The window title that most recently matched a rule, surfaced for debugging.
    @Published private(set) var lastDetectedWindowTitle: String?

    /// Heuristics for "this app currently has a live meeting window on screen".
    /// Tuned conservatively to avoid false positives from idle UI.
    static let rules: [Rule] = [
        // Zoom: "Zoom Meeting" / "Zoom Webinar" only appear in window titles during an active call.
        // "Zoom Workplace" (the main app window, always present when Zoom runs) is intentionally
        // excluded — it would false-positive every time Zoom is open.
        Rule(bundleID: "us.zoom.xos",
             windowTitleContains: ["Zoom Meeting", "Zoom Webinar"]),
        // Teams active-call windows have titles starting with "Meeting in", "Meeting with",
        // "Call with", or "Meeting now". A bare "| Microsoft Teams" suffix matches every Teams
        // window (chat, calendar, notifications) and must not be used.
        Rule(bundleID: "com.microsoft.teams2",
             windowTitleContains: ["Meeting in ", "Meeting with ", "Call with ", "Meeting now"]),
        Rule(bundleID: "com.microsoft.teams",
             windowTitleContains: ["Meeting in ", "Meeting with ", "Call with ", "Meeting now"]),
        Rule(bundleID: "com.tinyspeck.slackmacgap",
             windowTitleContains: ["Huddle"]),
        Rule(bundleID: "com.hnc.Discord",
             windowTitleContains: ["Voice Connected", "Voice Channel"]),
        Rule(bundleID: "com.cisco.webexmeetingsapp",
             windowTitleContains: ["Webex Meeting"]),
    ]

    /// How often we poll the window list.
    static let pollSeconds: TimeInterval = 3

    /// How long the meeting app must continuously NOT hold the mic before we stop recording.
    /// Short — the mic signal is reliable, so we don't need much padding. The only thing this
    /// guards against is rare blips like AirPods reconnecting mid-call splitting one recording
    /// into two; everything else stops promptly.
    static let graceSeconds: TimeInterval = 5

    /// Hard safety cap — auto-stop after this many seconds even if detection keeps firing.
    /// Prevents runaway recordings if a meeting app leaves a matching window open.
    static let maxRecordingDuration: TimeInterval = 3 * 3600

    private let pipeline = AudioPipeline()
    private var pollTimer: Timer?
    private var lastSeenMeetingAt: Date?
    private var pendingMeetingID: Int64?
    private var pendingDir: URL?

    init() {
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        evaluate()
    }

    /// Number of consecutive polls the mic must be active before we trust it as a meeting trigger.
    /// At a 3-second poll cadence this means ~6 seconds of sustained mic use — enough to cross the
    /// "Teams 'test your microphone' button" spike but trivially crossed by a real call.
    private static let micTriggerStreakRequired: Int = 2
    private var micActiveStreak: Int = 0

    private func evaluate() {
        switch status {
        case .idle:
            evaluateIdle()
        case .recording(_, _, let startedAt):
            evaluateRecording(startedAt: startedAt)
        case .stopping, .transcribing:
            break
        }
    }

    /// While idle: a meeting starts if EITHER a window-title rule matches OR the mic is in
    /// use by another process while a known meeting app is running.
    private func evaluateIdle() {
        if let detection = Self.detectActiveMeetingWindow() {
            lastDetectedWindowTitle = detection.windowTitle
            lastSeenMeetingAt = Date()
            Task { await self.startRecording(triggeringApp: detection.bundleID) }
            return
        }
        if MicrophoneActivity.isInUse(),
           let bundle = Self.firstRunningMeetingBundleID() {
            micActiveStreak += 1
            lastDetectedWindowTitle = "(mic active in \(bundle), \(micActiveStreak)/\(Self.micTriggerStreakRequired))"
            if micActiveStreak >= Self.micTriggerStreakRequired {
                micActiveStreak = 0
                lastSeenMeetingAt = Date()
                Task { await self.startRecording(triggeringApp: bundle) }
            }
        } else {
            micActiveStreak = 0
            lastDetectedWindowTitle = nil
        }
    }

    /// While recording: stop signal is "is any process *other than us* still using audio
    /// input?" via Core Audio's per-process property. We don't need to pause our own mic —
    /// the API ignores our own usage. If no other process has held the mic for `graceSeconds`,
    /// recording stops.
    private func evaluateRecording(startedAt: Date) {
        // Hard cap as a final backstop.
        if Date().timeIntervalSince(startedAt) >= Self.maxRecordingDuration {
            Log.meetings.notice("Meeting hit \(Int(Self.maxRecordingDuration))s safety cap — force-stopping")
            Task { await self.stopRecording() }
            return
        }

        // Per-process mic check (cheap, can run every poll). Only count processes whose bundle
        // ID matches a known meeting app — this excludes things like com.apple.CoreSpeech which
        // permanently hold the mic for dictation.
        // If the API returns nil (failure / unsupported), treat as "no other process holds mic"
        // so we err toward stopping — falling back to window titles here would re-introduce the
        // persistent-Teams-chat-window bug that this whole change is trying to fix.
        let meetingPrefixes = Set(Self.rules.map { $0.bundleID })
        let rawAnswer = AudioProcessActivity.meetingAppHoldingInput(meetingPrefixes: meetingPrefixes)
        let otherMeetingAppHasMic = rawAnswer ?? false
        let answerStr = rawAnswer.map { $0 ? "true" : "false" } ?? "nil"
        let age = Int(Date().timeIntervalSince(self.lastSeenMeetingAt ?? .distantPast))
        Log.meetings.info("evaluateRecording: meetingAppHoldingInput=\(answerStr, privacy: .public) lastSeenAge=\(age)s")

        if otherMeetingAppHasMic {
            lastSeenMeetingAt = Date()
            lastDetectedWindowTitle = "(meeting app holds mic)"
        } else if let detection = Self.detectActiveMeetingWindow() {
            // Purely informational — title detection no longer keeps the recording alive.
            lastDetectedWindowTitle = "\(detection.windowTitle) [title only]"
        } else {
            lastDetectedWindowTitle = nil
        }

        if let last = lastSeenMeetingAt, Date().timeIntervalSince(last) >= Self.graceSeconds {
            Task { await self.stopRecording() }
        }
    }

    /// Returns the bundle ID of the first running meeting app, if any. Used by mic-based
    /// detection — we don't require frontmost or matching window title.
    static func firstRunningMeetingBundleID() -> String? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        for rule in rules where running.contains(rule.bundleID) {
            return rule.bundleID
        }
        return nil
    }

    struct Detection { let bundleID: String; let windowTitle: String }

    /// Returns the first meeting-app window matching a rule, with its title, if any.
    /// Requires Screen Recording permission to read window titles; otherwise returns nil.
    static func detectActiveMeetingWindow() -> Detection? {
        // Use `.optionAll` rather than `.optionOnScreenOnly` so a minimized or
        // off-current-Space meeting window still counts. Title patterns are specific
        // enough (e.g. "Zoom Meeting") that false positives from idle UI are unlikely.
        let opts: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for w in windows {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
            guard let app = NSRunningApplication(processIdentifier: pid),
                  let bundle = app.bundleIdentifier else { continue }
            let title = (w[kCGWindowName as String] as? String) ?? ""
            for rule in rules where rule.bundleID == bundle {
                if rule.windowTitleContains.isEmpty {
                    return Detection(bundleID: bundle, windowTitle: title)
                }
                for needle in rule.windowTitleContains {
                    if title.range(of: needle, options: .caseInsensitive) != nil {
                        return Detection(bundleID: bundle, windowTitle: title)
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Manual control

    func manualStart() async {
        guard case .idle = status else { return }
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "manual"
        await startRecording(triggeringApp: bundle)
        lastSeenMeetingAt = Date()
    }

    func manualStop() async {
        await stopRecording()
    }

    // MARK: - Recording lifecycle

    private func startRecording(triggeringApp: String) async {
        do {
            let dir = try await pipeline.start()
            let started = Date()
            let relPath = dir.lastPathComponent + "/system.m4a"
            let meetingID = try Database.shared.insertMeeting(
                startedAt: started,
                audioPath: relPath,
                triggeringApp: triggeringApp
            )
            pendingMeetingID = meetingID
            pendingDir = dir
            status = .recording(meetingID: meetingID, app: triggeringApp, startedAt: started)
            Log.meetings.info("Meeting recording started (\(triggeringApp, privacy: .public), id=\(meetingID))")
            // Diagnostic: dump the audio-process list as the sandboxed app sees it.
            let snap = AudioProcessActivity.snapshot()
            for entry in snap where entry.runningInput || entry.runningOutput {
                Log.meetings.info("audio-process pid=\(entry.pid) bundle=\(entry.bundleID ?? "—", privacy: .public) IN=\(entry.runningInput) OUT=\(entry.runningOutput)")
            }
        } catch {
            Log.meetings.error("Failed to start meeting recording: \(error.localizedDescription, privacy: .public)")
            status = .idle
        }
    }

    private func stopRecording() async {
        guard let meetingID = pendingMeetingID, let dir = pendingDir else {
            status = .idle
            return
        }
        Log.meetings.info("Meeting recording stopping (id=\(meetingID))")
        status = .stopping

        let mixedURL = await pipeline.stopAndMix()
        let endedAt = Date()

        guard let finalURL = mixedURL else {
            Database.shared.setTranscriptStatus(meetingID: meetingID, status: "failed", error: "no audio captured")
            cleanup()
            status = .idle
            return
        }

        let relPath = dir.lastPathComponent + "/" + finalURL.lastPathComponent
        try? Database.shared.finishMeeting(id: meetingID, endedAt: endedAt, audioPath: relPath)

        if finalURL.lastPathComponent == "mixed.m4a" {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("system.m4a"))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("mic.m4a"))
        }

        status = .transcribing(meetingID: meetingID)
        Database.shared.setTranscriptStatus(meetingID: meetingID, status: "in_progress")
        Task.detached(priority: .background) { [weak self] in
            do {
                let segments = try await Transcriber.shared.transcribe(audioPath: finalURL.path)
                Database.shared.appendTranscriptSegments(meetingID: meetingID, segments: segments)
                Database.shared.setTranscriptStatus(meetingID: meetingID, status: "done")
            } catch {
                Database.shared.setTranscriptStatus(meetingID: meetingID, status: "failed", error: "\(error)")
            }
            await MainActor.run { [weak self] in
                if case .transcribing(let mid) = self?.status, mid == meetingID {
                    self?.status = .idle
                }
            }
        }

        cleanup()
    }

    private func cleanup() {
        pendingMeetingID = nil
        pendingDir = nil
        lastSeenMeetingAt = nil
    }
}
