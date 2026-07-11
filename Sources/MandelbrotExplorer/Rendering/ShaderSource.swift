import Foundation

/// Loads Shaders.metal's source text so it can be compiled at runtime via
/// `MTLDevice.makeLibrary(source:options:)`. Shared by both `FractalRenderer`
/// (2D Mandelbrot) and `MandelbulbRenderer` (3D ray marcher) -- both kernel
/// families live in the same source file and are compiled into independent
/// libraries, one per renderer.
enum ShaderSource {
    static func load() -> String {
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
}
