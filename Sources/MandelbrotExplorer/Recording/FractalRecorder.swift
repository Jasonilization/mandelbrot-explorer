import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia

/// Drives an offline, deterministic zoom journey through `FractalRenderer`
/// and encodes each frame straight to an H.264 .mov file via `AVAssetWriter`.
///
/// Frames are paced by simulated time (`1 / fps` per frame), not wall clock:
/// each frame renders at full quality regardless of how long that takes, so
/// the *output* video is always smooth even though *producing* it can take
/// far longer than its own runtime at extreme zoom -- exactly like every
/// other deep-zoom fractal renderer. Recording takes over the live viewport
/// (the on-screen view mirrors progress) rather than running a second,
/// independent render pipeline, which keeps this implementation simple at
/// the cost of interaction being paused for the duration; the UI makes that
/// trade-off explicit rather than silently blocking input.
@MainActor
final class FractalRecorder: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case finishing
        case finished(URL)
        case failed(String)
        case cancelled
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentFrame: Int = 0
    @Published private(set) var totalFrames: Int = 0

    var progress: Double {
        totalFrames > 0 ? Double(currentFrame) / Double(totalFrames) : 0
    }

    var isActive: Bool {
        switch phase {
        case .recording, .finishing: true
        default: false
        }
    }

    private var cancelRequested = false

    func cancel() {
        cancelRequested = true
    }

    func reset() {
        phase = .idle
        currentFrame = 0
        totalFrames = 0
    }

    func start(renderer: FractalRenderer, settings: RecordingSettings, outputURL: URL) {
        guard !isActive else { return }
        cancelRequested = false
        currentFrame = 0
        totalFrames = settings.totalFrames
        phase = .recording
        Task { await self.run(renderer: renderer, settings: settings, outputURL: outputURL) }
    }

    private func run(renderer: FractalRenderer, settings: RecordingSettings, outputURL: URL) async {
        let size = settings.resolution.size
        let width = Int(size.width)
        let height = Int(size.height)
        let startingViewport = renderer.viewport

        renderer.isInputLocked = true
        renderer.isAutoZooming = false // recording drives the same viewport itself; don't let both steer at once
        defer {
            renderer.isInputLocked = false
            renderer.viewport = startingViewport
        }

        try? FileManager.default.removeItem(at: outputURL)

        guard let (writer, input, adaptor) = Self.makeWriter(outputURL: outputURL, width: width, height: height) else {
            phase = .failed("Could not create the video file at that location.")
            return
        }
        guard writer.startWriting() else {
            phase = .failed(writer.error?.localizedDescription ?? "Could not start writing the video file.")
            return
        }
        writer.startSession(atSourceTime: .zero)

        var lastSnapshot: (values: [Float], width: Int, height: Int)?
        let dt = 1.0 / Double(settings.fps)
        renderer.resetAutoZoomSteering()

        for frameIndex in 0..<settings.totalFrames {
            if cancelRequested {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                phase = .cancelled
                return
            }

            if frameIndex > 0 {
                renderer.updateAutoZoomSteering(snapshot: lastSnapshot)
                if !renderer.advanceAutoZoom(dt: dt, viewSize: size) {
                    break // hit the precision floor -- stop early rather than encode a frozen tail
                }
            }

            guard let (image, values) = await captureFrame(renderer: renderer, size: size) else {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                phase = .failed("A frame failed to render.")
                return
            }
            lastSnapshot = values.map { (values: $0, width: width, height: height) }

            let overlayText = settings.showZoomOverlay ? Self.zoomLabel(for: renderer.viewport.zoomFactor) : nil
            guard let pixelBuffer = Self.makePixelBuffer(from: image, pool: adaptor.pixelBufferPool, width: width, height: height, overlayText: overlayText) else {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                phase = .failed("Could not prepare a video frame.")
                return
            }

            while !input.isReadyForMoreMediaData && !cancelRequested {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let pts = CMTime(value: Int64(frameIndex), timescale: Int32(settings.fps))
            adaptor.append(pixelBuffer, withPresentationTime: pts)

            currentFrame = frameIndex + 1
        }

        phase = .finishing
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .completed {
            phase = .finished(outputURL)
        } else {
            phase = .failed(writer.error?.localizedDescription ?? "Recording failed.")
        }
    }

    private func captureFrame(renderer: FractalRenderer, size: CGSize) async -> (CGImage, [Float]?)? {
        await withCheckedContinuation { continuation in
            renderer.captureFrameForRecording(size: size) { image, values in
                guard let image else { continuation.resume(returning: nil); return }
                continuation.resume(returning: (image, values))
            }
        }
    }

    private static func zoomLabel(for zoom: Double) -> String {
        zoom < 1000 ? String(format: "%.1f×", zoom) : String(format: "%.2e×", zoom)
    }

    // MARK: - AVFoundation plumbing

    private static func makeWriter(outputURL: URL, width: Int, height: Int) -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor)? {
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mov) else { return nil }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                // ~8 bits/pixel/frame: comfortably lossless-looking for the
                // smooth gradients and fine banding this renderer produces,
                // at any of the offered resolutions.
                AVVideoAverageBitRateKey: width * height * 8,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        return (writer, input, adaptor)
    }

    /// Composites the rendered frame (and optional overlay) into a
    /// BGRA `CVPixelBuffer`. The context is flipped immediately after
    /// creation: a raw `CGContext` over pixel buffer memory places row 0 at
    /// the geometric *bottom* (standard Quartz convention), but video
    /// scanlines are top-down, so without the flip every exported frame
    /// would be upside down.
    private static func makePixelBuffer(from image: CGImage, pool: CVPixelBufferPool?, width: Int, height: Int, overlayText: String?) -> CVPixelBuffer? {
        var pixelBufferOut: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBufferOut)
        }
        if pixelBufferOut == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBufferOut)
        }
        guard let pixelBuffer = pixelBufferOut else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        if let overlayText {
            // `translateBy`+`scaleBy` with y-negation is its own inverse
            // (F(F(p)) = p), so re-applying the exact same pair on top of
            // the CTM above cancels it back to the context's native
            // bottom-left-origin, y-up space -- exactly what
            // `NSGraphicsContext(flipped: false)` and `NSAttributedString`
            // baseline layout expect. Without this, text drawn through the
            // outer flip comes out rotated 180°.
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            drawOverlay("Zoom: \(overlayText)", in: context, width: width, height: height)
            context.restoreGState()
        }

        return pixelBuffer
    }

    /// Draws the zoom-level pill in the context's native (unflipped,
    /// bottom-left-origin) coordinate space -- see the call site above for
    /// why that's the space this needs to run in.
    private static func drawOverlay(_ text: String, in context: CGContext, width: Int, height: Int) {
        let fontSize = CGFloat(max(18, width / 60))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        let textSize = string.size()
        let margin = fontSize
        let padding = fontSize * 0.5
        let boxSize = CGSize(width: textSize.width + padding * 2, height: textSize.height + padding * 2)
        // "Top" of the frame as the viewer sees it is *high* y in this
        // native (y-up) space.
        let boxOrigin = CGPoint(x: margin, y: CGFloat(height) - margin - boxSize.height)

        context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        let path = CGPath(roundedRect: CGRect(origin: boxOrigin, size: boxSize), cornerWidth: padding, cornerHeight: padding, transform: nil)
        context.addPath(path)
        context.fillPath()

        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        string.draw(at: CGPoint(x: boxOrigin.x + padding, y: boxOrigin.y + padding))
        NSGraphicsContext.restoreGraphicsState()
    }
}
