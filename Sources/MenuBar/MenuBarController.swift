import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarController: NSObject {
    private let recorder: ScreenRecorder
    private let meetingMonitor: MeetingMonitor
    private let statusItem: NSStatusItem
    private var timelineWindow: NSWindow?
    private var meetingsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    init(recorder: ScreenRecorder, meetingMonitor: MeetingMonitor) {
        self.recorder = recorder
        self.meetingMonitor = meetingMonitor
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        rebuildMenu()

        recorder.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureButton()
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        meetingMonitor.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureButton()
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        meetingMonitor.$lastDetectedWindowTitle
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let symbol: String
        switch meetingMonitor.status {
        case .recording:
            symbol = "rectangle.dashed.badge.record"
        case .stopping, .transcribing:
            symbol = "waveform.badge.magnifyingglass"
        default:
            symbol = recorder.isRunning ? "rectangle.dashed" : "rectangle.dashed"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ReviewLite")
        button.image?.isTemplate = true
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // Capture toggle
        let toggle = NSMenuItem(
            title: recorder.isRunning ? "Pause Screen Capture" : "Resume Screen Capture",
            action: #selector(togglePressed),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        if let last = recorder.lastCaptureAt {
            let f = DateFormatter(); f.timeStyle = .medium
            let item = NSMenuItem(title: "Last frame: \(f.string(from: last))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Meeting status
        let meetingStatus = meetingStatusItem()
        meetingStatus.isEnabled = false
        menu.addItem(meetingStatus)

        switch meetingMonitor.status {
        case .idle:
            let m = NSMenuItem(title: "Record Meeting Now", action: #selector(manualMeetingStart), keyEquivalent: "")
            m.target = self
            menu.addItem(m)
        case .recording:
            let m = NSMenuItem(title: "Stop Meeting Recording", action: #selector(manualMeetingStop), keyEquivalent: "")
            m.target = self
            menu.addItem(m)
        case .stopping, .transcribing:
            break
        }

        menu.addItem(.separator())

        let timeline = NSMenuItem(title: "Open Timeline…", action: #selector(openTimelinePressed), keyEquivalent: "t")
        timeline.target = self
        menu.addItem(timeline)

        let meetings = NSMenuItem(title: "Open Meetings…", action: #selector(openMeetingsPressed), keyEquivalent: "m")
        meetings.target = self
        menu.addItem(meetings)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsPressed), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ReviewLite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func meetingStatusItem() -> NSMenuItem {
        let title: String
        switch meetingMonitor.status {
        case .idle:
            if let t = meetingMonitor.lastDetectedWindowTitle, !t.isEmpty {
                title = "Meeting: idle · last seen \"\(truncate(t))\""
            } else {
                title = "Meeting: idle (auto-detect on)"
            }
        case .recording(_, let app, let started):
            let elapsed = Int(Date().timeIntervalSince(started))
            let detected = meetingMonitor.lastDetectedWindowTitle.map { "  · window: \"\(truncate($0))\"" } ?? ""
            title = "Meeting: recording \(displayName(for: app)) — \(formatDuration(elapsed))\(detected)"
        case .stopping:
            title = "Meeting: finalizing audio…"
        case .transcribing:
            title = "Meeting: transcribing…"
        }
        return NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }

    private func truncate(_ s: String, max: Int = 60) -> String {
        if s.count <= max { return s }
        return String(s.prefix(max - 1)) + "…"
    }

    @objc private func togglePressed() {
        Task { await recorder.toggle() }
    }

    @objc private func manualMeetingStart() {
        Task { await meetingMonitor.manualStart() }
    }

    @objc private func manualMeetingStop() {
        Task { await meetingMonitor.manualStop() }
    }

    @objc private func openTimelinePressed() {
        if timelineWindow == nil {
            timelineWindow = makeWindow(title: "ReviewLite Timeline",
                                        size: NSSize(width: 1200, height: 720),
                                        rootView: AnyView(TimelineView()))
        }
        NSApp.activate(ignoringOtherApps: true)
        timelineWindow?.makeKeyAndOrderFront(nil)
        // Snap the timeline back to today on every open (in case a previous session left
        // the date picker on a different day).
        NotificationCenter.default.post(name: .timelineWindowOpened, object: nil)
    }

    @objc private func openMeetingsPressed() {
        if meetingsWindow == nil {
            meetingsWindow = makeWindow(title: "ReviewLite Meetings",
                                        size: NSSize(width: 1200, height: 720),
                                        rootView: AnyView(MeetingsView()))
        }
        NSApp.activate(ignoringOtherApps: true)
        meetingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettingsPressed() {
        if settingsWindow == nil {
            let view = SettingsView().environmentObject(SettingsStore.shared)
            settingsWindow = makeWindow(title: "ReviewLite Settings",
                                        size: NSSize(width: 520, height: 360),
                                        rootView: AnyView(view),
                                        resizable: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(title: String, size: NSSize, rootView: AnyView, resizable: Bool = true) -> NSWindow {
        let host = NSHostingController(rootView: rootView)
        let win = NSWindow(contentViewController: host)
        win.title = title
        win.setContentSize(size)
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { mask.insert(.resizable) }
        win.styleMask = mask
        win.isReleasedWhenClosed = false
        win.center()
        return win
    }

    private func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? bundleID
    }

    private func formatDuration(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
