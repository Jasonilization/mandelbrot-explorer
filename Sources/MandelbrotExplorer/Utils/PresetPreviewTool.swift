import AppKit
import Foundation

/// Headless verification path: renders every preset, plus a zoom-depth
/// ladder at a single fixed coordinate spanning all three precision tiers,
/// straight to PNG files -- no window, no screen capture. Activated by
/// setting PRESET_PREVIEW_DIR so it never runs in the shipped app.
@MainActor
enum PresetPreviewTool {
    /// Shader compilation now happens off the main actor (see
    /// `FractalRenderer.buildPipelinesAsync`), so a headless run that starts
    /// capturing immediately would spuriously fail every GPU-tier preset
    /// until compilation happens to catch up in the background.
    private static func waitUntilReady(_ renderer: FractalRenderer, timeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(timeout)
        while !renderer.isReady && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    static func run(outputDir: String) {
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let renderer = FractalRenderer()
        waitUntilReady(renderer)
        let size = CGSize(width: 900, height: 560)

        func stats(_ values: [Float]) -> String {
            var escaped = 0
            var minMu = Float.greatestFiniteMagnitude
            var maxMu: Float = -1
            var sum: Double = 0
            for v in values {
                if v >= 0 {
                    escaped += 1
                    minMu = min(minMu, v)
                    maxMu = max(maxMu, v)
                    sum += Double(v)
                }
            }
            let pct = 100.0 * Double(escaped) / Double(values.count)
            if escaped == 0 { return "escaped=0%" }
            let mean = sum / Double(escaped)
            return String(format: "escaped=%.1f%% mu[min=%.1f max=%.1f mean=%.1f]", pct, minMu, maxMu, mean)
        }

        func capture(name: String, configure: () -> Void) {
            configure()
            let tierLabel = renderer.viewport.tier.label
            var done = false
            var statsLine = ""
            renderer.computeIterationValues(width: Int(size.width), height: Int(size.height)) { values in
                if let values { statsLine = stats(values) }
            }
            renderer.captureFullQualityImage(size: size) { image in
                defer { done = true }
                guard let image else {
                    logErr("FAILED \(name)")
                    return
                }
                let rep = NSBitmapImageRep(cgImage: image)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
                    logErr("wrote \(name) tier=\(tierLabel) zoom=\(renderer.viewport.zoomFactor) \(statsLine)")
                }
            }
            let deadline = Date().addingTimeInterval(120)
            while !done && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            if !done { logErr("TIMEOUT \(name)") }
        }

        for preset in Preset.all {
            capture(name: "preset_\(preset.id)") {
                renderer.viewport = preset.makeViewport()
                renderer.maxIterations = preset.suggestedIterations
            }
        }

        // Zoom ladder at one fixed, high-confidence boundary coordinate to
        // exercise every precision tier and the tier hand-off points.
        let ladderReal = "-0.7436438870371587"
        let ladderImag = "0.13182590420533"
        let zooms: [(String, Double, Int)] = [
            ("1e0", 1, 200),
            ("1e3", 1e3, 300),
            ("3e4_tier1-2_boundary", 3e4, 400),
            ("1e6", 1e6, 500),
            ("1e10", 1e10, 800),
            ("1e13_tier2-3_boundary", 1e13, 1200),
            ("1e14", 1e14, 1500),
            ("1e16", 1e16, 2000),
            ("1e20", 1e20, 2500),
            ("1e40", 1e40, 3000),
            ("1e80", 1e80, 3500),
        ]
        for (label, zoom, iters) in zooms {
            capture(name: "ladder_\(label)") {
                let precision = requiredPrecisionTerms(forZoom: zoom)
                let re = Expansion(decimalString: ladderReal, precision: precision)
                let im = Expansion(decimalString: ladderImag, precision: precision)
                renderer.viewport = Viewport(center: ComplexExpansion(re: re, im: im), spanX: Viewport.initialSpanX / zoom)
                renderer.maxIterations = iters
            }
        }

        // Second ladder at a coordinate with zero memorization risk: c =
        // -3/4 exactly is the parabolic root where the main cardioid meets
        // the period-2 bulb (fixed point z=-1/2 has derivative exactly -1
        // there) -- a exact rational, provably-on-the-boundary point with
        // famously rich structure at arbitrary depth, so this isolates
        // renderer correctness from any doubt about a memorized many-digit
        // coordinate. Parabolic dynamics converge slowly, so iteration
        // counts are pushed higher than the equivalent generic-boundary case.
        let exactReal = "-0.75"
        let exactImag = "0.0"
        let exactZooms: [(String, Double, Int)] = [
            ("1e10", 1e10, 2000),
            ("1e13_boundary", 3e13, 3000),
            ("1e14", 1e14, 4000),
            ("1e20", 1e20, 6000),
            ("1e40", 1e40, 8000),
            ("1e80", 1e80, 10000),
        ]
        for (label, zoom, iters) in exactZooms {
            capture(name: "exact_\(label)") {
                let precision = requiredPrecisionTerms(forZoom: zoom)
                let re = Expansion(decimalString: exactReal, precision: precision)
                let im = Expansion(decimalString: exactImag, precision: precision)
                renderer.viewport = Viewport(center: ComplexExpansion(re: re, im: im), spanX: Viewport.initialSpanX / zoom)
                renderer.maxIterations = iters
            }
        }

        logErr("DONE")
        exit(0)
    }

    private static func logErr(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }

    /// Renders a square, high-color-contrast crop for use as the app icon.
    static func renderIcon(to path: String) {
        let renderer = FractalRenderer()
        waitUntilReady(renderer)
        renderer.palette = ColorPalette.all.first(where: { $0.id == "fire" }) ?? .default
        let re = Expansion(decimalString: "-0.1592", precision: 4)
        let im = Expansion(decimalString: "1.0317", precision: 4)
        renderer.viewport = Viewport(center: ComplexExpansion(re: re, im: im), spanX: Viewport.initialSpanX / 120)
        renderer.maxIterations = 600
        var done = false
        renderer.captureFullQualityImage(size: CGSize(width: 1024, height: 1024)) { image in
            defer { done = true }
            guard let image else { logErr("icon render FAILED"); return }
            let rep = NSBitmapImageRep(cgImage: image)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                logErr("wrote icon to \(path)")
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while !done && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        exit(0)
    }

    /// spec format: "real,imag,zoom,iterations"
    static func runSingle(spec: String) {
        let parts = spec.split(separator: ",").map(String.init)
        guard parts.count == 4, let zoom = Double(parts[2]), let iters = Int(parts[3]) else {
            logErr("bad spec, expected real,imag,zoom,iterations")
            exit(1)
        }
        let precision = requiredPrecisionTerms(forZoom: zoom)
        let re = Expansion(decimalString: parts[0], precision: precision)
        let im = Expansion(decimalString: parts[1], precision: precision)
        let center = ComplexExpansion(re: re, im: im)
        let pixelSize = (Viewport.initialSpanX / zoom) / 900
        logErr("center=\(center.approximateValue) zoom=\(zoom) precisionTerms=\(precision) pixelSize=\(pixelSize) iters=\(iters)")

        // Independently derive the expected |d(z_n)/dc| growth directly from
        // the reference orbit (sum of log2(2*|Z_k|)) to check whether slow
        // per-pixel divergence is a real property of this orbit or a bug in
        // the dz recurrence.
        let orbit = ReferenceOrbit.compute(center: center, maxIterations: iters, escapeRadiusSquared: 256, precision: precision)
        var logGrowth = 0.0
        for z in orbit.points {
            let mag = (z.x * z.x + z.y * z.y).squareRoot()
            if mag > 0 { logGrowth += log2(2 * mag) }
        }
        logErr("referenceOrbit points=\(orbit.points.count) escapedAt=\(String(describing: orbit.escapedAtIteration)) expected_log2_growth=\(logGrowth) expected_growth_factor=2^\(logGrowth)")

        // Definitive cross-check: iterate pixel (0,0)'s *exact* c value
        // directly at full arbitrary precision (no perturbation at all) and
        // compare its escape iteration to what perturbation reported.
        let dcRe = -450.0 * pixelSize
        let dcIm = 280.0 * pixelSize
        let pixelC = center.adding(ComplexExpansion(re: Expansion(dcRe), im: Expansion(dcIm)), precision: precision)
        var z = ComplexExpansion.zero
        var directEscapeN: Int? = nil
        var n = 0
        while n < iters {
            z = z.squared(precision: precision).adding(pixelC, precision: precision)
            n += 1
            let a = z.approximateValue
            if a.x * a.x + a.y * a.y > 256 { directEscapeN = n; break }
        }
        logErr("DIRECT pixel(0,0) escapeN=\(String(describing: directEscapeN)) (perturbation reported n=3050 for this pixel per earlier px log)")
        let result = Perturbation.render(
            centerDeep: center, pixelSize: pixelSize,
            width: 900, height: 560,
            maxIterations: iters, escapeRadius: 16.0, precision: precision
        )
        let values = result.values
        var escaped = 0
        var uniqueValues = Set<Float>()
        for v in values { if v >= 0 { escaped += 1 }; uniqueValues.insert(v) }
        logErr("escaped=\(escaped)/\(values.count) uniqueValueCount=\(uniqueValues.count) sampleUniqueValues=\(uniqueValues.prefix(10)) seriesApproximationSkip=\(result.seriesApproximationSkip) referenceOrbitIterations=\(result.referenceOrbitIterations)")
        exit(0)
    }
}
