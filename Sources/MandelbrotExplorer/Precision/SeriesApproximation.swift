import Foundation

@inline(__always) private func cmul(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SIMD2<Double> {
    SIMD2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x)
}

@inline(__always) private func cadd(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SIMD2<Double> {
    SIMD2(a.x + b.x, a.y + b.y)
}

/// Bulk-skip-ahead for perturbation iteration. Every pixel's delta orbit
/// δz_n = z_n - Z_n obeys δz_{n+1} = 2·Z_n·δz_n + δz_n² + δc, and since δc is
/// just a per-pixel constant, δz_n is exactly a power series in δc:
/// δz_n(δc) = Σ_j A_n^(j)·δc^j. The coefficients A_n^(j) depend only on the
/// reference orbit, not on any individual pixel, so they can be walked
/// forward once (this type) and then evaluated per pixel in O(order) instead
/// of looping n from 0 -- letting every pixel jump straight to
/// `skipIterations` and iterate only the remaining, genuinely
/// pixel-dependent tail.
///
/// The walk stops the moment the highest retained term could plausibly
/// exceed `tolerance` relative to the reference orbit's own magnitude at the
/// worst-case (frame-corner) δc: past that point the truncated series is no
/// longer trustworthy, and every pixel falls back to iterating that tail by
/// hand exactly as before.
struct SeriesApproximation {
    /// Order 8 is the standard sweet spot in the fractal-rendering
    /// literature (e.g. Kalles Fraktaler, FractalShades): the per-iteration
    /// convolution cost is O(order²), negligible next to `maxIterations`,
    /// while doubling the order roughly doubles how many iterations can
    /// safely be skipped.
    static let order = 8

    /// Coefficients A^(1)...A^(order) at `skipIterations`, ascending order
    /// (coefficients[0] is the δc¹ term).
    var coefficients: [SIMD2<Double>]
    var skipIterations: Int

    static let none = SeriesApproximation(coefficients: [], skipIterations: 0)

    static func compute(
        referencePoints: [SIMD2<Double>],
        validIterationCount: Int,
        maxDeltaC: Double,
        tolerance: Double = 1e-6
    ) -> SeriesApproximation {
        guard validIterationCount > 1, maxDeltaC > 0 else { return .none }
        let k = order
        var A = [SIMD2<Double>](repeating: SIMD2(0, 0), count: k)
        var lastGood = A
        var lastGoodN = 0

        var n = 0
        while n < validIterationCount {
            let Z = referencePoints[n]
            var newA = [SIMD2<Double>](repeating: SIMD2(0, 0), count: k)
            // j=1: δz picks up a bare δc term every iteration, plus the
            // existing series folded through the reference orbit (2·Z·δz).
            let twoZA0 = cadd(cmul(Z, A[0]), cmul(Z, A[0]))
            newA[0] = cadd(twoZA0, SIMD2(1, 0))
            if k > 1 {
                for j in 2...k {
                    // δz² contributes a convolution of the existing series
                    // with itself at every order below j.
                    var conv = SIMD2<Double>(0, 0)
                    for p in 1..<j {
                        let q = j - p
                        conv = cadd(conv, cmul(A[p - 1], A[q - 1]))
                    }
                    let twoZAj = cadd(cmul(Z, A[j - 1]), cmul(Z, A[j - 1]))
                    newA[j - 1] = cadd(twoZAj, conv)
                }
            }
            A = newA
            n += 1

            let lastCoeffMag = (A[k - 1].x * A[k - 1].x + A[k - 1].y * A[k - 1].y).squareRoot()
            let lastTermMag = lastCoeffMag * pow(maxDeltaC, Double(k))
            let refMag = max((Z.x * Z.x + Z.y * Z.y).squareRoot(), 1e-300)
            if lastTermMag < tolerance * refMag {
                lastGood = A
                lastGoodN = n
            } else {
                break
            }
        }
        // Below a handful of iterations the per-pixel evaluation overhead
        // isn't worth it -- just let the normal loop start from zero.
        guard lastGoodN > 8 else { return .none }
        return SeriesApproximation(coefficients: lastGood, skipIterations: lastGoodN)
    }

    /// Evaluate δz(δc) at `skipIterations` via Horner's method.
    @inline(__always) func evaluate(dcRe: Double, dcIm: Double) -> SIMD2<Double> {
        guard !coefficients.isEmpty else { return SIMD2(0, 0) }
        let dc = SIMD2(dcRe, dcIm)
        var acc = coefficients[coefficients.count - 1]
        var i = coefficients.count - 2
        while i >= 0 {
            acc = cadd(coefficients[i], cmul(dc, acc))
            i -= 1
        }
        return cmul(dc, acc)
    }

    /// Evaluate d(δz)/d(δc) at `skipIterations`, analytically differentiating
    /// the same power series `evaluate` uses (term j·A^(j)·δc^(j-1)). Since
    /// z_n = Z_n + δz_n and the reference orbit Z_n doesn't depend on the
    /// per-pixel δc at all, this is exactly d(z)/d(c) -- what distance
    /// estimation needs -- without which every pixel would have to seed its
    /// derivative accumulator at 0 right where SA jumps ahead, silently
    /// discarding however much sensitivity built up over the skipped
    /// iterations and making the estimate wildly wrong at any real depth.
    @inline(__always) func evaluateDerivative(dcRe: Double, dcIm: Double) -> SIMD2<Double> {
        guard !coefficients.isEmpty else { return SIMD2(0, 0) }
        let dc = SIMD2(dcRe, dcIm)
        let lastIndex = coefficients.count - 1
        var acc = SIMD2(Double(lastIndex + 1) * coefficients[lastIndex].x, Double(lastIndex + 1) * coefficients[lastIndex].y)
        var i = lastIndex - 1
        while i >= 0 {
            let term = SIMD2(Double(i + 1) * coefficients[i].x, Double(i + 1) * coefficients[i].y)
            acc = cadd(term, cmul(dc, acc))
            i -= 1
        }
        return acc
    }
}
