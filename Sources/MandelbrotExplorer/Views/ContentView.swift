import SwiftUI

struct ContentView: View {
    @StateObject private var renderer = FractalRenderer()
    @StateObject private var recorder = FractalRecorder()

    var body: some View {
        NavigationSplitView {
            SidebarView(renderer: renderer, recorder: recorder)
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
        .navigationTitle("Mandelbrot Explorer")
        .animation(.easeOut(duration: 0.25), value: renderer.isReady)
        .animation(.easeOut(duration: 0.25), value: recorder.isActive)
    }
}

/// A small "recording in progress" pill over the canvas so it's obvious
/// interaction is paused even if the settings sheet has been dismissed.
private struct RecordingBanner: View {
    @ObservedObject var recorder: FractalRecorder

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text("Recording frame \(recorder.currentFrame) of \(recorder.totalFrames)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
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
