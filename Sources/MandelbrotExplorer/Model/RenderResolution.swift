import Foundation

/// User-selectable internal render scale for the live canvas, independent of
/// the actual window/drawable size. Below 1x trades sharpness for frame rate
/// on slower Macs or very large windows; above 1x supersamples (the fast
/// preview path already downsamples through a bilinear palette pass, so
/// values > 1 just make that same pass do anti-aliasing instead of upscaling).
enum RenderResolution: String, CaseIterable, Identifiable, Hashable {
    case performance = "Performance (0.5×)"
    case balanced = "Balanced (0.75×)"
    case native = "Native (1×)"
    case high = "High (1.5×)"
    case ultra = "Ultra (2× Supersampled)"

    var id: String { rawValue }

    var scale: Double {
        switch self {
        case .performance: 0.5
        case .balanced: 0.75
        case .native: 1.0
        case .high: 1.5
        case .ultra: 2.0
        }
    }

    var shortLabel: String {
        switch self {
        case .performance: "0.5×"
        case .balanced: "0.75×"
        case .native: "1×"
        case .high: "1.5×"
        case .ultra: "2×"
        }
    }
}
