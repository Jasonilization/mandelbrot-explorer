import Combine
import Foundation
import MetalKit
import QuartzCore
import simd

@MainActor
final class FractalRenderer: NSObject, ObservableObject, MTKViewDelegate {
    @Published var viewport: Viewport = .initial() { didSet { autoAdjustIterationsIfNeeded(); wake() } }
    @Published var maxIterations: Int = 500 { didSet { wake() } }
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

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipelineFloat32: MTLComputePipelineState!
    private var pipelineDD: MTLComputePipelineState!
    private var pipelinePalette: MTLComputePipelineState!

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
        buildPipelines()
        rebuildStopsBuffer()
    }

    private func buildPipelines() {
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
            let library = try device.makeLibrary(source: source, options: options)
            guard let f32 = library.makeFunction(name: "mandelbrotFloat32"),
                  let dd = library.makeFunction(name: "mandelbrotDoubleDouble"),
                  let pal = library.makeFunction(name: "paletteMap") else {
                fatalError("Missing kernel functions in compiled shader library.")
            }
            pipelineFloat32 = try device.makeComputePipelineState(function: f32)
            pipelineDD = try device.makeComputePipelineState(function: dd)
            pipelinePalette = try device.makeComputePipelineState(function: pal)
        } catch {
            fatalError("Failed to build Metal shader pipelines: \(error)")
        }
    }

    private static func loadShaderSource() -> String {
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

    /// Snap the view back to a responsive frame rate. Cheap and idempotent;
    /// safe to call from any published-property `didSet`. Deliberately never
    /// pauses the view outright -- a fully paused `MTKView` only resumes on
    /// an explicit wake, and any missed/racy wake (async task completing
    /// after an idle-timeout, a SwiftUI update outside the tracked paths...)
    /// would freeze the app forever. Throttling `preferredFramesPerSecond`
    /// instead keeps `draw(in:)` firing at a slow heartbeat even at rest, so
    /// the view always self-heals within a fraction of a second.
    private func wake() {
        idleFrameCount = 0
        if metalView?.preferredFramesPerSecond != FractalRenderer.activeFPS {
            metalView?.preferredFramesPerSecond = FractalRenderer.activeFPS
        }
    }

    private static let activeFPS = 120
    private static let idleFPS = 8

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
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

        // Adaptive frame rate rather than a hard pause: run fast while
        // something is actually in motion, and drop to a slow heartbeat once
        // settled. The heartbeat (never zero) guarantees the view can never
        // get permanently stuck showing a stale/low-quality frame.
        let active = isInteracting || perturbationBusy
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

    private func updateFPS(frameSeconds: Double) {
        guard frameSeconds > 0 else { return }
        recentFrameTimesMs.append(frameSeconds * 1000)
        if recentFrameTimesMs.count > 30 { recentFrameTimesMs.removeFirst() }
        let avgMs = recentFrameTimesMs.reduce(0, +) / Double(recentFrameTimesMs.count)
        fps = avgMs > 0 ? 1000.0 / avgMs : 0
    }

    private func adjustQualityScale(lastFrameMs: Double) {
        let targetMs = 16.0
        if isInteracting {
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
        let scale = isInteracting ? qualityScale : 1.0
        let renderW = max(8, Int(drawableSize.width * scale))
        let renderH = max(8, Int(drawableSize.height * scale))
        renderWidth = renderW
        renderHeight = renderH

        let iterations = isInteracting ? min(maxIterations, 220) : maxIterations

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
            encoder.setComputePipelineState(tier == .float32 ? pipelineFloat32 : pipelineDD)
            encoder.setTexture(iterTex, index: 0)
            encoder.setBytes(&params, length: MemoryLayout<FractalParams>.stride, index: 0)
            dispatch(encoder: encoder, pipeline: tier == .float32 ? pipelineFloat32 : pipelineDD, width: renderW, height: renderH)
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
        let scale = (isInteracting ? min(baseScale, 0.4) : baseScale)
        let renderW = max(8, Int(drawableSize.width * scale))
        let renderH = max(8, Int(drawableSize.height * scale))

        let iterations = isInteracting ? min(maxIterations, 300) : maxIterations
        let signature = "\(viewport.center.re.terms)|\(viewport.center.im.terms)|\(viewport.spanX)|\(iterations)|\(renderW)x\(renderH)"

        if signature != lastPerturbationSignature && !perturbationBusy {
            lastPerturbationSignature = signature
            perturbationSettledAtFullQuality = !isInteracting
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

        let centerDeep = viewport.center
        let pixelSize = viewport.spanX / Double(width)
        let precision = viewport.precisionTerms

        Task.detached(priority: .userInitiated) { [weak self] in
            let values = Perturbation.render(
                centerDeep: centerDeep,
                pixelSize: pixelSize,
                width: width,
                height: height,
                maxIterations: iterations,
                escapeRadius: 16.0,
                precision: precision
            )
            await MainActor.run {
                guard let self, generation == self.perturbationGeneration else { return }
                self.applyPerturbationResult(values, width: width, height: height)
                self.perturbationBusy = false
                self.isRefining = false

                // If we rendered a reduced preview while idle (e.g. right
                // after a pan settled), immediately queue the full-quality pass.
                if !self.perturbationSettledAtFullQuality && !self.isInteracting {
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
        guard let stopsBuffer else { return }
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
            guard let cb = queue.makeCommandBuffer(), let encoder = cb.makeComputeCommandEncoder() else { completion(nil); return }
            let pipeline = tier == .float32 ? pipelineFloat32! : pipelineDD!
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
                let values = Perturbation.render(
                    centerDeep: centerDeep, pixelSize: pixelSize,
                    width: width, height: height,
                    maxIterations: iterations, escapeRadius: 16.0, precision: precision
                )
                await MainActor.run { completion(values) }
            }
        }
    }

    func captureFullQualityImage(size: CGSize, completion: @escaping (CGImage?) -> Void) {
        let width = max(8, Int(size.width))
        let height = max(8, Int(size.height))
        computeIterationValues(width: width, height: height) { [weak self] values in
            guard let self, let values else { completion(nil); return }
            guard let srcTex = self.makeStandaloneTexture(width: width, height: height) else { completion(nil); return }
            values.withUnsafeBytes { raw in
                srcTex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: width * MemoryLayout<Float>.stride)
            }
            self.renderOffscreenAndReadback(source: srcTex, width: width, height: height, completion: completion)
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
