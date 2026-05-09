import Foundation
import Vision
import AppKit
import CoreGraphics
import ImageIO

/// Per-frame OCR via Apple's Vision framework. Two optimisations vs the naive approach:
///
/// 1. The image is loaded as a downsampled CGImage (max ~1200 px) using ImageIO's
///    thumbnail decoder. Vision doesn't need full-resolution pixels for body text and
///    decoding-then-resizing-internally is materially slower than decoding straight
///    to target size.
///
/// 2. A cheap 8×8 perceptual hash is computed on each frame; if the hash matches the
///    previously-OCR'd frame, the text is copied across instead of re-running Vision.
///    When the user is staring at a static screen — Slack channel, doc, code editor —
///    OCR cost drops from ~one Vision request per capture to a single hash compare.
actor OCRProcessor {
    static let shared = OCRProcessor()

    private init() {}

    private var lastHash: UInt64?
    private var lastText: String?

    /// Max edge sent to Vision. Body text in screenshots is fully readable below this
    /// even from a 4K source.
    private static let ocrMaxPixelSize: Int = 1200

    /// Hamming-distance tolerance for the dedupe hash — same logic as ScreenRecorder.
    /// Without this a moving cursor flips a few bits and we'd re-run Vision needlessly.
    private static let hashTolerance: Int = 4

    func process(frameID: Int64, imageURL: URL) async {
        guard let cgImage = Self.loadDownsampled(at: imageURL, maxPixelSize: Self.ocrMaxPixelSize) else { return }

        // Cheap dedupe: if the screen looks roughly the same as the previous frame
        // (Hamming distance within tolerance — tolerates cursor moves / clock ticks /
        // single-pixel changes), re-use its text instead of re-running Vision.
        let hash = Self.averageHash(cgImage)
        if let prev = lastHash, (prev ^ hash).nonzeroBitCount <= Self.hashTolerance,
           let cached = lastText, !cached.isEmpty {
            try? Database.shared.setOCR(frameID: frameID, text: cached)
            return
        }

        let request = VNRecognizeTextRequest()
        // .fast is roughly 3-5x cheaper than .accurate on Apple Silicon and produces
        // near-identical output for body text in screenshots — what we mostly OCR.
        // The accuracy delta only matters for stylized / very low-contrast text.
        request.recognitionLevel = .fast
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

        // Update the dedupe state regardless — even an empty result is "what this frame yields".
        lastHash = hash
        lastText = text

        guard !text.isEmpty else { return }
        try? Database.shared.setOCR(frameID: frameID, text: text)
    }

    /// Loads `url` as a CGImage with max edge clamped to `maxPixelSize`. Uses
    /// `CGImageSourceCreateThumbnailAtIndex`, which decodes only what's needed.
    private static func loadDownsampled(at url: URL, maxPixelSize: Int) -> CGImage? {
        let sourceOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, sourceOpts) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// 64-bit perceptual hash via 8×8 grayscale average comparison. Stable enough for
    /// "is the screen visually identical to the last frame" while ignoring tiny timestamp
    /// changes / cursor movement.
    private static func averageHash(_ cgImage: CGImage) -> UInt64 {
        let width = 8
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let total = pixels.reduce(0) { $0 + Int($1) }
        let avg = total / pixels.count
        var hash: UInt64 = 0
        for (i, p) in pixels.enumerated() where Int(p) > avg {
            hash |= UInt64(1) << UInt64(i)
        }
        return hash
    }
}
