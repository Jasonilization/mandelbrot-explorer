import SwiftUI

struct SidebarView: View {
    @ObservedObject var renderer: FractalRenderer
    @State private var iterationsText: String = ""

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
    }
}
