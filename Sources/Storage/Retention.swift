import Foundation
import Combine

/// Periodically purges history older than `SettingsStore.shared.retentionDays`.
/// Runs once at launch and then every 6 hours while the app is running.
@MainActor
final class RetentionScheduler {
    private var timer: Timer?

    func start() {
        runSweep()
        timer?.invalidate()
        let interval: TimeInterval = 6 * 3600
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runSweep() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func runSweep() {
        let days = SettingsStore.shared.retentionDays
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        Task.detached(priority: .background) {
            // 1. Date-based purge: anything older than the retention cutoff (frames + their OCR
            // text + their image files; meetings + their transcripts + their audio dirs).
            let aged = Database.shared.purgeOlderThan(cutoff)
            // 2. Orphan sweep: any image file or meeting workdir on disk that the DB no longer
            // references is removed too. Catches stragglers from interrupted runs / crashes so
            // disk usage stays in lockstep with what the app shows.
            let orphans = Database.shared.purgeOrphanFiles()

            if aged.framesRemoved > 0 || aged.meetingsRemoved > 0 ||
               orphans.frames > 0 || orphans.meetingDirs > 0 {
                Log.storage.info("Retention sweep: aged \(aged.framesRemoved) frames + \(aged.meetingsRemoved) meetings (>\(days) days); orphans \(orphans.frames) frame files + \(orphans.meetingDirs) meeting dirs")
            }
        }
    }
}
