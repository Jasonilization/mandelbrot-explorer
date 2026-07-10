import Combine
import Foundation
import MetalKit
import QuartzCore
import simd

/// Drives the 3D Mandelbulb ray marcher: an orbit camera around the origin,
/// quality/lighting controls, and a single-pass compute kernel (see
/// `mandelbulbRender` in Shaders.metal) that ray-marches, shades, and writes
/// final color directly -- unlike the 2D explorer there's no separate
/// escape-value + palette pass, since each ray march already produces a lit
/// color per pixel.
///
/// Mirrors `FractalRenderer`'s render-on-demand / progressive-quality
/// architecture: idle costs ~0% GPU, active camera movement renders at a
/// reduced step count and resolution, and it snaps back to full tier quality
/// the moment the camera settles.
@MainActor
final class MandelbulbRenderer: NSObject, ObservableObject, MTKViewDelegate {
    // MARK: - Camera (spherical orbit around the origin)

    static let defaultYaw = 0.6
    static let defaultPitch = 0.35
    static let defaultDistance = 3.2
    static let minDistance = 1.05
    static let maxDistance = 12.0

    @Published private(set) var yaw = MandelbulbRenderer.defaultYaw
    @Published private(set) var pitch = MandelbulbRenderer.defaultPitch
    @Published private(set) var distance = MandelbulbRenderer.defaultDistance

    private var targetYaw = MandelbulbRenderer.defaultYaw
    private var targetPitch = MandelbulbRenderer.defaultPitch
    private var targetDistance = MandelbulbRenderer.defaultDistance

    // MARK: - Fractal parameters

    @Published var power: Double = 8 { didSet { wake() } }
    @Published var iterations: Int = 10 { didSet { wake() } }
    @Published var hollowVariant: Bool = false { didSet { wake() } }

    // MARK: - Quality / rendering

    @Published var quality: MandelbulbQuality = .medium { didSet { wake() } }
    @Published var renderResolution: RenderResolution = .native { didSet { wake() } }

    // MARK: - Lighting

    @Published var lightAzimuthDegrees: Double = 135 { didSet { wake() } }
    @Published var lightElevationDegrees: Double = 55 { didSet { wake() } }
    @Published var ambientStrength: Double = 0.35 { didSet { wake() } }
    @Published var aoOverrideEnabled: Bool = true { didSet { wake() } }
    @Published var shadowsOverrideEnabled: Bool = true { didSet { wake() } }

    // MARK: - Status (read by the UI)

    @Published var isReady = false
    @Published var fps: Double = 0
    @Published var lastRenderTimeMs: Double = 0
    @Published var renderWidth = 0
    @Published var renderHeight = 0

    var isAnimating: Bool { isInteracting }
    private(set) var isInteracting = false

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLComputePipelineState?
    private var resamplePipeline: MTLComputePipelineState?

    weak var metalView: MTKView?
    private var idleFrameCount = 0
    private var needsRedraw = true
    private static let activeFPS = 120
    private static let idleFPS = 8

    private var interactionResetWorkItem: DispatchWorkItem?
    private var lastFrameTimestamp: CFTimeInterval = CACurrentMediaTime()
    private var recentFrameTimesMs: [Double] = []

    private let fovRadians: Double = 55.0 * .pi / 180.0

    override init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available on this device.")
        }
        self.device = device
        self.queue = queue
        super.init()
        buildPipelineAsync()
    }

    private func buildPipelineAsync() {
        let device = self.device
        Task.detached(priority: .userInitiated) { [weak self] in
            let source = ShaderSource.load()
            do {
                let options = MTLCompileOptions()
                let library = try await device.makeLibrary(source: source, options: options)
                guard let fn = library.makeFunction(name: "mandelbulbRender"),
                      let resampleFn = library.makeFunction(name: "resampleColor") else {
                    fatalError("Missing kernel functions in compiled shader library.")
                }
                let pipe = try await device.makeComputePipelineState(function: fn)
                let resamplePipe = try await device.makeComputePipelineState(function: resampleFn)
                await MainActor.run {
                    guard let self else { return }
                    self.pipeline = pipe
                    self.resamplePipeline = resamplePipe
                    self.isReady = true
                    self.wake()
                }
            } catch {
                fatalError("Failed to build Mandelbulb shader pipeline: \(error)")
            }
        }
    }

    // MARK: - Camera interaction

    func markInteractionBegan() {
        isInteracting = true
        interactionResetWorkItem?.cancel()
        wake()
    }

    func markInteractionEnded() {
        interactionResetWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.isInteracting = false
            self?.wake()
        }
        interactionResetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    /// Rotate the orbit camera. `deltaX`/`deltaY` are raw drag deltas in
    /// points; sign/scale tuned so dragging right/up rotates the object the
    /// way a trackball would.
    func orbit(deltaX: Double, deltaY: Double) {
        let sensitivity = 0.006
        targetYaw -= deltaX * sensitivity
        targetPitch = min(1.5, max(-1.5, targetPitch + deltaY * sensitivity))
        wake()
    }

    /// Zoom the orbit camera in/out. `factor` > 1 zooms in.
    func zoomCamera(by factor: Double) {
        guard factor > 0 else { return }
        targetDistance = min(Self.maxDistance, max(Self.minDistance, targetDistance / factor))
        wake()
    }

    func resetCamera() {
        targetYaw = Self.defaultYaw
        targetPitch = Self.defaultPitch
        targetDistance = Self.defaultDistance
        wake()
    }

    /// Eases the live camera toward its target every frame -- "smooth
    /// camera movement" rather than snapping straight to the latest input.
    private func easeCamera(dt: Double) {
        let ease = min(1.0, dt * 10.0)
        yaw += (targetYaw - yaw) * ease
        pitch += (targetPitch - pitch) * ease
        distance += (targetDistance - distance) * ease
    }

    private func wake() {
        needsRedraw = true
        idleFrameCount = 0
        if metalView?.preferredFramesPerSecond != Self.activeFPS {
            metalView?.preferredFramesPerSecond = Self.activeFPS
        }
    }

    // MARK: - Camera basis

    private func cameraBasis() -> (eye: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) {
        let eye = SIMD3<Double>(
            distance * cos(pitch) * sin(yaw),
            distance * sin(pitch),
            distance * cos(pitch) * cos(yaw)
        )
        let forward = normalize(-eye)
        let worldUp = SIMD3<Double>(0, 1, 0)
        let right = normalize(cross(forward, worldUp))
        let up = cross(right, forward)
        return (
            SIMD3<Float>(eye), SIMD3<Float>(right), SIMD3<Float>(up), SIMD3<Float>(forward)
        )
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        wake()
    }

    func draw(in view: MTKView) {
        guard isReady, let pipeline, let drawable = view.currentDrawable else { return }
        let now = CACurrentMediaTime()
        easeCamera(dt: min(0.1, max(0, now - lastFrameTimestamp)))

        let active = isAnimating
        guard needsRedraw || active else {
            idleFrameCount += 1
            if idleFrameCount > 3, view.preferredFramesPerSecond != Self.idleFPS {
                view.preferredFramesPerSecond = Self.idleFPS
            }
            return
        }

        let dt = now - lastFrameTimestamp
        lastFrameTimestamp = now
        if dt > 0.5 { recentFrameTimesMs.removeAll() }
        updateFPS(frameSeconds: dt)

        let drawableSize = view.drawableSize
        guard drawableSize.width > 1, drawableSize.height > 1 else { return }

        let scale = (active ? min(0.5, renderResolution.scale) : renderResolution.scale) * quality.resolutionScale
        let width = max(8, Int(drawableSize.width * scale))
        let height = max(8, Int(drawableSize.height * scale))
        renderWidth = width
        renderHeight = height

        let raySteps = active ? max(24, quality.maxRaySteps / 2) : quality.maxRaySteps
        let aoEnabled = !active && quality.aoEnabled && aoOverrideEnabled
        let shadowsEnabled = !active && quality.shadowsEnabled && shadowsOverrideEnabled

        guard let outTex = makeStandaloneTexture(width: width, height: height) else { return }
        var params = makeParams(width: width, height: height, raySteps: raySteps, aoEnabled: aoEnabled, shadowsEnabled: shadowsEnabled)

        let start = CACurrentMediaTime()
        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(outTex, index: 0)
            encoder.setBytes(&params, length: MemoryLayout<MandelbulbParams>.stride, index: 0)
            dispatch(encoder: encoder, pipeline: pipeline, width: width, height: height)
            encoder.endEncoding()
        }
        blit(commandBuffer: commandBuffer, source: outTex, destination: drawable.texture)
        commandBuffer.addCompletedHandler { [weak self] _ in
            Task { @MainActor in
                self?.lastRenderTimeMs = (CACurrentMediaTime() - start) * 1000
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()

        needsRedraw = false
        if active {
            idleFrameCount = 0
            if view.preferredFramesPerSecond != Self.activeFPS {
                view.preferredFramesPerSecond = Self.activeFPS
            }
        } else {
            idleFrameCount += 1
            if idleFrameCount > 3, view.preferredFramesPerSecond != Self.idleFPS {
                view.preferredFramesPerSecond = Self.idleFPS
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

    private func makeParams(width: Int, height: Int, raySteps: Int, aoEnabled: Bool, shadowsEnabled: Bool) -> MandelbulbParams {
        let basis = cameraBasis()
        return MandelbulbParams(
            eyeX: basis.eye.x, eyeY: basis.eye.y, eyeZ: basis.eye.z,
            rightX: basis.right.x, rightY: basis.right.y, rightZ: basis.right.z,
            upX: basis.up.x, upY: basis.up.y, upZ: basis.up.z,
            forwardX: basis.forward.x, forwardY: basis.forward.y, forwardZ: basis.forward.z,
            width: UInt32(width), height: UInt32(height),
            tanHalfFov: Float(tan(fovRadians / 2)),
            power: Float(power),
            maxIterations: UInt32(iterations),
            maxRaySteps: UInt32(raySteps),
            epsilon: 0.0004,
            maxDistance: 16.0,
            variant: hollowVariant ? 1 : 0,
            aoEnabled: aoEnabled ? 1 : 0,
            shadowsEnabled: shadowsEnabled ? 1 : 0,
            lightAzimuth: Float(lightAzimuthDegrees * .pi / 180),
            lightElevation: Float(lightElevationDegrees * .pi / 180),
            ambientStrength: Float(ambientStrength)
        )
    }

    // MARK: - Shared helpers

    private func dispatch(encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let threadsPerThreadgroup = MTLSize(width: w, height: h, depth: 1)
        let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    }

    /// Upscales/downscales `source` into `destination` with a simple
    /// blit-style compute-free copy via a render-independent path: since
    /// both are plain 2D textures, a blit encoder handles same-size copies,
    /// but source and destination can differ in size (render resolution
    /// scale), so this goes through a tiny compute pass reusing the same
    /// bilinear sampling trick the 2D palette pass uses.
    private func blit(commandBuffer: MTLCommandBuffer, source: MTLTexture, destination: MTLTexture) {
        if source.width == destination.width, source.height == destination.height,
           let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOriginMake(0, 0, 0),
                              sourceSize: MTLSizeMake(source.width, source.height, 1),
                              to: destination, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 0, 0))
            blitEncoder.endEncoding()
            return
        }
        guard let resamplePipeline,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(resamplePipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        dispatch(encoder: encoder, pipeline: resamplePipeline, width: destination.width, height: destination.height)
        encoder.endEncoding()
    }

    private func makeStandaloneTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat = .bgra8Unorm) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)
    }

    // MARK: - Export

    /// Renders one full-quality frame at an arbitrary resolution (ignoring
    /// the live view's progressive/animating reductions) and hands back a
    /// `CGImage`, for the Save Screenshot / Export Render actions.
    func captureImage(size: CGSize, completion: @escaping (CGImage?) -> Void) {
        guard let pipeline else { completion(nil); return }
        let width = max(8, Int(size.width))
        let height = max(8, Int(size.height))
        guard let tex = makeStandaloneTexture(width: width, height: height, pixelFormat: .rgba8Unorm) else {
            completion(nil)
            return
        }
        var params = makeParams(width: width, height: height, raySteps: quality.maxRaySteps, aoEnabled: quality.aoEnabled && aoOverrideEnabled, shadowsEnabled: quality.shadowsEnabled && shadowsOverrideEnabled)
        guard let cb = queue.makeCommandBuffer(), let encoder = cb.makeComputeCommandEncoder() else {
            completion(nil)
            return
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(tex, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<MandelbulbParams>.stride, index: 0)
        dispatch(encoder: encoder, pipeline: pipeline, width: width, height: height)
        encoder.endEncoding()
        cb.addCompletedHandler { [weak self] _ in
            Task { @MainActor in
                completion(self?.cgImage(from: tex, width: width, height: height))
            }
        }
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
