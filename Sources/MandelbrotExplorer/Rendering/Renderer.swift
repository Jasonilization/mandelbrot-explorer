import Combine
import Foundation
import MetalKit
import QuartzCore
import simd

@MainActor
final class FractalRenderer: NSObject, ObservableObject, MTKViewDelegate {
    @Published var viewport: Viewport = .initial() { didSet { autoAdjustIterationsIfNeeded(); wake() } }
    @Published var maxIterations: Int = 500 { didSet { wake() } }
    /// True while `FractalRecorder` has taken over the viewport to drive an
    /// offline zoom journey. Blocks manual pan/zoom/pinch and the live
    /// auto-zoom toggle so the two never fight over the same camera state.
    @Published var isInputLocked: Bool = false
    @Published var palette: ColorPalette = .default { didSet { rebuildStopsBuffer(); wake() } }
    @Published var colorScale: Float = 1.0 { didSet { wake() } }
    @Published var colorOffset: Float = 0.0 { didSet { wake() } }

    /// True while iteration count should auto-track zoom depth (the default,
    /// "just zoom and it stays sharp" experience). Cleared the moment the
    /// user manually touches the iteration control, so a deliberate choice
    /// is never silently overwritten; restored on preset/reset.
    var autoIterationsEnabled = true

    private func autoAdjustIterationsIfNeeded() {
        guard autoIterationsEnabled else { return }
        let suggested = Preset.suggestedIterations(forZoom: viewport.zoomFactor)
        if suggested != maxIterations { maxIterations = suggested }
    }
    @Published var fps: Double = 0
    @Published var lastRenderTimeMs: Double = 0
    @Published var currentTierLabel: String = RenderTier.float32.label
    @Published var isRefining: Bool = false
    @Published var renderWidth: Int = 0
    @Published var renderHeight: Int = 0

    /// How many leading iterations series approximation let the last
    /// perturbation render skip, and how long that render's reference orbit
    /// was. Both 0 outside the perturbation tier. Purely informational --
    /// drives the "Rendering" status indicator described in the additional
    /// quality features (precision/mode visibility).
    @Published var seriesApproximationSkip: Int = 0
    @Published var referenceOrbitIterations: Int = 0

    /// False until the Metal shader library has finished compiling. Shader
    /// compilation is a few hundred ms of blocking work; doing it on the
    /// main thread at launch used to freeze the window (a plain black
    /// screen, since that's MTKView's default clear color) before the first
    /// frame could render. It now happens off the main actor, and
    /// ContentView shows a loading overlay until this flips to true.
    @Published var isReady: Bool = false

    /// True while auto-zoom or a manual gesture is actively moving the
    /// viewport -- both should get the same reduced-quality/iteration
    /// treatment so continuous motion never spikes CPU/GPU usage.
    var isAnimating: Bool { isInteracting || isAutoZooming }

    /// Continuously and smoothly zooms when enabled, steering toward
    /// visually rich boundary structure (see `AutoZoomScoring`) instead of
    /// diving straight ahead -- otherwise it's just as likely to plunge into
    /// a flat interior lake as real detail. Cancelled by any manual
    /// pan/zoom/pinch.
    @Published var isAutoZooming: Bool = false {
        didSet {
            guard isAutoZooming, !oldValue else { return }
            autoZoomLastTimestamp = CACurrentMediaTime()
            resetAutoZoomSteering()
            wake()
        }
    }
    /// Zoom multiplier applied per second of auto-zoom, e.g. 1.15 = 15%/sec.
    @Published var autoZoomSpeed: Double = 1.15
    /// True while auto-zoom has decided the current view is boring (flat
    /// interior or featureless exterior) and is backing off / sweeping
    /// around to find structure again, rather than zooming further in.
    /// Purely informational, for a status indicator.
    @Published var isAutoZoomSearching: Bool = false

    /// Steering target for auto-zoom, normalized [-1, 1] (0,0 = screen
    /// center), re-scored periodically from the last rendered frame.
    private var autoZoomTargetOffset = CGPoint.zero
    /// Eased toward `autoZoomTargetOffset` every frame so direction changes
    /// read as a smooth drift rather than a snap -- this is the point
    /// actually passed to `viewport.zoom(aroundScreenPoint:)`.
    private var autoZoomCurrentOffset = CGPoint.zero
    private var autoZoomLastScoreTime: CFTimeInterval = -1
    private var autoZoomBoringStreak = 0
    private var autoZoomSearchAngle: Double = 0
    /// Eased +1 (zooming in) / -1 (backing out while searching), so the
    /// bored <-> interested transition is a smooth ramp, not a hard cut.
    private var autoZoomDirection: Double = 1.0

    private var autoZoomLastTimestamp: CFTimeInterval = CACurrentMediaTime()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipelineFloat32: MTLComputePipelineState?
    private var pipelineDD: MTLComputePipelineState?
    private var pipelinePalette: MTLComputePipelineState?

    private var iterationTexture: MTLTexture?
    private var stopsBuffer: MTLBuffer?

    /// The app renders on demand rather than at a constant frame rate: idle
    /// scenes cost ~0% CPU/GPU, matching "smooth while moving, efficient at
    /// rest" rather than a naive always-on 120Hz redraw loop.
    weak var metalView: MTKView?
    private var idleFrameCount = 0

    private var interactionResetWorkItem: DispatchWorkItem?
    private(set) var isInteracting: Bool = false

    private var qualityScale: Double = 1.0
    private var lastFrameTimestamp: CFTimeInterval = CACurrentMediaTime()
    private var recentFrameTimesMs: [Double] = []

    // MARK: Tier-3 (perturbation) async pipeline state
    private var perturbationGeneration = 0
    private var perturbationBusy = false
    private var perturbationSettledAtFullQuality = false
    private var lastPerturbationSignature = ""

    override init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available on this device.")
        }
        self.device = device
        self.queue = queue
        super.init()
        rebuildStopsBuffer()
        buildPipelinesAsync()
    }

    private func buildPipelinesAsync() {
        let device = self.device
        Task.detached(priority: .userInitiated) { [weak self] in
            let source = FractalRenderer.loadShaderSource()
            do {
                // Fast-math defaults to on and permits reassociating/contracting
                // float ops. The double-double kernel's two-sum/two-prod error
                // terms only work if every add/multiply rounds exactly as
                // written -- fast-math is free to "simplify" e.g. `fma(a,b,-p)`
                // where `p = a*b` down to a literal zero, silently collapsing
                // double-double back to plain float32 precision. Must stay off.
                let options = MTLCompileOptions()
                options.fastMathEnabled = false
                let library = try await device.makeLibrary(source: source, options: options)
                guard let f32 = library.makeFunction(name: "mandelbrotFloat32"),
                      let dd = library.makeFunction(name: "mandelbrotDoubleDouble"),
                      let pal = library.makeFunction(name: "paletteMap") else {
                    fatalError("Missing kernel functions in compiled shader library.")
                }
                let pipeF32 = try await device.makeComputePipelineState(function: f32)
                let pipeDD = try await device.makeComputePipelineState(function: dd)
                let pipePal = try await device.makeComputePipelineState(function: pal)
                await MainActor.run {
                    guard let self else { return }
                    self.pipelineFloat32 = pipeF32
                    self.pipelineDD = pipeDD
                    self.pipelinePalette = pipePal
                    self.isReady = true
                    self.wake()
                }
            } catch {
                fatalError("Failed to build Metal shader pipelines: \(error)")
            }
        }
    }

    private nonisolated static func loadShaderSource() -> String {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
            Bundle.module.url(forResource: "Shaders", withExtension: "metal", subdirectory: "Rendering"),
        ]
        for candidate in candidates {
            if let url = candidate, let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }
        fatalError("Could not locate Shaders.metal resource.")
    }

    private func rebuildStopsBuffer() {
        var colors = palette.stops
        colors.append(palette.interiorColor)
        stopsBuffer = device.makeBuffer(
            bytes: colors,
            length: MemoryLayout<SIMD3<Float>>.stride * colors.count,
            options: .storageModeShared
        )
    }

    // MARK: - Interaction lifecycle (called by the view on drag/scroll)

    func markInteractionBegan() {
        isInteracting = true
        isAutoZooming = false // manual input always takes back control
        interactionResetWorkItem?.cancel()
        wake()
    }

    func markInteractionEnded() {
        interactionResetWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.isInteracting = false
            self?.wake() // one final full-quality frame once settled
        }
        interactionResetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    /// Snap the view back to a responsive frame rate and mark that the next
    /// frame has actual work to do. Cheap and idempotent; safe to call from
    /// any published-property `didSet`. Deliberately never pauses the view
    /// outright -- a fully paused `MTKView` only resumes on an explicit
    /// wake, and any missed/racy wake (async task completing after an
    /// idle-timeout, a SwiftUI update outside the tracked paths...) would
    /// freeze the app forever. Throttling `preferredFramesPerSecond` instead
    /// keeps `draw(in:)` firing at a slow heartbeat even at rest, so the
    /// view always self-heals within a fraction of a second -- but see
    /// `needsRedraw` for why that heartbeat no longer costs GPU time once
    /// the scene is actually static.
    private func wake() {
        needsRedraw = true
        idleFrameCount = 0
        if metalView?.preferredFramesPerSecond != FractalRenderer.activeFPS {
            metalView?.preferredFramesPerSecond = FractalRenderer.activeFPS
        }
    }

    private static let activeFPS = 120
    private static let idleFPS = 8

    /// Set by `wake()` whenever an input actually changes something (pan,
    /// zoom, palette, resize, a perturbation result landing...) and cleared
    /// right after a frame is actually rendered. Without this, the idle
    /// heartbeat re-ran the full compute + palette shader pass every single
    /// frame forever just to redraw pixels that hadn't changed -- cheap per
    /// frame, but it never stopped, so GPU/CPU usage crept up the longer the
    /// window sat open. Gating on it means idle frames are a no-op: Core
    /// Animation keeps showing the last presented drawable untouched.
    private var needsRedraw: Bool = true

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        wake() // new drawable size always needs a fresh render
    }

    func draw(in view: MTKView) {
        guard isReady else { return } // still compiling shaders; overlay covers the canvas
        let now = CACurrentMediaTime()

        if isAutoZooming {
            stepAutoZoom(now: now, viewSize: view.drawableSize)
        }

        let active = isAnimating || perturbationBusy
        guard needsRedraw || active else {
            // Nothing changed and nothing in flight: skip all GPU work. The
            // previously presented drawable stays on screen untouched, and
            // we keep decaying toward the idle frame rate below.
            idleFrameCount += 1
            if idleFrameCount > 3, view.preferredFramesPerSecond != FractalRenderer.idleFPS {
                view.preferredFramesPerSecond = FractalRenderer.idleFPS
            }
            return
        }

        let dt = now - lastFrameTimestamp
        lastFrameTimestamp = now
        // A large gap means we just resumed from being idle/paused -- don't
        // let that gap pollute the rolling FPS average.
        if dt > 0.5 { recentFrameTimesMs.removeAll() }
        updateFPS(frameSeconds: dt)
        adjustQualityScale(lastFrameMs: dt * 1000)

        let tier = viewport.tier
        currentTierLabel = tier.label

        let drawableSize = view.drawableSize
        guard drawableSize.width > 1, drawableSize.height > 1 else { return }

        switch tier {
        case .float32, .doubleDouble:
            renderGPUTier(tier: tier, view: view, drawableSize: drawableSize)
        case .perturbation:
            renderPerturbationTier(view: view, drawableSize: drawableSize)
        }

        needsRedraw = false

        // Adaptive frame rate rather than a hard pause: run fast while
        // something is actually in motion, and drop to a slow heartbeat once
        // settled. The heartbeat (never zero) guarantees the view can never
        // get permanently stuck showing a stale/low-quality frame.
        if active {
            idleFrameCount = 0
            if view.preferredFramesPerSecond != FractalRenderer.activeFPS {
                view.preferredFramesPerSecond = FractalRenderer.activeFPS
            }
        } else {
            idleFrameCount += 1
            if idleFrameCount > 3, view.preferredFramesPerSecond != FractalRenderer.idleFPS {
                view.preferredFramesPerSecond = FractalRenderer.idleFPS
            }
        }
    }

    /// Applies one frame's worth of smooth, frame-rate-independent zoom,
    /// steered toward interesting boundary structure rather than dead
    /// center. Runs from `draw(in:)` rather than a separate timer so it
    /// naturally shares the same GPU-driven cadence (and reduced
    /// quality/iterations via `isAnimating`) as manual interaction, instead
    /// of fighting it for control of the frame rate.
    private func stepAutoZoom(now: CFTimeInterval, viewSize: CGSize) {
        defer { autoZoomLastTimestamp = now }
        guard viewSize.width > 1, viewSize.height > 1 else { return }
        let dt = min(0.1, max(0, now - autoZoomLastTimestamp))
        guard dt > 0 else { return }
        updateAutoZoomSteering(now: now)
        if !advanceAutoZoom(dt: dt, viewSize: viewSize) {
            isAutoZooming = false
        }
    }

    /// Advances the smart-steered auto-zoom camera by exactly `dt` seconds'
    /// worth of motion and returns `false` once it's hit the precision
    /// floor (nothing further to do). Split out from `stepAutoZoom` so
    /// `FractalRecorder` can drive the identical steered path at a fixed
    /// per-output-frame dt, independent of how long each frame actually
    /// took to render -- recording should never be paced by live frame
    /// timing.
    @discardableResult
    func advanceAutoZoom(dt: Double, viewSize: CGSize) -> Bool {
        guard viewSize.width > 1, viewSize.height > 1, dt > 0 else { return true }
        guard viewport.spanX > Viewport.minSpanX * 1.0001 else {
            // Hit the precision floor -- further zoom wouldn't change
            // anything, so stop rather than spin forever.
            return false
        }

        // Ease both the steering point and the zoom direction toward their
        // latest targets every frame, so a newly-found interesting cell (or
        // a search sweep kicking in) reads as a continuous drift rather
        // than the camera snapping or jerking.
        let posEase = min(1.0, dt * 2.0)
        autoZoomCurrentOffset.x += (autoZoomTargetOffset.x - autoZoomCurrentOffset.x) * posEase
        autoZoomCurrentOffset.y += (autoZoomTargetOffset.y - autoZoomCurrentOffset.y) * posEase

        let targetDirection = autoZoomBoringStreak >= 2 ? -1.0 : 1.0
        let dirEase = min(1.0, dt * 1.5)
        autoZoomDirection += (targetDirection - autoZoomDirection) * dirEase
        isAutoZoomSearching = autoZoomBoringStreak >= 2

        let pivot = CGPoint(
            x: Double(viewSize.width) / 2 * (1 + autoZoomCurrentOffset.x),
            y: Double(viewSize.height) / 2 * (1 + autoZoomCurrentOffset.y)
        )
        let factor = pow(autoZoomSpeed, dt * autoZoomDirection)
        viewport.zoom(by: factor, aroundScreenPoint: pivot, viewSize: viewSize)
        return true
    }

    /// Re-scores auto-zoom's steering target from a rendered mu buffer (see
    /// `AutoZoomScoring`) at a fixed cadence during live interaction --
    /// re-reading back the on-screen texture every frame would be pointless
    /// when the image has barely changed since the last tick. `snapshot`
    /// lets `FractalRecorder` drive this from its own just-rendered frame
    /// instead of whatever happens to be in `iterationTexture` live.
    ///
    /// When nothing on screen clears the boredom threshold -- a flat
    /// interior lake, or featureless exterior far from the set -- sweeps
    /// the target around nearby instead, so a boring landing spot gets
    /// searched out of rather than zoomed straight into.
    func updateAutoZoomSteering(now: CFTimeInterval? = nil, snapshot: (values: [Float], width: Int, height: Int)? = nil) {
        if let now {
            guard autoZoomLastScoreTime < 0 || now - autoZoomLastScoreTime > 0.25 else { return }
            autoZoomLastScoreTime = now
        }
        guard let snapshot = snapshot ?? currentIterationSnapshot() else { return }
        guard let target = AutoZoomScoring.bestTarget(values: snapshot.values, width: snapshot.width, height: snapshot.height) else { return }

        if target.score >= AutoZoomScoring.boringThreshold {
            autoZoomBoringStreak = 0
            // Blend rather than snap: keeps the journey continuous even
            // when the most interesting cell hops across the frame between
            // scoring ticks.
            autoZoomTargetOffset.x = autoZoomTargetOffset.x * 0.5 + target.offset.x * 0.5
            autoZoomTargetOffset.y = autoZoomTargetOffset.y * 0.5 + target.offset.y * 0.5
        } else {
            autoZoomBoringStreak += 1
            autoZoomSearchAngle += 0.9
            let radius = min(0.85, 0.35 + Double(autoZoomBoringStreak) * 0.12)
            autoZoomTargetOffset = CGPoint(x: cos(autoZoomSearchAngle) * radius, y: sin(autoZoomSearchAngle) * radius)
        }
    }

    /// Resets auto-zoom's steering state to a clean slate. Called both when
    /// the live toggle switches on and before `FractalRecorder` starts a
    /// fresh journey, so neither inherits a stale target/search angle from
    /// a previous run.
    func resetAutoZoomSteering() {
        autoZoomTargetOffset = .zero
        autoZoomCurrentOffset = .zero
        autoZoomLastScoreTime = -1
        autoZoomBoringStreak = 0
        autoZoomDirection = 1.0
        isAutoZoomSearching = false
    }

    /// Cheap CPU-side copy of the texture that was actually presented last
    /// frame -- called from the top of `draw(in:)` before this frame's own
    /// render is encoded, so there's no race with the GPU still writing it.
    private func currentIterationSnapshot() -> (values: [Float], width: Int, height: Int)? {
        guard let tex = iterationTexture else { return nil }
        let w = tex.width, h = tex.height
        guard w > 4, h > 4 else { return nil }
        var values = [Float](repeating: -1, count: w * h)
        values.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: w * MemoryLayout<Float>.stride, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return (values, w, h)
    }

    private func updateFPS(frameSeconds: Double) {
        guard frameSeconds > 0 else { return }
        recentFrameTimesMs.append(frameSeconds * 1000)
        if recentFrameTimesMs.count > 30 { recentFrameTimesMs.removeFirst() }
        let avgMs = recentFrameTimesMs.reduce(0, +) / Double(recentFrameTimesMs.count)
        fps = avgMs > 0 ? 1000.0 / avgMs : 0
    }

    private func adjustQualityScale(lastFrameMs: Double) {
        let targetMs = 16.0
        if isAnimating {
            if lastFrameMs > targetMs * 1.3 {
                qualityScale = max(0.28, qualityScale - 0.08)
            } else if lastFrameMs < targetMs * 0.6 {
                qualityScale = min(1.0, qualityScale + 0.04)
            }
        } else {
            qualityScale = min(1.0, qualityScale + 0.15)
        }
    }

    // MARK: - Tier 1 / 2: GPU direct iteration

    private func renderGPUTier(tier: RenderTier, view: MTKView, drawableSize: CGSize) {
        guard let drawable = view.currentDrawable else { return }
        guard let pipeline = tier == .float32 ? pipelineFloat32 : pipelineDD else { return }
        // Stale from a previous perturbation render; irrelevant on the GPU tiers.
        if seriesApproximationSkip != 0 { seriesApproximationSkip = 0 }
        if referenceOrbitIterations != 0 { referenceOrbitIterations = 0 }
        let scale = isAnimating ? qualityScale : 1.0
        let renderW = max(8, Int(drawableSize.width * scale))
        let renderH = max(8, Int(drawableSize.height * scale))
        renderWidth = renderW
        renderHeight = renderH

        let iterations = isAnimating ? min(maxIterations, 220) : maxIterations

        guard let iterTex = makeOrReuseIterationTexture(width: renderW, height: renderH) else { return }
        guard stopsBuffer != nil else { return }

        let centerApprox = viewport.centerApprox
        let (hiRe, loRe) = splitDoubleToFloatPair(centerApprox.x)
        let (hiIm, loIm) = splitDoubleToFloatPair(centerApprox.y)
        var params = FractalParams(
            centerHi: SIMD2(hiRe, hiIm),
            centerLo: SIMD2(loRe, loIm),
            spanX: Float(viewport.spanX),
            aspect: Float(renderH) / Float(renderW),
            width: UInt32(renderW),
            height: UInt32(renderH),
            maxIterations: UInt32(iterations),
            escapeRadiusSq: 256.0
        )

        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        let start = CACurrentMediaTime()

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(iterTex, index: 0)
            encoder.setBytes(&params, length: MemoryLayout<FractalParams>.stride, index: 0)
            dispatch(encoder: encoder, pipeline: pipeline, width: renderW, height: renderH)
            encoder.endEncoding()
        }

        encodePalette(commandBuffer: commandBuffer, source: iterTex, destination: drawable.texture, sourceSize: (renderW, renderH))

        commandBuffer.addCompletedHandler { [weak self] _ in
            Task { @MainActor in
                self?.lastRenderTimeMs = (CACurrentMediaTime() - start) * 1000
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Tier 3: CPU perturbation, computed off the main thread

    private func renderPerturbationTier(view: MTKView, drawableSize: CGSize) {
        guard let drawable = view.currentDrawable else { return }

        let targetLongEdge: Double = 1500
        let baseScale = min(1.0, targetLongEdge / max(drawableSize.width, drawableSize.height))
        let scale = (isAnimating ? min(baseScale, 0.4) : baseScale)
        let renderW = max(8, Int(drawableSize.width * scale))
        let renderH = max(8, Int(drawableSize.height * scale))

        let iterations = isAnimating ? min(maxIterations, 300) : maxIterations
        let signature = "\(viewport.center.re.terms)|\(viewport.center.im.terms)|\(viewport.spanX)|\(iterations)|\(renderW)x\(renderH)"

        if signature != lastPerturbationSignature && !perturbationBusy {
            lastPerturbationSignature = signature
            perturbationSettledAtFullQuality = !isAnimating
            kickOffPerturbation(width: renderW, height: renderH, iterations: iterations)
        }

        renderWidth = renderW
        renderHeight = renderH

        guard let iterTex = iterationTexture, iterTex.width == renderW, iterTex.height == renderH else {
            // Nothing to show yet at this resolution; keep last drawable contents.
            return
        }
        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        let start = CACurrentMediaTime()
        encodePalette(commandBuffer: commandBuffer, source: iterTex, destination: drawable.texture, sourceSize: (renderW, renderH))
        commandBuffer.addCompletedHandler { [weak self] _ in
            Task { @MainActor in
                self?.lastRenderTimeMs = (CACurrentMediaTime() - start) * 1000
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func kickOffPerturbation(width: Int, height: Int, iterations: Int) {
        perturbationBusy = true
        isRefining = true
        perturbationGeneration += 1
        let generation = perturbationGeneration

        // Ensure the destination texture exists (freshly blanked to a
        // neutral value if it just changed size) before any tile lands, so
        // progressive fill-in always has a correctly-sized, non-garbage
        // buffer to paint into from the very first tile onward.
        _ = makeOrReuseIterationTexture(width: width, height: height)

        let centerDeep = viewport.center
        let pixelSize = viewport.spanX / Double(width)
        let precision = viewport.precisionTerms

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Perturbation.render(
                centerDeep: centerDeep,
                pixelSize: pixelSize,
                width: width,
                height: height,
                maxIterations: iterations,
                escapeRadius: 16.0,
                precision: precision,
                onTileComplete: { tile in
                    Task { @MainActor [weak self] in
                        guard let self, generation == self.perturbationGeneration else { return }
                        self.applyPerturbationTile(tile, fullWidth: width, fullHeight: height)
                    }
                }
            )
            await MainActor.run {
                guard let self, generation == self.perturbationGeneration else { return }
                self.applyPerturbationResult(result.values, width: width, height: height)
                self.seriesApproximationSkip = result.seriesApproximationSkip
                self.referenceOrbitIterations = result.referenceOrbitIterations
                self.perturbationBusy = false
                self.isRefining = false

                // If we rendered a reduced preview while idle (e.g. right
                // after a pan settled), immediately queue the full-quality pass.
                if !self.perturbationSettledAtFullQuality && !self.isAnimating {
                    self.perturbationSettledAtFullQuality = true
                    self.lastPerturbationSignature = ""
                }

                // The background computation may have outlasted the view's
                // idle-timeout and let it pause; guarantee at least one more
                // draw so the new result (and any chained refinement pass
                // queued above) is never stranded undisplayed.
                self.wake()
            }
        }
    }

    /// Blits one progressively-completed tile straight into the iteration
    /// texture and wakes the view, so a slow deep-zoom render visibly fills
    /// in tile by tile instead of leaving the old frame on screen until the
    /// entire buffer is ready. Guarded against a texture that was
    /// reallocated (e.g. a resize raced with an in-flight render) between
    /// `kickOffPerturbation` creating it and this tile landing.
    private func applyPerturbationTile(_ tile: Perturbation.TileUpdate, fullWidth: Int, fullHeight: Int) {
        guard let tex = iterationTexture, tex.width == fullWidth, tex.height == fullHeight else { return }
        tile.values.withUnsafeBytes { raw in
            tex.replace(
                region: MTLRegionMake2D(tile.originX, tile.originY, tile.width, tile.height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: tile.width * MemoryLayout<Float>.stride
            )
        }
        wake()
    }

    private func applyPerturbationResult(_ values: [Float], width: Int, height: Int) {
        guard let tex = makeOrReuseIterationTexture(width: width, height: height) else { return }
        values.withUnsafeBytes { raw in
            tex.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width * MemoryLayout<Float>.stride
            )
        }
    }

    // MARK: - Shared helpers

    private func dispatch(encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let threadsPerThreadgroup = MTLSize(width: w, height: h, depth: 1)
        let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    }

    private func encodePalette(commandBuffer: MTLCommandBuffer, source: MTLTexture, destination: MTLTexture, sourceSize: (Int, Int)) {
        guard let stopsBuffer, let pipelinePalette else { return }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipelinePalette)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        var params = PaletteParams(
            stopCount: UInt32(palette.stops.count),
            colorScale: colorScale,
            colorOffset: colorOffset,
            sourceWidth: UInt32(sourceSize.0),
            sourceHeight: UInt32(sourceSize.1),
            outWidth: UInt32(destination.width),
            outHeight: UInt32(destination.height)
        )
        encoder.setBytes(&params, length: MemoryLayout<PaletteParams>.stride, index: 0)
        encoder.setBuffer(stopsBuffer, offset: 0, index: 1)
        dispatch(encoder: encoder, pipeline: pipelinePalette, width: destination.width, height: destination.height)
        encoder.endEncoding()
    }

    private func makeOrReuseIterationTexture(width: Int, height: Int) -> MTLTexture? {
        if let tex = iterationTexture, tex.width == width, tex.height == height {
            return tex
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let tex = device.makeTexture(descriptor: desc)
        if let tex {
            // A freshly-allocated texture's contents are undefined. Blank it
            // to "interior" (-1) so a resize or new deep render reads as a
            // calm, neutral color while progressive tiles are still landing,
            // instead of a frame of uninitialized-memory noise.
            let blank = [Float](repeating: -1, count: width * height)
            blank.withUnsafeBytes { raw in
                tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: width * MemoryLayout<Float>.stride)
            }
        }
        iterationTexture = tex
        return tex
    }

    // MARK: - Save image

    /// Runs the current tier's iteration pass at an arbitrary resolution and
    /// returns the raw per-pixel smooth-escape buffer (mu, or -1 for
    /// interior points) with no palette applied. Shared by image export and
    /// by diagnostics that need to distinguish "correctly rendered, and this
    /// region is legitimately uniform" from "broken."
    func computeIterationValues(width: Int, height: Int, completion: @escaping ([Float]?) -> Void) {
        let tier = viewport.tier
        switch tier {
        case .float32, .doubleDouble:
            guard let tex = makeStandaloneTexture(width: width, height: height, pixelFormat: .r32Float) else { completion(nil); return }
            let centerApprox = viewport.centerApprox
            let (hiRe, loRe) = splitDoubleToFloatPair(centerApprox.x)
            let (hiIm, loIm) = splitDoubleToFloatPair(centerApprox.y)
            var params = FractalParams(
                centerHi: SIMD2(hiRe, hiIm), centerLo: SIMD2(loRe, loIm),
                spanX: Float(viewport.spanX), aspect: Float(height) / Float(width),
                width: UInt32(width), height: UInt32(height),
                maxIterations: UInt32(maxIterations), escapeRadiusSq: 256.0
            )
            guard let pipeline = tier == .float32 ? pipelineFloat32 : pipelineDD else { completion(nil); return }
            guard let cb = queue.makeCommandBuffer(), let encoder = cb.makeComputeCommandEncoder() else { completion(nil); return }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(tex, index: 0)
            encoder.setBytes(&params, length: MemoryLayout<FractalParams>.stride, index: 0)
            dispatch(encoder: encoder, pipeline: pipeline, width: width, height: height)
            encoder.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            var values = [Float](repeating: 0, count: width * height)
            values.withUnsafeMutableBytes { raw in
                tex.getBytes(raw.baseAddress!, bytesPerRow: width * MemoryLayout<Float>.stride, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            completion(values)
        case .perturbation:
            let centerDeep = viewport.center
            let pixelSize = viewport.spanX / Double(width)
            let precision = viewport.precisionTerms
            let iterations = maxIterations
            Task.detached(priority: .userInitiated) {
                let result = Perturbation.render(
                    centerDeep: centerDeep, pixelSize: pixelSize,
                    width: width, height: height,
                    maxIterations: iterations, escapeRadius: 16.0, precision: precision
                )
                await MainActor.run { completion(result.values) }
            }
        }
    }

    func captureFullQualityImage(size: CGSize, completion: @escaping (CGImage?) -> Void) {
        captureFrameForRecording(size: size) { image, _ in completion(image) }
    }

    /// Same full-quality offscreen render as `captureFullQualityImage`, but
    /// also hands back the raw per-pixel mu buffer alongside the image.
    /// `FractalRecorder` uses this to steer the next journey step from the
    /// frame it just encoded instead of paying for a second, redundant
    /// render purely to re-score.
    func captureFrameForRecording(size: CGSize, completion: @escaping (CGImage?, [Float]?) -> Void) {
        let width = max(8, Int(size.width))
        let height = max(8, Int(size.height))
        computeIterationValues(width: width, height: height) { [weak self] values in
            guard let self, let values else { completion(nil, nil); return }
            guard let srcTex = self.makeStandaloneTexture(width: width, height: height) else { completion(nil, nil); return }
            values.withUnsafeBytes { raw in
                srcTex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: width * MemoryLayout<Float>.stride)
            }
            self.renderOffscreenAndReadback(source: srcTex, width: width, height: height) { image in
                completion(image, values)
            }
        }
    }

    private func makeStandaloneTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat = .r32Float) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)
    }

    private func renderOffscreenAndReadback(source: MTLTexture, width: Int, height: Int, completion: @escaping (CGImage?) -> Void) {
        guard let colorTex = makeStandaloneTexture(width: width, height: height, pixelFormat: .rgba8Unorm),
              let stopsBuffer,
              let cb = queue.makeCommandBuffer() else { completion(nil); return }
        cb.addCompletedHandler { [weak self] _ in
            Task { @MainActor in
                completion(self?.cgImage(from: colorTex, width: width, height: height))
            }
        }
        _ = stopsBuffer
        encodePalette(commandBuffer: cb, source: source, destination: colorTex, sourceSize: (width, height))
        cb.commit()
    }

    private func cgImage(from texture: MTLTexture, width: Int, height: Int) -> CGImage? {
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&data, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
