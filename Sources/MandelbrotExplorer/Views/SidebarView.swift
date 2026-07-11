import SwiftUI

struct SidebarView: View {
    @ObservedObject var renderer: FractalRenderer
    @ObservedObject var recorder: FractalRecorder
    /// See `ContentView.onExploreJulia`.
    var onExploreJulia: ((SIMD2<Double>) -> Void)? = nil
    @State private var showingRecorder = false
    @State private var showingPaletteEditor = false
    @State private var exportResolution: ExportResolution = .default

    var body: some View {
        Form {
            Section("Location") {
                Picker("Preset", selection: Binding<String>(
                    get: { "" },
                    set: { id in
                        guard let preset = Preset.all.first(where: { $0.id == id }) else { return }
                        renderer.autoIterationsEnabled = true
                        renderer.viewport = preset.makeViewport()
                        renderer.maxIterations = preset.suggestedIterations
                    }
                )) {
                    Text("Choose a location…").tag("")
                    ForEach(Preset.all) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }

                Button("Reset View") {
                    renderer.autoIterationsEnabled = true
                    renderer.viewport.reset()
                }

                if let onExploreJulia {
                    Button {
                        onExploreJulia(renderer.viewport.centerApprox)
                    } label: {
                        Label("Open Julia Set at Center", systemImage: "atom")
                    }
                    .help("Explore the Julia set for c = the current view's center point. Double-clicking anywhere on the canvas does the same for that exact point.")
                }
            }

            FractalCommonSidebarSections(
                renderer: renderer,
                recorder: recorder,
                showingRecorder: $showingRecorder,
                showingPaletteEditor: $showingPaletteEditor,
                exportResolution: $exportResolution
            )
        }
        .formStyle(.grouped)
        .frame(minWidth: 260, idealWidth: 280)
        .sheet(isPresented: $showingRecorder) {
            RecordingView(renderer: renderer, recorder: recorder)
        }
        .sheet(isPresented: $showingPaletteEditor) {
            PaletteEditorView(renderer: renderer)
        }
    }
}
