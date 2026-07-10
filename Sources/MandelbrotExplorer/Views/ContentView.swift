import SwiftUI

struct ContentView: View {
    @StateObject private var renderer = FractalRenderer()

    var body: some View {
        NavigationSplitView {
            SidebarView(renderer: renderer)
        } detail: {
            VStack(spacing: 0) {
                MetalCanvasView(renderer: renderer)
                StatusBarView(renderer: renderer)
            }
        }
        .navigationTitle("Mandelbrot Explorer")
    }
}
