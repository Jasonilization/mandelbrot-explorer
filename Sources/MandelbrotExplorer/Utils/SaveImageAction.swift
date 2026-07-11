import AppKit
import UniformTypeIdentifiers

@MainActor
enum SaveImageAction {
    static func run(renderer: FractalRenderer, resolution: ExportResolution = .default) {
        renderer.captureFullQualityImage(size: resolution.size) { cgImage in
            guard let cgImage else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "mandelbrot.png"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }

            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: url)
        }
    }
}
