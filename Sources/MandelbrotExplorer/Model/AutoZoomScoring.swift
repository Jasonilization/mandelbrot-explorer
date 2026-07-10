import CoreGraphics

/// Turns a rendered mu buffer (smooth escape-iteration count, or -1 for
/// interior points) into a steering target for auto-zoom, so it drifts
/// toward visually rich boundary structure instead of zooming straight
/// ahead into whatever happened to be centered -- which, left unchecked,
/// is just as likely to be a flat interior lake or a featureless exterior
/// as it is real detail.
enum AutoZoomScoring {
    struct Target {
        /// Normalized offset in [-1, 1] x [-1, 1], same top-left-origin
        /// convention as the rendered buffer (0,0 = center, +x = right,
        /// +y = down).
        let offset: CGPoint
        /// Roughly 0 (flat/boring) to 3 (right on richly detailed boundary).
        let score: Double
    }

    /// Below this, a frame counts as "boring": no cell showed meaningful
    /// boundary presence or iteration-count variation.
    static let boringThreshold = 0.12

    /// Scans a coarse grid over the buffer and scores each cell by two
    /// independent signals that both indicate "this is worth looking at":
    ///  - boundary presence: neighboring cells disagree on interior vs.
    ///    exterior, i.e. the fractal edge itself passes through here.
    ///  - iteration variation: among exterior neighbors, how much the
    ///    escape count changes cell to cell (fine banding = detail; a flat
    ///    run of nearly-identical values = a featureless region far from
    ///    the set).
    static func bestTarget(values: [Float], width: Int, height: Int, gridColumns: Int = 40, gridRows: Int = 26) -> Target? {
        guard width >= 4, height >= 4, values.count == width * height else { return nil }
        let cellW = max(1, width / gridColumns)
        let cellH = max(1, height / gridRows)
        let cols = width / cellW
        let rows = height / cellH
        guard cols >= 3, rows >= 3 else { return nil }

        // One representative sample per cell keeps the neighbor pass
        // O(cols*rows) rather than rescanning every source pixel.
        var cellMu = [Float](repeating: -1, count: cols * rows)
        for gy in 0..<rows {
            let sy = min(height - 1, gy * cellH + cellH / 2)
            for gx in 0..<cols {
                let sx = min(width - 1, gx * cellW + cellW / 2)
                cellMu[gy * cols + gx] = values[sy * width + sx]
            }
        }

        var best: Target?
        let neighborOffsets = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        for gy in 1..<(rows - 1) {
            for gx in 1..<(cols - 1) {
                let center = cellMu[gy * cols + gx]
                let centerIsInterior = center < 0
                var boundaryDisagreements = 0.0
                var gradientSum = 0.0
                var gradientSamples = 0.0
                for (dx, dy) in neighborOffsets {
                    let neighbor = cellMu[(gy + dy) * cols + (gx + dx)]
                    let neighborIsInterior = neighbor < 0
                    if centerIsInterior != neighborIsInterior {
                        boundaryDisagreements += 1
                    } else if !centerIsInterior {
                        gradientSum += Double(abs(center - neighbor))
                        gradientSamples += 1
                    }
                }
                let boundaryScore = boundaryDisagreements / 4.0
                // 24 mu-units of neighbor-to-neighbor variation saturates
                // the score; picked empirically to separate "smooth exterior
                // gradient" from "fine boundary banding" at typical
                // iteration counts without needing per-zoom recalibration.
                let gradientScore = gradientSamples > 0 ? min(1.0, (gradientSum / gradientSamples) / 24.0) : 0.0
                let score = boundaryScore * 2.0 + gradientScore
                if best == nil || score > best!.score {
                    let nx = (Double(gx) + 0.5) / Double(cols) * 2 - 1
                    let ny = (Double(gy) + 0.5) / Double(rows) * 2 - 1
                    best = Target(offset: CGPoint(x: nx, y: ny), score: score)
                }
            }
        }
        return best
    }
}
