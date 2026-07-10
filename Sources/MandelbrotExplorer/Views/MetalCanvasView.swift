import AppKit
import MetalKit
import SwiftUI

/// Bridges an `MTKView` into SwiftUI and translates raw AppKit mouse/scroll
/// events into viewport pan/zoom. Mouse wheel = zoom (centered on cursor),
/// click + drag = pan, trackpad pinch = zoom as a bonus.
struct MetalCanvasView: NSViewRepresentable {
    @ObservedObject var renderer: FractalRenderer

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer)
    }

    func makeNSView(context: Context) -> InteractiveMTKView {
        let view = InteractiveMTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.coordinator = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        // Adaptive frame rate: runs at up to 120Hz while active and drops to
        // a slow heartbeat once settled -- never fully paused, so the view
        // can't get stuck. See FractalRenderer.wake() / the tail of draw(in:).
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 120
        view.autoResizeDrawable = true
        // A dark neutral rather than pure black: while the shader library is
        // still compiling (nothing presented yet), this reads as "a dark
        // panel that's about to show something" rather than a dead/crashed
        // window. The SwiftUI loading overlay in ContentView sits on top of
        // it either way.
        view.clearColor = MTLClearColorMake(0.05, 0.055, 0.07, 1.0)
        (view.layer as? CAMetalLayer)?.framebufferOnly = false
        renderer.metalView = view
        return view
    }

    func updateNSView(_ nsView: InteractiveMTKView, context: Context) {}

    @MainActor
    final class Coordinator {
        let renderer: FractalRenderer
        private var lastDragPoint: CGPoint?

        init(renderer: FractalRenderer) {
            self.renderer = renderer
        }

        func mouseDown(at point: CGPoint) {
            guard !renderer.isInputLocked else { return }
            lastDragPoint = point
            renderer.markInteractionBegan()
        }

        func mouseDragged(to point: CGPoint) {
            defer { lastDragPoint = point }
            guard !renderer.isInputLocked else { return }
            guard let last = lastDragPoint else { return }
            let dx = point.x - last.x
            let dyAppKit = point.y - last.y
            let width = renderer.renderWidth > 0 ? Double(renderer.renderWidth) : 1
            renderer.viewport.pan(dxPixels: Double(dx), dyPixels: Double(-dyAppKit), viewWidthPixels: width)
        }

        func mouseUp() {
            lastDragPoint = nil
            guard !renderer.isInputLocked else { return }
            renderer.markInteractionEnded()
        }

        func scroll(deltaY: CGFloat, appKitLocation: CGPoint, viewSize: CGSize) {
            guard !renderer.isInputLocked, deltaY != 0 else { return }
            renderer.markInteractionBegan()
            let factor = pow(1.0035, Double(deltaY) * 6.0)
            let rawPoint = CGPoint(x: appKitLocation.x, y: viewSize.height - appKitLocation.y)
            let imageSpacePoint = renderer.detailLockedZoomPivot(for: rawPoint, viewSize: viewSize)
            renderer.viewport.zoom(by: factor, aroundScreenPoint: imageSpacePoint, viewSize: viewSize)
            renderer.markInteractionEnded()
        }

        func magnify(delta: CGFloat, appKitLocation: CGPoint, viewSize: CGSize) {
            guard !renderer.isInputLocked else { return }
            renderer.markInteractionBegan()
            let factor = max(0.05, 1.0 + delta)
            let rawPoint = CGPoint(x: appKitLocation.x, y: viewSize.height - appKitLocation.y)
            let imageSpacePoint = renderer.detailLockedZoomPivot(for: rawPoint, viewSize: viewSize)
            renderer.viewport.zoom(by: factor, aroundScreenPoint: imageSpacePoint, viewSize: viewSize)
            renderer.markInteractionEnded()
        }
    }
}

final class InteractiveMTKView: MTKView {
    weak var coordinator: MetalCanvasView.Coordinator?

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
        let p = convert(event.locationInWindow, from: nil)
        coordinator?.scroll(deltaY: event.scrollingDeltaY, appKitLocation: p, viewSize: bounds.size)
    }

    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        coordinator?.magnify(delta: event.magnification, appKitLocation: p, viewSize: bounds.size)
    }
}
