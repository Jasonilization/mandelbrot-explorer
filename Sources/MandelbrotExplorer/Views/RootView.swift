import SwiftUI

/// App shell: a native macOS tab bar switching between the 2D Mandelbrot
/// explorer, the Julia Set explorer, and the 3D Mandelbulb explorer. They're
/// deliberately separate, independently-stateful experiences (each owns its
/// own renderer) rather than a shared mode within one view -- switching tabs
/// doesn't reset or interrupt whichever one you're not looking at.
///
/// The Mandelbrot and Julia renderers are owned here, one level up from
/// their own tabs, specifically so double-clicking a point in the
/// Mandelbrot set (or its sidebar's explicit button) can hand that point's
/// coordinate to the Julia renderer as its `c` and switch tabs to it --
/// something neither tab's own view could do while only holding its own
/// renderer.
struct RootView: View {
    @StateObject private var mandelbrotRenderer = FractalRenderer(kind: .mandelbrot)
    @StateObject private var juliaRenderer = FractalRenderer(kind: .julia)
    @State private var selection: Tab = .mandelbrot

    private enum Tab: Hashable {
        case mandelbrot, julia, mandelbulb
    }

    var body: some View {
        TabView(selection: $selection) {
            ContentView(renderer: mandelbrotRenderer, onExploreJulia: exploreJulia)
                .tabItem {
                    Label("Mandelbrot", systemImage: "smoke")
                }
                .tag(Tab.mandelbrot)
            JuliaContentView(renderer: juliaRenderer)
                .tabItem {
                    Label("Julia Set", systemImage: "atom")
                }
                .tag(Tab.julia)
            MandelbulbContentView()
                .tabItem {
                    Label("Mandelbulb Explorer", systemImage: "cube.transparent")
                }
                .tag(Tab.mandelbulb)
        }
    }

    private func exploreJulia(c: SIMD2<Double>) {
        juliaRenderer.juliaC = c
        juliaRenderer.autoIterationsEnabled = true
        juliaRenderer.viewport = Viewport.julia()
        selection = .julia
    }
}
