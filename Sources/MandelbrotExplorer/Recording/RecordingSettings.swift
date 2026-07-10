import CoreGraphics

/// User-adjustable knobs for a recorded zoom journey.
struct RecordingSettings {
    enum Resolution: String, CaseIterable, Identifiable, Hashable {
        case hd720 = "1280 × 720"
        case hd1080 = "1920 × 1080 (HD)"
        case uhd4k = "3840 × 2160 (4K)"

        var id: String { rawValue }

        var size: CGSize {
            switch self {
            case .hd720: CGSize(width: 1280, height: 720)
            case .hd1080: CGSize(width: 1920, height: 1080)
            case .uhd4k: CGSize(width: 3840, height: 2160)
            }
        }
    }

    var resolution: Resolution = .hd1080
    var fps: Int = 30
    var durationSeconds: Double = 15
    var showZoomOverlay: Bool = true

    var totalFrames: Int { max(1, Int((durationSeconds * Double(fps)).rounded())) }
}
