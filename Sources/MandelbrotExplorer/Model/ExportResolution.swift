import CoreGraphics

/// Selectable output size for "Save Image…", mirroring the resolution
/// picker `RecordingSettings` already offers for video export.
struct ExportResolution: Identifiable, Hashable {
    let id: String
    let label: String
    let size: CGSize

    static let all: [ExportResolution] = [
        ExportResolution(id: "hd720", label: "1280 × 720", size: CGSize(width: 1280, height: 720)),
        ExportResolution(id: "hd1080", label: "1920 × 1080 (HD)", size: CGSize(width: 1920, height: 1080)),
        ExportResolution(id: "qhd1440", label: "2560 × 1440 (QHD)", size: CGSize(width: 2560, height: 1440)),
        ExportResolution(id: "uhd4k", label: "3840 × 2160 (4K)", size: CGSize(width: 3840, height: 2160)),
        ExportResolution(id: "uhd8k", label: "7680 × 4320 (8K)", size: CGSize(width: 7680, height: 4320)),
    ]

    static let `default` = all[2]
}
