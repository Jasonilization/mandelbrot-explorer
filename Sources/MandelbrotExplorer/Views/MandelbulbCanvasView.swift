import AppKit
import MetalKit
import SwiftUI

/// Bridges an `MTKView` into SwiftUI for the Mandelbulb explorer. Mirrors
/// `MetalCanvasView`'s structure, but drag orbits the camera around the
/// fractal instead of panning a 2D viewport, and scroll/pinch move the
/// camera's orbit distance instead of a zoom factor.
struct MandelbulbCanvasView: NSViewRepresentable {
    @ObservedObject var renderer: MandelbulbRenderer

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer)
    }

    func makeNSView(context: Context) -> InteractiveMandelbulbView {
        let view = InteractiveMandelbulbView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.coordinator = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 120
        view.autoResizeDrawable = true
        view.clearColor = MTLClearColorMake(0.015, 0.015, 0.035, 1.0)
        (view.layer as? CAMetalLayer)?.framebufferOnly = false
        renderer.metalView = view
        return view
    }

    func updateNSView(_ nsView: InteractiveMandelbulbView, context: Context) {}

    @MainActor
    final class Coordinator {
        let renderer: MandelbulbRenderer
        private var lastDragPoint: CGPoint?

        init(renderer: MandelbulbRenderer) {
            self.renderer = renderer
        }

        func mouseDown(at point: CGPoint) {
            lastDragPoint = point
            renderer.markInteractionBegan()
        }

        func mouseDragged(to point: CGPoint) {
            defer { lastDragPoint = point }
            guard let last = lastDragPoint else { return }
            renderer.orbit(deltaX: Double(point.x - last.x), deltaY: Double(point.y - last.y))
        }

        func mouseUp() {
            lastDragPoint = nil
            renderer.markInteractionEnded()
        }

        func scroll(deltaY: CGFloat) {
            guard deltaY != 0 else { return }
            renderer.markInteractionBegan()
            renderer.zoomCamera(by: pow(1.02, Double(deltaY)))
            renderer.markInteractionEnded()
        }

        func magnify(delta: CGFloat) {
            renderer.markInteractionBegan()
            renderer.zoomCamera(by: max(0.05, 1.0 + delta))
            renderer.markInteractionEnded()
        }
    }
}

final class InteractiveMandelbulbView: MTKView {
    weak var coordinator: MandelbulbCanvasView.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        coordinator?.mouseDown(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        coordinator?.mouseDragged(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        coordinator?.mouseUp()
    }

    override func scrollWheel(with event: NSEvent) {
        coordinator?.scroll(deltaY: event.scrollingDeltaY)
    }

    override func magnify(with event: NSEvent) {
        coordinator?.magnify(delta: event.magnification)
    }
}
