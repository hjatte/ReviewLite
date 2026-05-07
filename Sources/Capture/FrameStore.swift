import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Stores each captured frame as a standalone JPEG on disk.
/// Trades some compression efficiency for trivial readability — JPGs are
/// readable the moment they're written, no AVAssetWriter shadow-file games.
actor FrameStore {
    struct AppendResult {
        var relativePath: String
    }

    private let ciContext: CIContext = {
        let opts: [CIContextOption: Any] = [.useSoftwareRenderer: false]
        return CIContext(options: opts)
    }()

    func append(pixelBuffer: CVPixelBuffer, capturedAt: Date) async throws -> AppendResult {
        let preset = SettingsStore.currentCaptureQuality

        let day = Self.dayString(capturedAt)
        let stamp = Self.timeStamp(capturedAt)
        let dir = Database.shared.framesDirectory.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = "\(stamp).heic"
        let url = dir.appendingPathComponent(filename)
        let relative = "\(day)/\(filename)"

        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let scaled = Self.scaled(ci, maxWidth: CGFloat(preset.maxWidth))

        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else {
            throw NSError(domain: "FrameStore", code: -1, userInfo: [NSLocalizedDescriptionKey: "CIContext failed to render"])
        }

        // Hardware-accelerated HEIC on Apple Silicon. ~50% smaller than JPEG at equivalent
        // perceived quality. Existing .jpg files in the data dir keep working — NSImage
        // reads either format, and the paths stored in DB include each frame's extension.
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw NSError(domain: "FrameStore", code: -2, userInfo: [NSLocalizedDescriptionKey: "Could not create HEIC destination"])
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: CGFloat(preset.imageQuality)]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "FrameStore", code: -3, userInfo: [NSLocalizedDescriptionKey: "HEIC finalize failed"])
        }

        return AppendResult(relativePath: relative)
    }

    private static func scaled(_ image: CIImage, maxWidth: CGFloat) -> CIImage {
        let width = image.extent.width
        guard width > maxWidth else { return image }
        let scale = maxWidth / width
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

    private static func timeStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HHmmss_SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
}
