import Foundation

/// Which per-pixel scalar drives the palette lookup. Rendered identically
/// (same palette, same shading pass) across all three precision tiers --
/// float32 GPU, double-double GPU, and CPU perturbation -- each tier just
/// computes this scalar its own way. Raw values are mirrored exactly by the
/// `colorMode` field in both `FractalParams` (ShaderTypes.swift) and the
/// Metal-side struct, so this is a plain `UInt32`-backed enum rather than
/// something Swift-only.
enum ColorMode: UInt32, CaseIterable, Identifiable, Hashable {
    /// Classic escape-time: how many iterations before |z| passed the
    /// escape radius, optionally smoothed into a continuous value.
    case escapeTime = 0
    /// Analytic distance estimation: how close this exterior point is to
    /// the fractal boundary, via |z|·log|z|/|dz/dc|. Produces crisp,
    /// detail-following contours independent of iteration banding.
    case distanceEstimation = 1
    /// Orbit trap: the closest the orbit ever came to a chosen shape
    /// (circle/line/cross/point), colored across the *whole* set (interior
    /// included) rather than only the exterior.
    case orbitTrap = 2

    var id: UInt32 { rawValue }

    var label: String {
        switch self {
        case .escapeTime: "Escape Time"
        case .distanceEstimation: "Distance Estimation"
        case .orbitTrap: "Orbit Trap"
        }
    }

    var helpText: String {
        switch self {
        case .escapeTime: "Colors by how many iterations a point takes to escape -- the classic Mandelbrot look."
        case .distanceEstimation: "Colors by estimated distance to the fractal boundary, producing crisp contour-like detail independent of iteration banding."
        case .orbitTrap: "Colors by how close each point's orbit passes to a chosen shape, painted across the whole set rather than just the boundary -- the richly patterned 'orbit trap' look."
        }
    }
}

/// Shape an orbit trap measures distance to. Raw values mirrored by the
/// `trapType` field in `FractalParams`/the Metal struct.
enum OrbitTrapType: UInt32, CaseIterable, Identifiable, Hashable {
    case circle = 0
    case line = 1
    case cross = 2
    case custom = 3

    var id: UInt32 { rawValue }

    var label: String {
        switch self {
        case .circle: "Circle"
        case .line: "Line"
        case .cross: "Cross"
        case .custom: "Custom Point"
        }
    }
}

/// User-adjustable orbit trap parameters. `scale` is the circle's radius;
/// `angleDegrees` is the line trap's angle; `customX`/`customY` are the
/// custom point trap's position, all in the fractal's own coordinate units
/// (roughly [-2, 2]).
struct OrbitTrapSettings: Equatable, Hashable {
    var type: OrbitTrapType = .circle
    /// A tight default: a loose/large trap radius is satisfied by almost any
    /// orbit's natural excursion, which washes the whole image out toward a
    /// single flat color -- especially at deep zoom, where every pixel's
    /// orbit already ranges from near-zero up past the escape radius.
    var scale: Double = 0.15
    var angleDegrees: Double = 0
    var customX: Double = 0.3
    var customY: Double = 0.3

    static let `default` = OrbitTrapSettings()
}
