import Foundation

/// CPU, multithreaded (GCD across all performance cores) deep-zoom renderer
/// using perturbation theory: a single arbitrary-precision reference orbit is
/// computed once, and every pixel only tracks its tiny delta from that orbit
/// using plain hardware `Double`. Deltas stay small in magnitude, so ordinary
/// double relative precision (~15-16 digits) is sufficient however deep the
/// zoom — the catastrophic cancellation that breaks naive float64 iteration
/// never occurs because we never compute a large-minus-large-nearly-equal
/// subtraction.
///
/// Two further optimizations layer on top of the base algorithm:
///  - Series approximation (`SeriesApproximation`) lets every pixel skip the
///    iterations that are still identical (to within tolerance) across the
///    whole frame, rather than looping from n=0.
///  - The first pass tiles the image and reports each tile back via
///    `onTileComplete` as soon as it's done, so a slow deep-zoom render
///    fills in progressively instead of the display staying frozen on the
///    old frame until the entire buffer is ready.
enum Perturbation {

    /// A finished rectangular region, in the same row-major layout as the
    /// full-frame `Result.values`, ready to be blitted straight into the
    /// iteration texture without waiting for the rest of the image.
    struct TileUpdate {
        let originX: Int
        let originY: Int
        let width: Int
        let height: Int
        let values: [Float]
    }

    struct Result {
        /// Smooth (continuous) escape iteration count per pixel, or -1 for
        /// points that never escaped (interior).
        var values: [Float]
        /// How many leading iterations series approximation let every pixel
        /// skip on the primary reference orbit. 0 means SA didn't engage
        /// (e.g. too shallow a zoom for it to pay off).
        var seriesApproximationSkip: Int
        /// Length of the primary high-precision reference orbit actually
        /// computed. Exposed purely for the UI's precision/quality indicators.
        var referenceOrbitIterations: Int
    }

    /// Tile edge length in pixels for the progressive first pass. Small
    /// enough that a deep, slow render visibly fills in as it goes; large
    /// enough that per-tile overhead (allocation, the main-actor hop to
    /// paint it) stays negligible next to the per-pixel iteration cost.
    private static let tileSize = 128

    static func render(
        centerDeep: ComplexExpansion,
        pixelSize: Double,
        width: Int,
        height: Int,
        maxIterations: Int,
        escapeRadius: Double,
        precision: Int,
        isCancelled: @Sendable () -> Bool = { false },
        onTileComplete: (@Sendable (TileUpdate) -> Void)? = nil
    ) -> Result {
        let escapeR2 = escapeRadius * escapeRadius
        var values = [Float](repeating: -1, count: width * height)
        let halfW = Double(width) / 2
        let halfH = Double(height) / 2

        // Precompute each pixel's exact (small, double-safe) offset from the
        // ORIGINAL view center in fractal-plane units.
        var dcx = [Double](repeating: 0, count: width)
        var dcy = [Double](repeating: 0, count: height)
        for x in 0..<width { dcx[x] = (Double(x) - halfW) * pixelSize }
        for y in 0..<height { dcy[y] = (halfH - Double(y)) * pixelSize }

        var pending = Array(0..<(width * height))
        var referenceOffset = SIMD2<Double>(0, 0) // reference point's offset from original center
        var roundsLeft = 4
        var firstRoundSkip = 0
        var firstRoundOrbitLength = 0
        let debugSample = ProcessInfo.processInfo.environment["PERTURBATION_DEBUG"] != nil
        var isFirstRound = true

        while roundsLeft > 0 && !pending.isEmpty && !isCancelled() {
            roundsLeft -= 1
            let referenceCenter = centerDeep.adding(
                ComplexExpansion(re: Expansion(referenceOffset.x), im: Expansion(referenceOffset.y)),
                precision: precision
            )
            let orbit = ReferenceOrbit.compute(
                center: referenceCenter,
                maxIterations: maxIterations,
                escapeRadiusSquared: escapeR2,
                precision: precision
            )
            let refPoints = orbit.points
            let refCount = refPoints.count

            // -1: SA's skip point becomes the resumed per-pixel loop's first
            // reference index (refPoints[skipIterations]), which must stay
            // strictly inside the orbit -- refCount itself is one past the
            // last point ReferenceOrbit actually computed.
            let validIterationCount = min(maxIterations, refCount - 1)
            let maxDcxAbs = max(abs(dcx[0] - referenceOffset.x), abs(dcx[width - 1] - referenceOffset.x))
            let maxDcyAbs = max(abs(dcy[0] - referenceOffset.y), abs(dcy[height - 1] - referenceOffset.y))
            let maxDeltaC = (maxDcxAbs * maxDcxAbs + maxDcyAbs * maxDcyAbs).squareRoot()
            let sa = SeriesApproximation.compute(
                referencePoints: refPoints,
                validIterationCount: validIterationCount,
                maxDeltaC: maxDeltaC
            )
            if isFirstRound {
                firstRoundSkip = sa.skipIterations
                firstRoundOrbitLength = refCount
            }

            // Core per-pixel recurrence, shared by both the tiled first pass
            // and the flat glitch-retry passes below. δz starts wherever SA
            // leaves off instead of at n=0 -- everything before that point
            // is, by construction, identical across every pixel in this frame.
            func computePixel(x: Int, y: Int, idx: Int) -> (value: Float, glitched: Bool) {
                let dcRe = dcx[x] - referenceOffset.x
                let dcIm = dcy[y] - referenceOffset.y

                var dzRe = 0.0, dzIm = 0.0
                var n = 0
                if sa.skipIterations > 0 {
                    let z0 = sa.evaluate(dcRe: dcRe, dcIm: dcIm)
                    dzRe = z0.x
                    dzIm = z0.y
                    n = sa.skipIterations
                }

                var glitched = false
                var escaped = false
                var finalMag2 = 0.0

                while n < maxIterations {
                    guard n < refCount else { glitched = true; break }
                    let Z = refPoints[n]
                    let zRe = Z.x + dzRe
                    let zIm = Z.y + dzIm
                    let mag2 = zRe * zRe + zIm * zIm
                    if mag2 > escapeR2 {
                        escaped = true
                        finalMag2 = mag2
                        n += 1
                        break
                    }
                    let dzMag2 = dzRe * dzRe + dzIm * dzIm
                    // Pauldelbrot glitch criterion: reference and true orbit
                    // have effectively coincided, so continuing would use a
                    // near-zero reference magnitude as a divisor of trust --
                    // bail out and re-reference.
                    if dzMag2 > 0, mag2 < dzMag2 * 1e-12 {
                        glitched = true
                        break
                    }
                    let newDzRe = 2 * (Z.x * dzRe - Z.y * dzIm) + (dzRe * dzRe - dzIm * dzIm) + dcRe
                    let newDzIm = 2 * (Z.x * dzIm + Z.y * dzRe) + 2 * dzRe * dzIm + dcIm
                    dzRe = newDzRe
                    dzIm = newDzIm
                    n += 1
                }

                if debugSample, idx == 0 || idx == (width * height) / 2 || idx == width * height - 1 {
                    FileHandle.standardError.write("px idx=\(idx) x=\(x) y=\(y) dcRe=\(dcRe) dcIm=\(dcIm) n=\(n) escaped=\(escaped) glitched=\(glitched) skip=\(sa.skipIterations) finalDzRe=\(dzRe) finalDzIm=\(dzIm)\n".data(using: .utf8)!)
                }

                if glitched {
                    return (-1, true)
                } else if escaped {
                    let logZn = log(finalMag2) * 0.5
                    let nu = log(logZn / log(2)) / log(2)
                    return (Float(Double(n) + 1 - nu), false)
                } else {
                    return (-1, false)
                }
            }

            let glitchLock = NSLock()
            var nextPending: [Int] = []

            if isFirstRound {
                // Full frame, not yet computed: tile it so the caller can
                // paint progress as each tile lands instead of waiting for
                // the whole image.
                let tilesX = (width + tileSize - 1) / tileSize
                let tilesY = (height + tileSize - 1) / tileSize
                let tileCount = tilesX * tilesY

                values.withUnsafeMutableBufferPointer { out in
                    DispatchQueue.concurrentPerform(iterations: tileCount) { tileIdx in
                        if isCancelled() { return }
                        let tx = tileIdx % tilesX
                        let ty = tileIdx / tilesX
                        let x0 = tx * tileSize
                        let y0 = ty * tileSize
                        let tw = min(tileSize, width - x0)
                        let th = min(tileSize, height - y0)

                        var tileValues = [Float](repeating: -1, count: tw * th)
                        var localGlitched: [Int] = []
                        for ly in 0..<th {
                            let y = y0 + ly
                            for lx in 0..<tw {
                                let x = x0 + lx
                                let idx = y * width + x
                                let (value, glitched) = computePixel(x: x, y: y, idx: idx)
                                if glitched {
                                    localGlitched.append(idx)
                                } else {
                                    out[idx] = value
                                    tileValues[ly * tw + lx] = value
                                }
                            }
                        }
                        if !localGlitched.isEmpty {
                            glitchLock.lock()
                            nextPending.append(contentsOf: localGlitched)
                            glitchLock.unlock()
                        }
                        onTileComplete?(TileUpdate(originX: x0, originY: y0, width: tw, height: th, values: tileValues))
                    }
                }
            } else {
                // A small, scattered set of previously-glitched pixels:
                // tiling buys nothing here, so retry them directly.
                pending.withUnsafeBufferPointer { pendingBuf in
                    values.withUnsafeMutableBufferPointer { out in
                        DispatchQueue.concurrentPerform(iterations: pendingBuf.count) { i in
                            let idx = pendingBuf[i]
                            let x = idx % width
                            let y = idx / width
                            let (value, glitched) = computePixel(x: x, y: y, idx: idx)
                            if glitched {
                                glitchLock.lock()
                                nextPending.append(idx)
                                glitchLock.unlock()
                            } else {
                                out[idx] = value
                            }
                        }
                    }
                }
                // Glitch fixups are scattered across the frame, so report
                // progress as one full-frame refresh rather than trying to
                // reconstruct per-tile rects for a handful of stray pixels.
                onTileComplete?(TileUpdate(originX: 0, originY: 0, width: width, height: height, values: values))
            }

            if debugSample {
                FileHandle.standardError.write("round refCount=\(refCount) refEscapedAt=\(String(describing: orbit.escapedAtIteration)) saSkip=\(sa.skipIterations) pending=\(pending.count) glitched=\(nextPending.count) roundsLeft=\(roundsLeft)\n".data(using: .utf8)!)
            }

            isFirstRound = false

            if nextPending.isEmpty || roundsLeft == 0 {
                // Give up gracefully: paint any still-glitched pixels using
                // their last reference's iteration depth as an approximation
                // rather than leaving them uninitialized.
                for idx in nextPending { values[idx] = Float(maxIterations) }
                if !nextPending.isEmpty {
                    onTileComplete?(TileUpdate(originX: 0, originY: 0, width: width, height: height, values: values))
                }
                break
            }

            // Re-reference on the first remaining glitched pixel and retry
            // just that subset.
            let seed = nextPending[0]
            let sx = seed % width
            let sy = seed / width
            referenceOffset = SIMD2(dcx[sx], dcy[sy])
            pending = nextPending
        }

        return Result(values: values, seriesApproximationSkip: firstRoundSkip, referenceOrbitIterations: firstRoundOrbitLength)
    }
}
