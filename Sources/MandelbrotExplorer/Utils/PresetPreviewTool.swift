import AppKit
import AVFoundation
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

    /// Headless smoke test for the Mandelbulb explorer: renders a handful of
    /// camera angles/variants/power values straight to PNG, no window
    /// needed. Activated by MANDELBULB_TEST_DIR.
    static func runMandelbulbTest(outputDir: String) {
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let renderer = MandelbulbRenderer()
        let deadline = Date().addingTimeInterval(15)
        while !renderer.isReady && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let size = CGSize(width: 480, height: 300)

        func capture(_ name: String, configure: () -> Void) {
            configure()
            var done = false
            renderer.captureImage(size: size) { image in
                defer { done = true }
                guard let image else { logErr("FAILED \(name)"); return }
                let rep = NSBitmapImageRep(cgImage: image)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
                    logErr("wrote \(name)")
                }
            }
            let d2 = Date().addingTimeInterval(60)
            while !done && Date() < d2 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            if !done { logErr("TIMEOUT \(name)") }
        }

        capture("classic_default") {}
        capture("power4") { renderer.power = 4 }
        capture("hollow") { renderer.power = 8; renderer.hollowVariant = true }
        capture("power12_spiky") { renderer.hollowVariant = false; renderer.power = 12 }
        capture("low_quality") { renderer.power = 8; renderer.quality = .low }
        capture("ultra_quality") { renderer.quality = .ultra }
        capture("high_quality_ao_shadows") { renderer.quality = .high }

        logErr("DONE")
        exit(0)
    }

    /// Headless correctness check for the color engine: renders the same
    /// view under every `ColorMode`/orbit trap shape/shading combination, at
    /// both a GPU-tier zoom and a perturbation-tier (CPU) zoom, so a broken
    /// color mode on either path shows up as a visibly wrong PNG rather than
    /// requiring someone to click through every sidebar control by hand.
    /// Activated by COLOR_MODE_TEST_DIR.
    static func runColorModeTest(outputDir: String) {
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let renderer = FractalRenderer()
        waitUntilReady(renderer)
        let size = CGSize(width: 480, height: 300)

        func capture(_ name: String, configure: () -> Void) {
            configure()
            var done = false
            renderer.captureFullQualityImage(size: size) { image in
                defer { done = true }
                guard let image else { logErr("FAILED \(name)"); return }
                let rep = NSBitmapImageRep(cgImage: image)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
                    logErr("wrote \(name)")
                }
            }
            let deadline = Date().addingTimeInterval(60)
            while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            if !done { logErr("TIMEOUT \(name)") }
        }

        if let seahorse = Preset.all.first(where: { $0.id == "seahorse" }) {
            renderer.viewport = seahorse.makeViewport()
            renderer.maxIterations = seahorse.suggestedIterations
        }
        capture("gpu_escape_smooth") { renderer.colorMode = .escapeTime; renderer.smoothingEnabled = true; renderer.shadingEnabled = false }
        capture("gpu_escape_banded") { renderer.smoothingEnabled = false }
        capture("gpu_escape_shaded") { renderer.smoothingEnabled = true; renderer.shadingEnabled = true }
        capture("gpu_distance_estimation") { renderer.shadingEnabled = false; renderer.colorMode = .distanceEstimation }
        capture("gpu_orbit_trap_circle") { renderer.colorMode = .orbitTrap; renderer.orbitTrap = OrbitTrapSettings(type: .circle) }
        capture("gpu_orbit_trap_line") { renderer.orbitTrap = OrbitTrapSettings(type: .line, angleDegrees: 30) }
        capture("gpu_orbit_trap_cross") { renderer.orbitTrap = OrbitTrapSettings(type: .cross) }
        capture("gpu_orbit_trap_custom") { renderer.orbitTrap = OrbitTrapSettings(type: .custom, customX: 0.3, customY: 0.2) }
        capture("gpu_orbit_trap_shaded") { renderer.shadingEnabled = true }

        if let full = Preset.all.first(where: { $0.id == "full" }) {
            renderer.viewport = full.makeViewport()
            renderer.maxIterations = 400
        }
        capture("gpu_fullview_orbit_trap_small_circle") { renderer.colorMode = .orbitTrap; renderer.orbitTrap = OrbitTrapSettings(type: .circle, scale: 0.15); renderer.shadingEnabled = false }
        capture("gpu_fullview_orbit_trap_cross") { renderer.orbitTrap = OrbitTrapSettings(type: .cross) }

        if let deep = Preset.all.first(where: { $0.id == "seahorse-deep" }) {
            renderer.viewport = deep.makeViewport()
            renderer.maxIterations = deep.suggestedIterations
        }
        capture("perturbation_escape_smooth") { renderer.colorMode = .escapeTime; renderer.smoothingEnabled = true; renderer.shadingEnabled = false }
        capture("perturbation_distance_estimation") { renderer.colorMode = .distanceEstimation }
        capture("perturbation_orbit_trap") { renderer.colorMode = .orbitTrap; renderer.orbitTrap = OrbitTrapSettings(type: .circle) }
        capture("perturbation_orbit_trap_cross") { renderer.orbitTrap = OrbitTrapSettings(type: .cross) }

        logErr("DONE")
        exit(0)
    }

    /// Definitive numeric cross-check for Julia-mode perturbation: iterates a
    /// specific pixel's *exact* z0 value directly at full arbitrary
    /// precision (no perturbation at all) and compares its escape iteration
    /// to what `Perturbation.render(kind: .julia, ...)` reports for the same
    /// pixel -- mirrors `runSingle`'s Mandelbrot cross-check. Activated by
    /// JULIA_DEBUG_SINGLE, spec format "z0real,z0imag,cReal,cImag,zoom,iterations".
    static func runJuliaSingle(spec: String) {
        let parts = spec.split(separator: ",").map(String.init)
        guard parts.count == 6, let cRe = Double(parts[2]), let cIm = Double(parts[3]),
              let zoom = Double(parts[4]), let iters = Int(parts[5]) else {
            logErr("bad spec, expected z0real,z0imag,cReal,cImag,zoom,iterations")
            exit(1)
        }
        let precision = requiredPrecisionTerms(forZoom: zoom)
        let re = Expansion(decimalString: parts[0], precision: precision)
        let im = Expansion(decimalString: parts[1], precision: precision)
        let center = ComplexExpansion(re: re, im: im) // the explored z0 neighborhood's center
        let juliaC = SIMD2(cRe, cIm)
        let cExpansion = ComplexExpansion(re: Expansion(cRe), im: Expansion(cIm))
        let pixelSize = (Viewport.initialSpanX / zoom) / 900
        logErr("center(z0)=\(center.approximateValue) c=\(juliaC) zoom=\(zoom) precisionTerms=\(precision) pixelSize=\(pixelSize) iters=\(iters)")

        let orbit = ReferenceOrbit.compute(start: center, addedConstant: cExpansion, maxIterations: iters, escapeRadiusSquared: 256, precision: precision)
        logErr("referenceOrbit points=\(orbit.points.count) escapedAt=\(String(describing: orbit.escapedAtIteration))")

        let dcRe = -450.0 * pixelSize
        let dcIm = 280.0 * pixelSize
        let pixelZ0 = center.adding(ComplexExpansion(re: Expansion(dcRe), im: Expansion(dcIm)), precision: precision)
        var z = pixelZ0
        var directEscapeN: Int? = nil
        var n = 0
        while n < iters {
            z = z.squared(precision: precision).adding(cExpansion, precision: precision)
            n += 1
            let a = z.approximateValue
            if a.x * a.x + a.y * a.y > 256 { directEscapeN = n; break }
        }
        logErr("DIRECT pixel(0,0) escapeN=\(String(describing: directEscapeN))")
        let result = Perturbation.render(
            centerDeep: center, pixelSize: pixelSize,
            width: 900, height: 560,
            maxIterations: iters, escapeRadius: 16.0, precision: precision,
            kind: .julia, juliaC: juliaC
        )
        logErr("PERTURBATION pixel(0,0) smoothValue=\(result.values[0]) seriesApproximationSkip=\(result.seriesApproximationSkip) referenceOrbitIterations=\(result.referenceOrbitIterations)")
        exit(0)
    }

    /// Headless correctness check for the Julia explorer: renders a handful
    /// of well-known Julia constants at the GPU float32 tier, plus one deep
    /// zoom (well past the perturbation-tier threshold) to exercise the
    /// Julia-mode reference-orbit/series-approximation math -- straight to
    /// PNG, no window needed. Activated by JULIA_TEST_DIR.
    static func runJuliaTest(outputDir: String) {
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let renderer = FractalRenderer(kind: .julia)
        waitUntilReady(renderer)
        let size = CGSize(width: 480, height: 300)

        func capture(_ name: String, configure: () -> Void) {
            configure()
            var done = false
            renderer.captureFullQualityImage(size: size) { image in
                defer { done = true }
                guard let image else { logErr("FAILED \(name)"); return }
                let rep = NSBitmapImageRep(cgImage: image)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
                    logErr("wrote \(name) tier=\(renderer.viewport.tier.label)")
                }
            }
            let deadline = Date().addingTimeInterval(60)
            while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            if !done { logErr("TIMEOUT \(name)") }
        }

        let constants: [(String, SIMD2<Double>)] = [
            ("dendrite", SIMD2(-0.4, 0.6)),
            ("douady_rabbit", SIMD2(-0.123, 0.745)),
            ("san_marco", SIMD2(-0.75, 0.0)),
            ("siegel_disk", SIMD2(-0.390541, -0.586788)),
        ]
        for (name, c) in constants {
            capture("julia_\(name)") { renderer.juliaC = c }
        }

        capture("julia_orbit_trap") {
            renderer.juliaC = SIMD2(-0.8, 0.156)
            renderer.colorMode = .orbitTrap
            renderer.orbitTrap = OrbitTrapSettings(type: .circle)
        }
        capture("julia_distance_estimation") {
            renderer.colorMode = .distanceEstimation
        }

        // Deep zoom into a Julia set's own boundary detail, well past the
        // perturbation-tier threshold -- exercises the Julia-mode reference
        // orbit (start = z0, added constant = fixed c) and series
        // approximation (seeded at ε rather than 0, no per-iteration
        // injection) end to end.
        capture("julia_deep_perturbation") {
            renderer.colorMode = .escapeTime
            renderer.juliaC = SIMD2(-0.4, 0.6)
            let zoom = 1e16
            let precision = requiredPrecisionTerms(forZoom: zoom)
            let re = Expansion(decimalString: "0.0", precision: precision)
            let im = Expansion(decimalString: "0.0", precision: precision)
            renderer.viewport = Viewport(center: ComplexExpansion(re: re, im: im), spanX: Viewport.initialSpanX / zoom)
            renderer.maxIterations = 2000
        }

        logErr("DONE")
        exit(0)
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
        let orbit = ReferenceOrbit.compute(addedConstant: center, maxIterations: iters, escapeRadiusSquared: 256, precision: precision)
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

    /// Headless correctness check for `FractalRecorder`: records a short
    /// clip and pulls a mid-clip frame back out as a PNG next to it, so
    /// orientation/overlay/codec problems show up as a plain image rather
    /// than requiring a person to click through the record UI and eyeball
    /// a QuickTime window. Activated by RECORDING_TEST_PATH (path to the
    /// .mov to write).
    static func runRecordingTest(outputPath: String) {
        let renderer = FractalRenderer()
        waitUntilReady(renderer)
        if let seahorse = Preset.all.first(where: { $0.id == "seahorse" }) {
            renderer.viewport = seahorse.makeViewport()
            renderer.maxIterations = seahorse.suggestedIterations
        }

        let recorder = FractalRecorder()
        var settings = RecordingSettings()
        settings.resolution = .hd720
        settings.fps = 10
        settings.durationSeconds = 2
        settings.showZoomOverlay = true

        let url = URL(fileURLWithPath: outputPath)
        recorder.start(renderer: renderer, settings: settings, outputURL: url)

        let deadline = Date().addingTimeInterval(90)
        while recorder.isActive && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        logErr("recording phase=\(recorder.phase) frames=\(recorder.currentFrame)/\(recorder.totalFrames)")

        guard case .finished(let finishedURL) = recorder.phase else { exit(1) }
        let asset = AVURLAsset(url: finishedURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for frac: Double in [0.0, 0.25, 0.5, 0.75, 0.95] {
            let thumbTime = CMTime(seconds: settings.durationSeconds * frac, preferredTimescale: 600)
            do {
                var actual = CMTime.zero
                let cgImage = try generator.copyCGImage(at: thumbTime, actualTime: &actual)
                let rep = NSBitmapImageRep(cgImage: cgImage)
                if let data = rep.representation(using: .png, properties: [:]) {
                    let thumbURL = finishedURL.deletingPathExtension().appendingPathExtension("thumb_\(Int(frac * 100)).png")
                    try data.write(to: thumbURL)
                    logErr("wrote thumbnail to \(thumbURL.path) requested=\(thumbTime.seconds)s actual=\(actual.seconds)s size=\(cgImage.width)x\(cgImage.height)")
                }
            } catch {
                logErr("thumbnail extraction FAILED at frac=\(frac): \(error)")
            }
        }
        exit(0)
    }
}
