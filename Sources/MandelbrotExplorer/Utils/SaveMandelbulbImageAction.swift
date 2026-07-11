import AppKit
import UniformTypeIdentifiers

/// Mirrors `SaveImageAction` for the Mandelbulb explorer: renders one
/// full-quality frame at the chosen resolution and writes it to a PNG the
/// user picks a location for. Used for both "Save Screenshot" (current
/// camera, quick) and "Export Render" (larger resolution) in the sidebar --
/// they're the same underlying action at different default sizes.
@MainActor
enum SaveMandelbulbImageAction {
    static func run(renderer: MandelbulbRenderer, resolution: ExportResolution) {
        renderer.captureImage(size: resolution.size) { cgImage in
            guard let cgImage else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "mandelbulb.png"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }

            let rep = NSBitmapImageRep(cgImage: cgImage)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: url)
        }
    }
}
