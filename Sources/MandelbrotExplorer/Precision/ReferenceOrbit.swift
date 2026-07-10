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

    static func compute(
        center: ComplexExpansion,
        maxIterations: Int,
        escapeRadiusSquared: Double,
        precision: Int
    ) -> ReferenceOrbit {
        var z = ComplexExpansion.zero
        var points: [SIMD2<Double>] = []
        points.reserveCapacity(maxIterations + 1)
        points.append(.zero)

        var escapedAt: Int? = nil
        let hardCap = max(escapeRadiusSquared * 4, 1e6)

        var n = 0
        while n < maxIterations {
            z = z.squared(precision: precision).adding(center, precision: precision)
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
