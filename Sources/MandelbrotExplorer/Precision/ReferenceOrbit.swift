import Foundation

/// A single high-precision orbit Z_0..Z_n computed once (sequentially, on
/// CPU, using arbitrary-precision `Expansion` arithmetic) that every pixel's
/// perturbation iteration is measured against. Downcast to `Double` for
/// storage: the orbit values themselves are O(1) in magnitude, so plain
/// hardware doubles carry plenty of *relative* precision for them — only the
/// reference *center coordinate* needed the expensive arbitrary-precision math.
struct ReferenceOrbit {
    var points: [SIMD2<Double>]
    var escapedAtIteration: Int?

    /// `start` is the orbit's z_0 (arbitrary precision); `addedConstant` is
    /// added every iteration. For Mandelbrot, `start` is always `.zero` and
    /// `addedConstant` is the c value being explored (one per reference).
    /// For Julia, `start` is the z0 value being explored and `addedConstant`
    /// is the fixed, shared `c` parameter -- the two families are the same
    /// recurrence with these roles swapped.
    static func compute(
        start: ComplexExpansion = .zero,
        addedConstant: ComplexExpansion,
        maxIterations: Int,
        escapeRadiusSquared: Double,
        precision: Int
    ) -> ReferenceOrbit {
        var z = start
        var points: [SIMD2<Double>] = []
        points.reserveCapacity(maxIterations + 1)
        points.append(start.approximateValue)

        var escapedAt: Int? = nil
        let hardCap = max(escapeRadiusSquared * 4, 1e6)

        var n = 0
        while n < maxIterations {
            z = z.squared(precision: precision).adding(addedConstant, precision: precision)
            let approx = z.approximateValue
            points.append(approx)
            n += 1
            let mag2 = approx.x * approx.x + approx.y * approx.y
            if mag2 > hardCap {
                escapedAt = n
                break
            }
        }
        return ReferenceOrbit(points: points, escapedAtIteration: escapedAt)
    }
}
