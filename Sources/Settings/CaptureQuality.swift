import Foundation

enum CaptureQuality: Int, CaseIterable, Identifiable, Hashable {
    case tiny   = 0
    case low    = 1
    case medium = 2
    case high   = 3
    case max    = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .tiny:   return "Tiny"
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        case .max:    return "Max"
        }
    }

    /// Maximum width in pixels; capture is downsampled to fit.
    var maxWidth: Double {
        switch self {
        case .tiny:   return 960
        case .low:    return 1280
        case .medium: return 1600
        case .high:   return 2000
        case .max:    return 2400
        }
    }

    /// HEIC compression quality, 0.0…1.0.
    /// HEIC is more efficient than JPEG, so equivalent visual quality numbers run lower.
    var imageQuality: Double {
        switch self {
        case .tiny:   return 0.45
        case .low:    return 0.50
        case .medium: return 0.55
        case .high:   return 0.65
        case .max:    return 0.75
        }
    }

    /// Empirical average size per HEIC frame in kilobytes, used for the disk-usage estimate.
    /// Real frames vary roughly 0.5x–2x depending on screen content.
    var estimatedKBPerFrame: Double {
        switch self {
        case .tiny:   return 12
        case .low:    return 20
        case .medium: return 35
        case .high:   return 65
        case .max:    return 130
        }
    }
}
