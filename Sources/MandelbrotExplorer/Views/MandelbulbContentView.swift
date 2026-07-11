import AppKit
import SwiftUI

/// The Mandelbulb tab's root view -- a separate 3D ray-marched explorer
/// living alongside (not replacing) the 2D Mandelbrot explorer in
/// `ContentView`. Deliberately mirrors that view's structure (sidebar +
/// canvas + status bar inside a `NavigationSplitView`, a loading overlay
/// until shaders finish compiling, the same toolbar) so the two tabs read
/// as one integrated app rather than two bolted-together experiences.
struct MandelbulbContentView: View {
    @StateObject private var renderer = MandelbulbRenderer()
    @State private var showingHelp = false

    var body: some View {
        NavigationSplitView {
            MandelbulbSidebarView(renderer: renderer)
        } detail: {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    MandelbulbCanvasView(renderer: renderer)
                    if !renderer.isReady {
                        MandelbulbLoadingOverlay()
                            .transition(.opacity)
                    }
                }
                MandelbulbStatusBarView(renderer: renderer)
            }
        }
        .navigationTitle("Mandelbulb Explorer")
        .animation(.easeOut(duration: 0.25), value: renderer.isReady)
        .toolbar {
            AppToolbarButtons(showingHelp: $showingHelp)
        }
        .sheet(isPresented: $showingHelp) {
            HelpView()
        }
    }
}

private struct MandelbulbLoadingOverlay: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Preparing ray marcher…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.015, green: 0.015, blue: 0.035))
    }
}
