import SwiftUI

struct ContentView: View {
    @StateObject private var renderer = FractalRenderer()

    var body: some View {
        NavigationSplitView {
            SidebarView(renderer: renderer)
        } detail: {
            VStack(spacing: 0) {
                ZStack {
                    MetalCanvasView(renderer: renderer)
                    if !renderer.isReady {
                        LoadingOverlay()
                            .transition(.opacity)
                    }
                }
                StatusBarView(renderer: renderer)
            }
        }
        .navigationTitle("Mandelbrot Explorer")
        .animation(.easeOut(duration: 0.25), value: renderer.isReady)
    }
}

/// Covers the canvas while the Metal shader library compiles (see
/// `FractalRenderer.buildPipelinesAsync`), so launch reads as "loading"
/// rather than a stuck black window.
private struct LoadingOverlay: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Preparing renderer…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.05, green: 0.055, blue: 0.07))
    }
}
