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
    /// Raw value of `ColorMode`: 0 escape time, 1 distance estimation, 2 orbit trap.
    var colorMode: UInt32
    /// 0/1. Only affects escape-time mode -- continuous vs. banded integer count.
    var smoothingEnabled: UInt32
    /// Raw value of `OrbitTrapType`: 0 circle, 1 line, 2 cross, 3 custom point.
    var trapType: UInt32
    /// Circle radius / line angle (radians) / custom point x, depending on trapType.
    var trapParamX: Float
    /// Unused for circle/line / custom point y, depending on trapType.
    var trapParamY: Float

    init(centerHi: SIMD2<Float>, centerLo: SIMD2<Float>, spanX: Float, aspect: Float,
         width: UInt32, height: UInt32, maxIterations: UInt32, escapeRadiusSq: Float,
         colorMode: UInt32 = 0, smoothingEnabled: UInt32 = 1,
         trapType: UInt32 = 0, trapParamX: Float = 0.5, trapParamY: Float = 0) {
        self.centerHi = centerHi
        self.centerLo = centerLo
        self.spanX = spanX
        self.aspect = aspect
        self.width = width
        self.height = height
        self.maxIterations = maxIterations
        self.escapeRadiusSq = escapeRadiusSq
        self.colorMode = colorMode
        self.smoothingEnabled = smoothingEnabled
        self.trapType = trapType
        self.trapParamX = trapParamX
        self.trapParamY = trapParamY
    }
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
    var interiorR: Float
    var interiorG: Float
    var interiorB: Float
    /// 0/1. Adds a cheap relief-shading pass using the scalar field as a
    /// fake heightmap, so boundary structure reads as more three-dimensional.
    var shadingEnabled: UInt32
    var lightAzimuth: Float
    var lightElevation: Float
    var shadingStrength: Float
}

/// Splits a `Double` into a compensated float32 (hi, lo) pair such that
/// `Double(hi) + Double(lo)` reconstructs the original value to full double
/// precision. Used to feed the GPU double-double tier.
func splitDoubleToFloatPair(_ v: Double) -> (Float, Float) {
    let hi = Float(v)
    let lo = Float(v - Double(hi))
    return (hi, lo)
}
