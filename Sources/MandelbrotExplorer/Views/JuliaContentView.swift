import AppKit
import SwiftUI

/// The Julia Set Explorer tab: c is fixed (tuned from the sidebar or handed
/// off by double-clicking a point in the Mandelbrot tab), and every pixel
/// explores a different starting z. Structurally a near-mirror of
/// `ContentView` -- both are thin shells around the exact same
/// `FractalRenderer` engine, differing only in which sidebar (and which
/// "where am I" controls) they show.
struct JuliaContentView: View {
    @ObservedObject var renderer: FractalRenderer
    @StateObject private var recorder = FractalRecorder()
    @State private var showingHelp = false

    var body: some View {
        NavigationSplitView {
            JuliaSidebarView(renderer: renderer, recorder: recorder)
        } detail: {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    MetalCanvasView(renderer: renderer)
                    if !renderer.isReady {
                        LoadingOverlay()
                            .transition(.opacity)
                    }
                    if recorder.isActive {
                        RecordingBanner(recorder: recorder)
                            .padding(.top, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                StatusBarView(renderer: renderer)
            }
        }
        .navigationTitle("Julia Set Explorer")
        .animation(.easeOut(duration: 0.25), value: renderer.isReady)
        .animation(.easeOut(duration: 0.25), value: recorder.isActive)
        .toolbar {
            AppToolbarButtons(showingHelp: $showingHelp)
        }
        .sheet(isPresented: $showingHelp) {
            HelpView()
        }
    }
}
