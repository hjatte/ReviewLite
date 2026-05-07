import Foundation

struct FrameRecord: Identifiable {
    var id: Int64
    var capturedAt: Date
    var imagePath: String
    var appBundleID: String?
    var windowTitle: String?
}

struct MeetingRecord: Identifiable, Hashable {
    var id: Int64
    var startedAt: Date
    var endedAt: Date?
    var audioPath: String
    var triggeringApp: String?
    var transcriptStatus: String
    var errorMessage: String?
    var minutes: String?
    var minutesGeneratedAt: Date?
    var minutesProvider: String?

    var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}

struct TranscriptSegmentRecord: Identifiable, Hashable {
    var id: Int64
    var start: Double
    var end: Double
    var text: String
}
