import SwiftUI

struct SidebarView: View {
    @ObservedObject var renderer: FractalRenderer
    @ObservedObject var recorder: FractalRecorder
    @State private var iterationsText: String = ""
    @State private var showingRecorder = false

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
            }

            Section("Rendering") {
                Stepper(value: Binding(
                    get: { renderer.maxIterations },
                    set: { renderer.autoIterationsEnabled = false; renderer.maxIterations = $0 }
                ), in: 50...20000, step: 50) {
                    HStack {
                        Text("Iterations")
                        Spacer()
                        Text("\(renderer.maxIterations)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if renderer.autoIterationsEnabled {
                            Text("auto")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                LabeledContent("Precision Tier") {
                    Text(renderer.currentTierLabel)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Precision Budget") {
                    Text("~\(Int(Double(renderer.viewport.precisionTerms) * 15.5)) digits")
                        .foregroundStyle(.secondary)
                }

                if renderer.viewport.tier == .perturbation, renderer.referenceOrbitIterations > 0 {
                    LabeledContent("Series Approximation") {
                        Text(renderer.seriesApproximationSkip > 0
                             ? "\(renderer.seriesApproximationSkip) / \(renderer.referenceOrbitIterations) skipped"
                             : "not engaged")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Auto Zoom") {
                Toggle("Smart Auto Zoom", isOn: $renderer.isAutoZooming)
                    .disabled(renderer.isInputLocked)

                VStack(alignment: .leading) {
                    Text("Speed")
                    Slider(value: $renderer.autoZoomSpeed, in: 1.03...1.6)
                }
                .disabled(renderer.isInputLocked)

                if renderer.isAutoZooming {
                    Label(
                        renderer.isAutoZoomSearching ? "Searching for detail…" : "Steering toward detail",
                        systemImage: renderer.isAutoZoomSearching ? "binoculars" : "scope"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Recording") {
                Button {
                    showingRecorder = true
                } label: {
                    Label("Record Zoom Journey…", systemImage: "video.badge.waveform")
                }
                .disabled(!renderer.isReady)
                if recorder.isActive {
                    Label("Recording in progress", systemImage: "record.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Color") {
                Picker("Palette", selection: $renderer.palette) {
                    ForEach(ColorPalette.all) { p in
                        Text(p.name).tag(p)
                    }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading) {
                    Text("Color Scale")
                    Slider(value: $renderer.colorScale, in: 0.1...5.0)
                }
                VStack(alignment: .leading) {
                    Text("Color Offset")
                    Slider(value: $renderer.colorOffset, in: 0...1)
                }
            }

            Section("Export") {
                Button {
                    SaveImageAction.run(renderer: renderer)
                } label: {
                    Label("Save Image…", systemImage: "square.and.arrow.down")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 260, idealWidth: 280)
        .sheet(isPresented: $showingRecorder) {
            RecordingView(renderer: renderer, recorder: recorder)
        }
    }
}
