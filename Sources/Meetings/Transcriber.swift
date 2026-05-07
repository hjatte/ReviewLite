import Foundation
import Combine
import WhisperKit

/// Shared status of the transcription model — published so UI can show "downloading model…" banners.
@MainActor
final class TranscriberStatus: ObservableObject {
    static let shared = TranscriberStatus()
    @Published var isLoadingModel: Bool = false
    @Published var modelReady: Bool = false
    @Published var loadError: String?
    private init() {}
}

actor Transcriber {
    static let shared = Transcriber()

    private var pipeline: WhisperKit?
    private(set) var modelName: String = "openai_whisper-base.en"

    func ensureReady() async throws {
        if pipeline != nil { return }
        await MainActor.run {
            TranscriberStatus.shared.isLoadingModel = true
            TranscriberStatus.shared.loadError = nil
        }
        do {
            let config = WhisperKitConfig(model: modelName)
            let pipe = try await WhisperKit(config)
            self.pipeline = pipe
            await MainActor.run {
                TranscriberStatus.shared.isLoadingModel = false
                TranscriberStatus.shared.modelReady = true
            }
        } catch {
            await MainActor.run {
                TranscriberStatus.shared.isLoadingModel = false
                TranscriberStatus.shared.loadError = error.localizedDescription
            }
            throw error
        }
    }

    func transcribe(audioPath: String) async throws -> [(start: Double, end: Double, text: String)] {
        try await ensureReady()
        guard let pipeline else {
            throw NSError(domain: "Transcriber", code: -1, userInfo: [NSLocalizedDescriptionKey: "WhisperKit pipeline not initialized"])
        }
        let results = try await pipeline.transcribe(audioPath: audioPath)
        var segments: [(start: Double, end: Double, text: String)] = []
        for r in results {
            for s in r.segments {
                let cleaned = Self.stripWhisperTokens(s.text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                segments.append((Double(s.start), Double(s.end), cleaned))
            }
        }
        return segments
    }

    /// Strips Whisper's control tokens like `<|startoftranscript|>`, `<|en|>`, `<|nospeech|>`,
    /// and inline timestamp markers `<|0.00|>` that occasionally leak through into segment text.
    private static let whisperTokenRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "<\\|[^|>]*\\|>", options: [])
    }()

    private static func stripWhisperTokens(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return whisperTokenRegex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
    }
}
