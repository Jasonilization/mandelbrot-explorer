import SwiftUI

/// App shell: a native macOS tab bar switching between the 2D Mandelbrot
/// explorer and the 3D Mandelbulb explorer. They're deliberately separate,
/// independently-stateful experiences (each owns its own renderer) rather
/// than a shared mode within one view -- switching tabs doesn't reset or
/// interrupt whichever one you're not looking at.
struct RootView: View {
    var body: some View {
        TabView {
            ContentView()
                .tabItem {
                    Label("Mandelbrot", systemImage: "smoke")
                }
            MandelbulbContentView()
                .tabItem {
                    Label("Mandelbulb Explorer", systemImage: "cube.transparent")
                }
        }
    }
}
