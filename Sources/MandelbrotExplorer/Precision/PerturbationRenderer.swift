import Foundation

/// CPU, multithreaded (Swift Concurrency / GCD across all performance cores)
/// deep-zoom renderer using perturbation theory: a single arbitrary-precision
/// reference orbit is computed once, and every pixel only tracks its tiny
/// delta from that orbit using plain hardware `Double`. Deltas stay small in
/// magnitude, so ordinary double relative precision (~15-16 digits) is
/// sufficient however deep the zoom — the catastrophic cancellation that
/// breaks naive float64 iteration never occurs because we never compute a
/// large-minus-large-nearly-equal subtraction.
enum Perturbation {

    /// Output is a "mu" buffer: smooth (continuous) escape iteration count
    /// per pixel, or -1 for points that never escaped (interior).
    static func render(
        centerDeep: ComplexExpansion,
        pixelSize: Double,
        width: Int,
        height: Int,
        maxIterations: Int,
        escapeRadius: Double,
        precision: Int,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [Float] {
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
        let debugSample = ProcessInfo.processInfo.environment["PERTURBATION_DEBUG"] != nil

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

            let glitchLock = NSLock()
            var nextPending: [Int] = []

            pending.withUnsafeBufferPointer { pendingBuf in
                values.withUnsafeMutableBufferPointer { out in
                    DispatchQueue.concurrentPerform(iterations: pendingBuf.count) { i in
                        let idx = pendingBuf[i]
                        let x = idx % width
                        let y = idx / width
                        let dcRe = dcx[x] - referenceOffset.x
                        let dcIm = dcy[y] - referenceOffset.y

                        var dzRe = 0.0, dzIm = 0.0
                        var n = 0
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
                            // Pauldelbrot glitch criterion: reference and true
                            // orbit have effectively coincided, so continuing
                            // would use a near-zero reference magnitude as a
                            // divisor of trust -- bail out and re-reference.
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

                        if glitched {
                            glitchLock.lock()
                            nextPending.append(idx)
                            glitchLock.unlock()
                        } else if escaped {
                            let logZn = log(finalMag2) * 0.5
                            let nu = log(logZn / log(2)) / log(2)
                            out[idx] = Float(Double(n) + 1 - nu)
                        } else {
                            out[idx] = -1
                        }

                        if debugSample, idx == 0 || idx == (width * height) / 2 || idx == width * height - 1 {
                            glitchLock.lock()
                            FileHandle.standardError.write("px idx=\(idx) x=\(x) y=\(y) dcRe=\(dcRe) dcIm=\(dcIm) n=\(n) escaped=\(escaped) glitched=\(glitched) finalDzRe=\(dzRe) finalDzIm=\(dzIm)\n".data(using: .utf8)!)
                            glitchLock.unlock()
                        }
                    }
                }
            }

            if ProcessInfo.processInfo.environment["PERTURBATION_DEBUG"] != nil {
                FileHandle.standardError.write("round refCount=\(refCount) refEscapedAt=\(String(describing: orbit.escapedAtIteration)) pending=\(pending.count) glitched=\(nextPending.count) roundsLeft=\(roundsLeft)\n".data(using: .utf8)!)
            }

            if nextPending.isEmpty || roundsLeft == 0 {
                // Give up gracefully: paint any still-glitched pixels using
                // their last reference's iteration depth as an approximation
                // rather than leaving them uninitialized.
                for idx in nextPending { values[idx] = Float(maxIterations) }
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

        return values
    }
}
