import AppKit
import CoreGraphics

struct WindowSnapshot {
    var bundleID: String?
    var title: String?
}

/// Reads the frontmost app and the title of its frontmost window.
/// Uses `CGWindowListCopyWindowInfo` rather than the Accessibility API, so it works inside
/// the App Sandbox (Accessibility is unavailable to sandboxed processes).
final class WindowTracker {
    func snapshot() -> WindowSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier

        var title: String?
        if let pid = app?.processIdentifier {
            title = topWindowTitle(forPID: pid)
        }
        return WindowSnapshot(bundleID: bundleID, title: title)
    }

    /// Returns the title of the topmost on-screen window owned by `pid`, if any.
    /// Window titles require the Screen Recording permission since macOS 12.3 — without it,
    /// the title is empty for windows we don't own.
    private func topWindowTitle(forPID pid: pid_t) -> String? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // CGWindowListCopyWindowInfo returns windows ordered front-to-back already.
        for w in windows {
            guard let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner == pid else { continue }
            // Skip tiny windows (menu-bar extras, indicator overlays).
            if let bounds = w[kCGWindowBounds as String] as? [String: CGFloat],
               let width = bounds["Width"], let height = bounds["Height"],
               width < 200 || height < 100 {
                continue
            }
            if let name = w[kCGWindowName as String] as? String, !name.isEmpty {
                return name
            }
        }
        return nil
    }
}
