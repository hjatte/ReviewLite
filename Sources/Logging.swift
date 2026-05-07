import Foundation
import os

/// Central place for the app's loggers. Use `os.Logger` (per-subsystem) so messages route into
/// the unified `log` system — visible in Console.app, accessible to Crash Reporter, off in
/// Release except for fault/error levels.
enum Log {
    private static let subsystem = "com.reviewlite.app"

    static let app          = Logger(subsystem: subsystem, category: "app")
    static let capture      = Logger(subsystem: subsystem, category: "capture")
    static let storage      = Logger(subsystem: subsystem, category: "storage")
    static let meetings     = Logger(subsystem: subsystem, category: "meetings")
    static let transcribe   = Logger(subsystem: subsystem, category: "transcribe")
    static let ui           = Logger(subsystem: subsystem, category: "ui")
}
