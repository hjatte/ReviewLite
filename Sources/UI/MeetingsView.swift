import SwiftUI
import AVKit
import AppKit
import Combine

@MainActor
final class MeetingsViewModel: ObservableObject {
    @Published var meetings: [MeetingRecord] = []
    @Published var selected: MeetingRecord?

    private var refreshTimer: Timer?

    func startAutoRefresh() {
        refresh()
        refreshTimer?.invalidate()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        let fresh = Database.shared.meetings()
        meetings = fresh
        // Keep the same selection if still present, refreshed from DB.
        if let sel = selected, let updated = fresh.first(where: { $0.id == sel.id }) {
            selected = updated
        } else if selected == nil {
            selected = fresh.first
        }
    }

    func delete(_ meeting: MeetingRecord) {
        Database.shared.deleteMeeting(id: meeting.id)
        let dir = Database.shared.meetingsDirectory.appendingPathComponent(URL(fileURLWithPath: meeting.audioPath).deletingLastPathComponent().path, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        refresh()
    }
}

struct MeetingsView: View {
    @StateObject private var model = MeetingsViewModel()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 460)
        } detail: {
            if let meeting = model.selected {
                MeetingDetailView(meeting: meeting)
                    .id(meeting.id)
            } else {
                emptyDetail
            }
        }
        .frame(minWidth: 1100, minHeight: 600)
        .onAppear { model.startAutoRefresh() }
        .onDisappear { model.stopAutoRefresh() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if model.meetings.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("No meetings yet.").foregroundStyle(.secondary)
                    Text("Recording starts automatically when Zoom, Teams, Slack or FaceTime becomes active.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Spacer()
            } else {
                List(selection: Binding(
                    get: { model.selected?.id },
                    set: { newID in
                        model.selected = model.meetings.first { $0.id == newID }
                    }
                )) {
                    ForEach(model.meetings) { m in
                        MeetingRow(meeting: m)
                            .tag(m.id as Int64?)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    model.delete(m)
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 48)).foregroundStyle(.tertiary)
            Text("Select a meeting from the list.").foregroundStyle(.secondary)
        }
    }
}

struct MeetingRow: View {
    let meeting: MeetingRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(formatDate(meeting.startedAt))
                    .font(.callout.weight(.semibold))
                Spacer()
                statusBadge
            }
            HStack(spacing: 6) {
                if let app = meeting.triggeringApp {
                    Text(appName(app) ?? app)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let dur = meeting.duration {
                    Text("·").foregroundStyle(.secondary)
                    Text(formatDuration(dur))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch meeting.transcriptStatus {
        case "in_progress":
            Label("Transcribing", systemImage: "waveform.badge.magnifyingglass")
                .labelStyle(.iconOnly)
                .foregroundStyle(.orange)
        case "failed":
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.red)
        case "done":
            Label("Ready", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
        default:
            Label("Pending", systemImage: "clock")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
    }

    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    private func formatDuration(_ s: TimeInterval) -> String {
        let total = Int(s)
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    private func appName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
    }
}

struct MeetingDetailView: View {
    let meeting: MeetingRecord

    @State private var player: AVPlayer?
    @State private var segments: [TranscriptSegmentRecord] = []
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying: Bool = false
    @State private var observer: Any?
    @State private var pollTimer: Timer?
    @ObservedObject private var transcriberStatus = TranscriberStatus.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var minutesText: String?
    @State private var minutesGeneratedAt: Date?
    @State private var minutesProvider: String?
    @State private var minutesGenerating: Bool = false
    @State private var minutesError: String?
    @State private var justCopied: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if transcriberStatus.isLoadingModel {
                modelDownloadBanner
            }
            Divider()
            playerArea
            Divider()
            minutesArea
            Divider()
            transcriptArea
        }
        .onAppear { setup() }
        .onDisappear { teardown() }
    }

    @ViewBuilder
    private var minutesArea: some View {
        let hasKey = KeychainStore.has(settings.aiProvider.keychainKey)
        let canGenerate = !segments.isEmpty && hasKey && !minutesGenerating

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Meeting minutes", systemImage: "doc.text")
                    .font(.callout.weight(.semibold))
                Spacer()
                if minutesGenerating {
                    ProgressView().controlSize(.small)
                    Text("Generating…").font(.caption).foregroundStyle(.secondary)
                } else {
                    if minutesText != nil {
                        Button {
                            copyMinutes()
                        } label: {
                            Label(justCopied ? "Copied" : "Copy",
                                  systemImage: justCopied ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(justCopied ? Color.green : Color.primary)
                                .animation(.easeInOut(duration: 0.15), value: justCopied)
                        }
                    }
                    if hasKey {
                        Button(minutesText == nil ? "Generate minutes" : "Regenerate") {
                            Task { await generateMinutes() }
                        }
                        .disabled(!canGenerate)
                    }
                }
            }

            if !hasKey {
                noKeyBanner
            }

            if let err = minutesError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            if let minutesText {
                ScrollView {
                    Text(LocalizedStringKey(minutesText))
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 320)
                if let at = minutesGeneratedAt, let p = minutesProvider {
                    Text("Generated \(formatRelative(at)) via \(p).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var noKeyBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add an Anthropic Claude or OpenAI API key in Settings to auto-generate structured meeting minutes from each transcript — Summary, Key Points, Decisions, Action Items, Open Questions.")
                .font(.callout)
            Text("Without a key, transcripts stay on this Mac and minutes generation is unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copyMinutes() {
        guard let minutesText, !minutesText.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(minutesText, forType: .string)
        justCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { justCopied = false }
        }
    }

    private func generateMinutes() async {
        let provider = settings.aiProvider
        let transcriptText = segments.map { $0.text }.joined(separator: " ")
        guard !transcriptText.isEmpty else {
            minutesError = "No transcript to summarise yet."
            return
        }
        await MainActor.run {
            minutesError = nil
            minutesGenerating = true
        }
        do {
            let result = try await MinutesGenerator.generate(transcript: transcriptText, using: provider)
            Database.shared.setMinutes(meetingID: meeting.id, minutes: result, provider: provider.displayName)
            await MainActor.run {
                minutesText = result
                minutesGeneratedAt = Date()
                minutesProvider = provider.displayName
                minutesGenerating = false
            }
        } catch {
            await MainActor.run {
                minutesError = error.localizedDescription
                minutesGenerating = false
            }
        }
    }

    private func formatRelative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    private var modelDownloadBanner: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Downloading speech model…")
                    .font(.callout.weight(.medium))
                Text("First-run only, ~140 MB. Transcription will start automatically once it's ready.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(formatDate(meeting.startedAt)).font(.title3.weight(.semibold))
                if let dur = meeting.duration {
                    Text("Duration \(formatDuration(dur))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            statusLabel
        }
        .padding()
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch meeting.transcriptStatus {
        case "in_progress":
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Transcribing…").font(.caption).foregroundStyle(.orange)
            }
        case "failed":
            VStack(alignment: .trailing, spacing: 2) {
                Label("Transcription failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                if let err = meeting.errorMessage {
                    Text(err).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        case "done":
            Label("Transcript ready", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        default:
            Label("Pending", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var playerArea: some View {
        Group {
            if player != nil {
                HStack(spacing: 14) {
                    Button {
                        togglePlayback()
                    } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])

                    Text(formatPlayerTime(currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)

                    Slider(value: Binding<Double>(
                        get: { min(currentTime, max(duration, 1)) },
                        set: { newValue in
                            seek(to: newValue)
                        }
                    ), in: 0...max(duration, 1))

                    Text(formatPlayerTime(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                Text("Audio file missing").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    private func formatPlayerTime(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s)
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    private var transcriptArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if segments.isEmpty {
                        emptyTranscript
                    } else {
                        ForEach(segments) { seg in
                            TranscriptLine(
                                segment: seg,
                                isCurrent: currentTime >= seg.start && currentTime < seg.end,
                                onTap: {
                                    if !isPlaying { isPlaying = true; player?.play() }
                                    seek(to: seg.start)
                                }
                            )
                            .id(seg.id)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: currentTime) {
                if let active = segments.first(where: { currentTime >= $0.start && currentTime < $0.end }) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(active.id, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyTranscript: some View {
        VStack(spacing: 8) {
            switch meeting.transcriptStatus {
            case "in_progress":
                ProgressView()
                Text("Transcribing… (first run downloads the Whisper model, may take a minute)")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            case "failed":
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 32)).foregroundStyle(.red)
                Text("Transcription failed.").foregroundStyle(.secondary)
                if let err = meeting.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
            default:
                Image(systemName: "text.alignleft").font(.system(size: 32)).foregroundStyle(.tertiary)
                Text("No transcript yet.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func setup() {
        let url = Database.shared.meetingsDirectory.appendingPathComponent(meeting.audioPath)
        if FileManager.default.fileExists(atPath: url.path) {
            let p = AVPlayer(url: url)
            self.player = p
            let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
            self.observer = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
                currentTime = time.seconds
            }
            // Load duration asynchronously.
            Task {
                if let asset = p.currentItem?.asset,
                   let dur = try? await asset.load(.duration) {
                    let secs = dur.seconds
                    if secs.isFinite {
                        await MainActor.run { self.duration = secs }
                    }
                }
            }
        }
        segments = Database.shared.transcriptSegments(meetingID: meeting.id)
        // Load any previously-generated minutes for this meeting.
        minutesText = meeting.minutes
        minutesGeneratedAt = meeting.minutesGeneratedAt
        minutesProvider = meeting.minutesProvider
        // If transcript is still being produced, poll for new segments.
        let t = Timer(timeInterval: 4, repeats: true) { _ in
            let fresh = Database.shared.transcriptSegments(meetingID: meeting.id)
            if fresh.count != segments.count { segments = fresh }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func teardown() {
        if let observer, let player {
            player.removeTimeObserver(observer)
        }
        observer = nil
        player?.pause()
        player = nil
        isPlaying = false
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func seek(to seconds: Double) {
        guard let player else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        currentTime = seconds
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            if isPlaying {
                player.play()
            }
        }
    }

    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f.string(from: d)
    }

    private func formatDuration(_ s: TimeInterval) -> String {
        let total = Int(s)
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}

struct TranscriptLine: View {
    let segment: TranscriptSegmentRecord
    let isCurrent: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(formatTime(segment.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .frame(width: 56, alignment: .trailing)
            Text(segment.text)
                .font(.body)
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isCurrent ? Color.accentColor.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    private func formatTime(_ s: Double) -> String {
        let total = Int(s)
        let m = total / 60
        let sec = total % 60
        return String(format: "%d:%02d", m, sec)
    }
}

