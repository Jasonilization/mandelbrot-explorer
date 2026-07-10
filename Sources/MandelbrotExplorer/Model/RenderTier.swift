import Foundation

/// The three precision strategies used to evaluate z -> z^2 + c, selected
/// automatically by zoom depth. Apple GPUs have no native `double`, so the
/// jump from "fast" to "exact" happens twice: once by emulating extra
/// mantissa bits on the GPU, and again by moving off the GPU entirely once
/// even that isn't enough.
enum RenderTier: String, CaseIterable {
    /// Direct iteration in native float32 on the GPU. Breaks down (visible
    /// pixelation / block artifacts) once the pixel spacing is a similar
    /// magnitude to float32's ~7 decimal digits of precision.
    case float32

    /// Direct iteration using emulated double-double arithmetic (two
    /// error-compensated float32s per component) on the GPU. Roughly
    /// equivalent to real hardware float64 (~15-16 digits), fully parallel.
    case doubleDouble

    /// Perturbation theory: one arbitrary-precision reference orbit computed
    /// on CPU, every pixel iterates a small delta from it in plain double
    /// precision, multithreaded across CPU cores. Effectively unbounded zoom.
    case perturbation

    /// Zoom factor is defined as (initial view width) / (current view width).
    static func select(forZoom zoom: Double) -> RenderTier {
        if zoom < 5e4 { return .float32 }
        if zoom < 3e13 { return .doubleDouble }
        return .perturbation
    }

    var label: String {
        switch self {
        case .float32: return "Float32 (GPU)"
        case .doubleDouble: return "Double-Double (GPU)"
        case .perturbation: return "Perturbation (CPU, arbitrary precision)"
        }
    }
}
