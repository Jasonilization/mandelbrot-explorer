import Foundation

/// Ray-march quality tiers for the Mandelbulb explorer. Higher tiers spend
/// more ray-marching steps and DE iterations per pixel and add ambient
/// occlusion / soft shadows; all of it re-renders progressively (reduced
/// automatically while the camera is moving, full quality once it settles --
/// see `MandelbulbRenderer.isAnimating`).
enum MandelbulbQuality: String, CaseIterable, Identifiable, Hashable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case ultra = "Ultra"

    var id: String { rawValue }

    /// Max ray-march steps per pixel before giving up and treating it as background.
    var maxRaySteps: Int {
        switch self {
        case .low: 64
        case .medium: 96
        case .high: 128
        case .ultra: 192
        }
    }

    var aoEnabled: Bool { self != .low }
    var shadowsEnabled: Bool { self == .high || self == .ultra }

    /// Multiplies `MandelbulbRenderer.renderResolution` -- lets Ultra
    /// supersample a bit for extra smoothness on fast GPUs.
    var resolutionScale: Double {
        switch self {
        case .low: 0.6
        case .medium: 0.85
        case .high: 1.0
        case .ultra: 1.35
        }
    }

    var helpText: String {
        switch self {
        case .low: "Fast preview: fewer ray-march steps, no ambient occlusion or shadows."
        case .medium: "Balanced: ambient occlusion on, shadows off."
        case .high: "Better detail: ambient occlusion and soft shadows both on."
        case .ultra: "Slow but beautiful: more ray-march steps, supersampled, full lighting."
        }
    }
}
