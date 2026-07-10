import simd

/// Mirrors `FractalParams` in Shaders.metal field-for-field. `SIMD2<Float>`
/// and MSL's `float2` are the documented-compatible bridging pair (8 bytes,
/// 8-byte aligned on both sides), so this struct's layout matches without
/// needing manual padding.
struct FractalParams {
    var centerHi: SIMD2<Float>
    var centerLo: SIMD2<Float>
    var spanX: Float
    var aspect: Float
    var width: UInt32
    var height: UInt32
    var maxIterations: UInt32
    var escapeRadiusSq: Float
}

/// Mirrors `PaletteParams` in Shaders.metal. All-scalar (no embedded
/// vector types) so there is no cross-language struct-padding risk at all.
struct PaletteParams {
    var stopCount: UInt32
    var colorScale: Float
    var colorOffset: Float
    var sourceWidth: UInt32
    var sourceHeight: UInt32
    var outWidth: UInt32
    var outHeight: UInt32
}

/// Splits a `Double` into a compensated float32 (hi, lo) pair such that
/// `Double(hi) + Double(lo)` reconstructs the original value to full double
/// precision. Used to feed the GPU double-double tier.
func splitDoubleToFloatPair(_ v: Double) -> (Float, Float) {
    let hi = Float(v)
    let lo = Float(v - Double(hi))
    return (hi, lo)
}
