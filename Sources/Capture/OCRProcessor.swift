import Foundation
import Vision
import AppKit
import ImageIO

actor OCRProcessor {
    static let shared = OCRProcessor()

    private init() {}

    func process(frameID: Int64, imageURL: URL) async {
        guard let cgImage = Self.loadCGImage(at: imageURL) else { return }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }
        let observations = request.results ?? []
        var lines: [String] = []
        lines.reserveCapacity(observations.count)
        for obs in observations {
            if let candidate = obs.topCandidates(1).first, !candidate.string.isEmpty {
                lines.append(candidate.string)
            }
        }
        let text = lines.joined(separator: "\n")
        guard !text.isEmpty else { return }
        do {
            try Database.shared.setOCR(frameID: frameID, text: text)
        } catch {
            // swallow — OCR is best-effort
        }
    }

    private static func loadCGImage(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
