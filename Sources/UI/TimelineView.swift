import SwiftUI
import AppKit
import AVFoundation
import CoreMedia

@MainActor
final class TimelineModel: ObservableObject {
    /// Day currently displayed (start-of-day in local time).
    @Published var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    /// Earliest day with any frames — minimum allowed value of the date picker.
    @Published var earliestDay: Date = Calendar.current.startOfDay(for: Date())

    /// Slider bounds for the selected day, clamped to actually-captured frames on that day.
    @Published var dayStart: Date = Calendar.current.startOfDay(for: Date())
    @Published var dayEnd: Date = Calendar.current.startOfDay(for: Date()).addingTimeInterval(1)

    @Published var current: Date = Date()
    @Published var currentImage: NSImage?
    @Published var currentRecord: FrameRecord?
    @Published var totalFramesInDay: Int = 0
    @Published var hasFramesInDay: Bool = false
    @Published var errorMessage: String?
    @Published var meetingsInDay: [MeetingRecord] = []
    @Published var currentMeeting: MeetingRecord?
    @Published var isPlaying: Bool = false
    @Published var audioPlaying: Bool = false
    @Published var playbackSpeed: Double = 1.0 {
        didSet { applyPlaybackSpeed() }
    }
    /// 0 = whole day; otherwise the visible window's duration in minutes (5, 30, 120).
    @Published var zoomMinutes: Int = 0
    /// Centre of the visible window when zoomed.
    @Published var windowCenter: Date = Date()

    var visibleStart: Date {
        guard zoomMinutes > 0 else { return dayStart }
        let half = TimeInterval(zoomMinutes * 60) / 2
        let proposed = windowCenter.addingTimeInterval(-half)
        return max(proposed, dayStart)
    }
    var visibleEnd: Date {
        guard zoomMinutes > 0 else { return dayEnd }
        let half = TimeInterval(zoomMinutes * 60) / 2
        let proposed = windowCenter.addingTimeInterval(half)
        return min(proposed, dayEnd)
    }

    func setZoom(minutes: Int) {
        zoomMinutes = minutes
        if minutes > 0 {
            windowCenter = current
        }
    }

    /// Recenter the visible window on `date` (called from the overview-track tap).
    func recenter(at date: Date) {
        windowCenter = date
        // If cursor is now outside the visible window, snap it inside.
        if current < visibleStart || current > visibleEnd {
            seek(to: date)
        }
    }

    private var refreshTimer: Timer?
    private var loadTask: Task<Void, Never>?
    /// Frame ID currently shown in the preview — guards against redundant image decodes.
    private var lastLoadedFrameID: Int64?
    private var playTimer: Timer?
    private var lastPlayTick: Date?
    private var player: AVPlayer?
    private var openObserver: NSObjectProtocol?

    var todayDay: Date { Calendar.current.startOfDay(for: Date()) }
    var canGoPrevious: Bool { selectedDay > earliestDay }
    var canGoNext: Bool { selectedDay < todayDay }

    func startAutoRefresh() {
        // Each time the timeline window is opened we want to land on "today",
        // even if the user navigated to a different day in a previous session.
        goToToday()
        refreshGlobal()
        loadDay(jumpToLatest: true)
        if openObserver == nil {
            openObserver = NotificationCenter.default.addObserver(
                forName: .timelineWindowOpened,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.goToToday() }
            }
        }
        refreshTimer?.invalidate()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshGlobal()
                // Only follow the live edge automatically when viewing today.
                self.loadDay(jumpToLatest: false)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        loadTask?.cancel()
        if let openObserver {
            NotificationCenter.default.removeObserver(openObserver)
        }
        openObserver = nil
        pause()
    }

    /// Pulls earliestDay (independent of selectedDay) so the date picker's range is correct.
    private func refreshGlobal() {
        if let earliest = Database.shared.earliestFrameDate() {
            earliestDay = Calendar.current.startOfDay(for: earliest)
        }
    }

    /// Recomputes day bounds, frame count, meetings list for `selectedDay`.
    func loadDay(jumpToLatest: Bool) {
        let day = selectedDay
        let count = Database.shared.frameCount(inDay: day)
        totalFramesInDay = count
        hasFramesInDay = count > 0
        meetingsInDay = Database.shared.meetings(inDay: day)

        if let range = Database.shared.frameRange(inDay: day) {
            dayStart = range.start
            dayEnd = max(range.end, range.start.addingTimeInterval(1))
        } else {
            dayStart = day
            dayEnd = day.addingTimeInterval(60) // dummy non-zero range so the slider doesn't crash
        }

        if jumpToLatest || current < dayStart || current > dayEnd {
            current = dayEnd
            loadFrame(at: dayEnd)
            syncMeeting(at: dayEnd, seekAudio: false)
        }
    }

    func selectDay(_ day: Date) {
        let start = Calendar.current.startOfDay(for: day)
        guard start != selectedDay else { return }
        pause()
        selectedDay = start
        loadDay(jumpToLatest: true)
    }

    func goPreviousDay() {
        guard canGoPrevious,
              let prev = Calendar.current.date(byAdding: .day, value: -1, to: selectedDay) else { return }
        selectDay(prev)
    }

    func goNextDay() {
        guard canGoNext,
              let next = Calendar.current.date(byAdding: .day, value: 1, to: selectedDay) else { return }
        selectDay(next)
    }

    func goToToday() {
        selectDay(Date())
    }

    func loadFrame(at date: Date) {
        let snap = date
        // Cancel only the in-flight image *decode* — but first identify the target frame ID
        // so we can skip work entirely if we're already showing it. During playback we tick
        // every 0.25 s but frames are 3 s apart, so most ticks land on the same frame and
        // shouldn't trigger another decode.
        Task { [weak self] in
            guard let self else { return }
            guard let record = Database.shared.frame(at: snap) else {
                await MainActor.run { self.errorMessage = "No frame found at this time." }
                return
            }
            let alreadyShown = await MainActor.run { self.lastLoadedFrameID == record.id }
            if alreadyShown {
                await MainActor.run { self.currentRecord = record }
                return
            }
            self.loadTask?.cancel()
            await MainActor.run {
                self.currentRecord = record
                self.lastLoadedFrameID = record.id
            }
            let url = Database.shared.framesDirectory.appendingPathComponent(record.imagePath)
            let task = Task.detached(priority: .userInitiated) { () -> NSImage? in
                NSImage(contentsOf: url)
            }
            self.loadTask = Task { [weak self] in
                let image = await task.value
                guard let self else { return }
                if Task.isCancelled { return }
                if let image {
                    await MainActor.run {
                        self.currentImage = image
                        self.errorMessage = nil
                    }
                } else {
                    await MainActor.run {
                        self.errorMessage = "Could not load \(url.lastPathComponent)"
                    }
                }
            }
        }
    }

    func seek(to date: Date) {
        // If user seeks outside the currently-loaded day, snap the view to that day too.
        let day = Calendar.current.startOfDay(for: date)
        if day != selectedDay {
            selectedDay = day
            loadDay(jumpToLatest: false)
        }
        current = date
        loadFrame(at: date)
        syncMeeting(at: date, seekAudio: true)
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        lastPlayTick = Date()
        syncMeeting(at: current, seekAudio: true)
        applyPlaybackSpeed()
        playTimer?.invalidate()
        // 0.5 s is plenty for slider-position smoothness; the audio (AVPlayer) and frame
        // decode (only when frame ID changes, ~every 3 s) run independently.
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        playTimer = t
    }

    func pause() {
        isPlaying = false
        playTimer?.invalidate()
        playTimer = nil
        lastPlayTick = nil
        player?.pause()
        audioPlaying = false
    }

    private func tick() {
        guard isPlaying, let last = lastPlayTick else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(last)
        lastPlayTick = now

        // At higher speeds, the cursor advances faster than wall-clock by `playbackSpeed`.
        // Audio rate is capped at 2x for intelligibility (see applyPlaybackSpeed).
        let next = current.addingTimeInterval(elapsed * playbackSpeed)
        if next >= dayEnd {
            current = dayEnd
            loadFrame(at: dayEnd)
            pause()
            return
        }
        current = next
        loadFrame(at: next)
        // At fast scrubbing speeds we still want to seek the audio so it picks up correctly
        // when the user drops back to 1x or 2x. But forcing a seek every tick stutters the
        // player; only seek on meeting transitions.
        syncMeeting(at: next, seekAudio: false)
    }

    /// Adjusts AVPlayer's rate to match `playbackSpeed`, with a cap.
    /// Audio at >2x sounds awful, so above that we pause the audio entirely and let the user
    /// fast-scrub frames silently.
    private func applyPlaybackSpeed() {
        guard let player else { return }
        if !isPlaying || currentMeeting == nil {
            player.rate = 0
            audioPlaying = false
            return
        }
        if playbackSpeed <= 2.0 {
            player.rate = Float(playbackSpeed)
            audioPlaying = true
        } else {
            player.pause()
            audioPlaying = false
        }
    }

    private func syncMeeting(at date: Date, seekAudio: Bool) {
        let meeting = Database.shared.meeting(coveringInstant: date)

        if meeting?.id != currentMeeting?.id {
            player?.pause()
            player = nil
            audioPlaying = false
            currentMeeting = meeting

            if let meeting {
                let url = Database.shared.meetingsDirectory.appendingPathComponent(meeting.audioPath)
                if FileManager.default.fileExists(atPath: url.path) {
                    let p = AVPlayer(url: url)
                    let offset = max(0, date.timeIntervalSince(meeting.startedAt))
                    p.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        guard let self else { return }
                        Task { @MainActor in self.applyPlaybackSpeed() }
                    }
                    self.player = p
                }
            }
            return
        }

        guard let meeting, let player else { return }

        if seekAudio {
            let offset = max(0, date.timeIntervalSince(meeting.startedAt))
            player.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.applyPlaybackSpeed() }
            }
        }
    }
}

struct TimelineView: View {
    @StateObject private var model = TimelineModel()
    @State private var query: String = ""
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var jumpInput: String = ""

    var body: some View {
        NavigationSplitView {
            SearchSidebar(query: $query) { hit in
                model.seek(to: hit.capturedAt)
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 340, max: 480)
        } detail: {
            VStack(spacing: 0) {
                dayBar
                Divider()
                previewArea
                Divider()
                scrubberArea
            }
            .frame(minWidth: 700, minHeight: 500)
        }
        .frame(minWidth: 1100, minHeight: 600)
        .onAppear { model.startAutoRefresh() }
        .onDisappear { model.stopAutoRefresh() }
    }

    // MARK: - Day picker bar

    private var dayBar: some View {
        HStack(spacing: 8) {
            Button {
                model.goPreviousDay()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canGoPrevious)
            .help("Previous day")

            DatePicker(
                "Day",
                selection: dayBinding,
                in: model.earliestDay...model.todayDay,
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .labelsHidden()

            Button {
                model.goNextDay()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canGoNext)
            .help("Next day")

            Button("Today") {
                model.goToToday()
            }
            .disabled(Calendar.current.isDateInToday(model.selectedDay))

            Spacer()

            Text(daySummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var dayBinding: Binding<Date> {
        Binding<Date>(
            get: { model.selectedDay },
            set: { model.selectDay($0) }
        )
    }

    private var daySummary: String {
        if !model.hasFramesInDay {
            return "No frames captured this day"
        }
        let mins = model.dayEnd.timeIntervalSince(model.dayStart) / 60
        let mtg = model.meetingsInDay.count
        return "\(model.totalFramesInDay) frames · \(Int(mins.rounded())) min span · \(mtg) meeting\(mtg == 1 ? "" : "s")"
    }

    // MARK: - Preview

    private var previewArea: some View {
        ZStack {
            Color.black
            if let img = model.currentImage, model.hasFramesInDay {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(zoomScale)
                    .offset(panOffset)
                    .padding(8)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                zoomScale = max(1.0, min(8.0, lastZoomScale * value))
                            }
                            .onEnded { _ in lastZoomScale = zoomScale }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard zoomScale > 1.0 else { return }
                                panOffset = CGSize(
                                    width: lastPanOffset.width + value.translation.width,
                                    height: lastPanOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in lastPanOffset = panOffset }
                    )
                    .onTapGesture(count: 2) { resetZoom() }
                zoomControls
            } else if !model.hasFramesInDay {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Nothing captured on this day.")
                        .foregroundStyle(.secondary)
                    Text("Pick a different date, or jump to today if ReviewLite is currently running.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                ProgressView()
            }
            if let err = model.errorMessage, model.hasFramesInDay {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(err).font(.caption)
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
                    .padding()
                }
            }
            if model.audioPlaying, let m = model.currentMeeting {
                VStack {
                    HStack {
                        Spacer()
                        AudioBadge(meeting: m).padding()
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Scrubber

    private var scrubberArea: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                playButton
                Text(formatTime(model.current))
                    .font(.title3.monospacedDigit())
                jumpToTimeField
                Spacer()
                if let r = model.currentRecord, model.hasFramesInDay {
                    metadataLabel(r)
                }
            }
            sliderRow
                .disabled(!model.hasFramesInDay)
            hourTicks
                .frame(height: 18)
            HStack {
                Text(formatTime(model.visibleStart)).font(.caption.monospacedDigit())
                Spacer()
                if model.zoomMinutes > 0 {
                    Text("Visible window — click overview to pan").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(formatTime(model.visibleEnd)).font(.caption.monospacedDigit())
            }
            overviewTrack
                .frame(height: 22)
            HStack(spacing: 16) {
                Button("Jump to latest") {
                    model.seek(to: model.dayEnd)
                }
                .disabled(!model.hasFramesInDay)
                Spacer()
                zoomPicker
                speedPicker
            }
        }
        .padding()
    }

    private var playButton: some View {
        Button {
            model.togglePlay()
        } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.title3)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .keyboardShortcut(.space, modifiers: [])
        .disabled(!model.hasFramesInDay)
    }

    private var sliderRow: some View {
        let lo = model.visibleStart.timeIntervalSince1970
        let hi = max(lo + 1, model.visibleEnd.timeIntervalSince1970)
        let binding = Binding<Double>(
            get: { min(max(model.current.timeIntervalSince1970, lo), hi) },
            set: { newVal in
                model.seek(to: Date(timeIntervalSince1970: newVal))
            }
        )
        return Slider(value: binding, in: lo...hi)
    }

    private var jumpToTimeField: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.right.to.line")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("HH:MM", text: $jumpInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .font(.caption.monospacedDigit())
                .onSubmit {
                    if let target = parseJumpInput(jumpInput) {
                        model.seek(to: target)
                    }
                    jumpInput = ""
                }
        }
        .help("Jump to a time on the selected day. Format: HH:MM or HH:MM:SS.")
        .disabled(!model.hasFramesInDay)
    }

    private func parseJumpInput(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":")
        guard parts.count >= 2,
              let h = Int(parts[0]), (0...23).contains(h),
              let m = Int(parts[1]), (0...59).contains(m) else { return nil }
        let s: Int
        if parts.count >= 3, let sec = Int(parts[2]), (0...59).contains(sec) {
            s = sec
        } else {
            s = 0
        }
        return Calendar.current.date(bySettingHour: h, minute: m, second: s, of: model.selectedDay)
    }

    private var zoomControls: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Button {
                        zoomScale = min(8.0, zoomScale + 0.5)
                        lastZoomScale = zoomScale
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        let next = max(1.0, zoomScale - 0.5)
                        zoomScale = next
                        lastZoomScale = next
                        if next == 1.0 {
                            panOffset = .zero
                            lastPanOffset = .zero
                        }
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .disabled(zoomScale <= 1.0)

                    Button {
                        resetZoom()
                    } label: {
                        Text("\(Int(zoomScale * 100))%")
                            .font(.caption.monospacedDigit())
                            .frame(minWidth: 38)
                    }
                    .buttonStyle(.bordered)
                    .help("Reset zoom (or double-click the image)")
                    .disabled(zoomScale == 1.0 && panOffset == .zero)
                }
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(8)
            }
            Spacer()
        }
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoomScale = 1.0
            lastZoomScale = 1.0
            panOffset = .zero
            lastPanOffset = .zero
        }
    }

    private var speedPicker: some View {
        Picker("Speed", selection: $model.playbackSpeed) {
            Text("1×").tag(1.0)
            Text("2×").tag(2.0)
            Text("4×").tag(4.0)
            Text("8×").tag(8.0)
            Text("16×").tag(16.0)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240)
        .help("Playback speed. Audio plays at 1× or 2×; faster speeds scrub frames silently.")
    }

    private var hourTicks: some View {
        GeometryReader { geo in
            let lo = model.visibleStart.timeIntervalSince1970
            let hi = max(lo + 1, model.visibleEnd.timeIntervalSince1970)
            let span = hi - lo
            let stepHours = hourStep(forSpanSeconds: span)
            let marks = hourMarks(start: model.visibleStart, end: model.visibleEnd, stepHours: stepHours)
            ZStack(alignment: .topLeading) {
                ForEach(marks, id: \.self) { date in
                    let x = CGFloat((date.timeIntervalSince1970 - lo) / span) * geo.size.width
                    VStack(spacing: 1) {
                        Rectangle().fill(Color.secondary.opacity(0.45)).frame(width: 1, height: 5)
                        Text(hourLabel(date))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .offset(x: x - 14, y: 0)
                }
            }
        }
    }

    /// Pick a tick-stride (in seconds) that produces ~6–10 marks across the visible span.
    private func hourStep(forSpanSeconds span: Double) -> Int {
        let hours = span / 3600
        switch hours {
        case ..<0.05:   return 30          // ≤3 min span → 30s ticks
        case ..<0.2:    return 60          // ≤12 min → 1m ticks
        case ..<0.6:    return 5 * 60      // ≤36 min → 5m ticks
        case ..<2:      return 15 * 60     // ≤2h → 15m ticks
        case ..<6:      return 60 * 60     // ≤6h → 1h
        case ..<12:     return 2 * 3600
        case ..<20:     return 3 * 3600
        default:        return 4 * 3600
        }
    }

    private func hourMarks(start: Date, end: Date, stepHours strideSeconds: Int) -> [Date] {
        var dates: [Date] = []
        let interval = TimeInterval(strideSeconds)
        // Snap to the next clean boundary at-or-after start.
        let startSecs = start.timeIntervalSince1970
        let snapped = ceil(startSecs / interval) * interval
        var t = snapped
        let endSecs = end.timeIntervalSince1970
        while t <= endSecs {
            dates.append(Date(timeIntervalSince1970: t))
            t += interval
        }
        return dates
    }

    private func hourLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private var zoomPicker: some View {
        Picker("Zoom", selection: zoomBinding) {
            Text("Day").tag(0)
            Text("2h").tag(120)
            Text("30m").tag(30)
            Text("5m").tag(5)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 200)
        .help("Timeline zoom level. Lower = scrub finer windows.")
        .disabled(!model.hasFramesInDay)
    }

    private var zoomBinding: Binding<Int> {
        Binding<Int>(
            get: { model.zoomMinutes },
            set: { newVal in model.setZoom(minutes: newVal) }
        )
    }

    /// Whole-day overview track. Shows meetings and the visible-window highlight.
    /// Click anywhere to recenter the zoomed window on that point.
    private var overviewTrack: some View {
        GeometryReader { geo in
            let lo = model.dayStart.timeIntervalSince1970
            let hi = max(lo + 1, model.dayEnd.timeIntervalSince1970)
            let span = hi - lo
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.18)).frame(height: 10)

                // Meeting bands
                ForEach(model.meetingsInDay) { meeting in
                    if let band = bandRect(for: meeting, totalWidth: geo.size.width, lo: lo, span: span) {
                        Capsule()
                            .fill(Color.accentColor.opacity(model.currentMeeting?.id == meeting.id ? 0.95 : 0.65))
                            .frame(width: max(2, band.width), height: 10)
                            .offset(x: band.x)
                            .help(bandTooltip(for: meeting))
                    }
                }

                // Visible-window highlight (only meaningful when zoomed)
                if model.zoomMinutes > 0 {
                    let vS = (model.visibleStart.timeIntervalSince1970 - lo) / span
                    let vE = (model.visibleEnd.timeIntervalSince1970 - lo) / span
                    let x = geo.size.width * CGFloat(vS)
                    let w = max(4, geo.size.width * CGFloat(vE - vS))
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.12)))
                        .frame(width: w, height: 18)
                        .offset(x: x)
                }

                // Cursor playhead
                let cursorFrac = max(0, min(1, (model.current.timeIntervalSince1970 - lo) / span))
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2, height: 22)
                    .offset(x: geo.size.width * CGFloat(cursorFrac))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let frac = max(0, min(1, value.location.x / geo.size.width))
                        let target = Date(timeIntervalSince1970: lo + Double(frac) * span)
                        if model.zoomMinutes > 0 {
                            model.recenter(at: target)
                        } else {
                            model.seek(to: target)
                        }
                    }
            )
        }
    }

    private func bandRect(for meeting: MeetingRecord, totalWidth: CGFloat, lo: Double, span: Double) -> (x: CGFloat, width: CGFloat)? {
        let start = meeting.startedAt.timeIntervalSince1970
        let end = (meeting.endedAt ?? Date()).timeIntervalSince1970
        let hi = lo + span
        guard span > 0, end >= lo, start <= hi else { return nil }
        let clampedStart = max(start, lo)
        let clampedEnd = min(end, hi)
        let x = CGFloat((clampedStart - lo) / span) * totalWidth
        let w = CGFloat((clampedEnd - clampedStart) / span) * totalWidth
        return (x, w)
    }

    private func bandTooltip(for meeting: MeetingRecord) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        var s = "Meeting · \(f.string(from: meeting.startedAt))"
        if let app = meeting.triggeringApp {
            s += " · \(app)"
        }
        if let dur = meeting.duration {
            s += " · \(formatDuration(dur))"
        }
        return s
    }

    private func formatDuration(_ s: TimeInterval) -> String {
        let total = Int(s)
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    private func formatTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .medium
        return f.string(from: d)
    }

    @ViewBuilder
    private func metadataLabel(_ r: FrameRecord) -> some View {
        HStack(spacing: 6) {
            if let bundle = r.appBundleID {
                Text(appName(bundleID: bundle) ?? bundle)
                    .font(.caption.weight(.semibold))
            }
            if let title = r.windowTitle, !title.isEmpty {
                Text("·").foregroundStyle(.secondary)
                Text(title).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    private func appName(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? FileManager.default.displayName(atPath: url.path)
    }
}

extension Notification.Name {
    /// Posted by MenuBarController each time the user re-opens the Timeline window,
    /// so the model can snap back to "today".
    static let timelineWindowOpened = Notification.Name("ReviewLite.timelineWindowOpened")
}

private struct AudioBadge: View {
    let meeting: MeetingRecord
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2.fill")
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: pulse)
            Text("Playing meeting audio").font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.15)))
        .onAppear { pulse = true }
        .onDisappear { pulse = false }
    }
}
