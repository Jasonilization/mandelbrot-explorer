import SwiftUI

struct MandelbulbSidebarView: View {
    @ObservedObject var renderer: MandelbulbRenderer
    @State private var exportResolution: ExportResolution = .default

    var body: some View {
        Form {
            Section("Presets") {
                Picker("Preset", selection: Binding<String>(
                    get: { "" },
                    set: { id in
                        guard let preset = MandelbulbPreset.all.first(where: { $0.id == id }) else { return }
                        renderer.power = preset.power
                        renderer.hollowVariant = preset.hollowVariant
                        renderer.resetCamera()
                    }
                )) {
                    Text("Choose a form…").tag("")
                    ForEach(MandelbulbPreset.all) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                if let selected = MandelbulbPreset.all.first(where: { $0.power == renderer.power && $0.hollowVariant == renderer.hollowVariant }) {
                    Text(selected.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Fractal") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Power")
                        Spacer()
                        Text(String(format: "%.1f", renderer.power)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $renderer.power, in: 2...16, step: 0.5)
                }
                .help("The Mandelbulb's exponent -- z, y, z → r^power · (spherical angles × power) + c. 8 is the canonical form; lower values look more organic, higher values sharper and spikier.")

                Stepper(value: $renderer.iterations, in: 3...20) {
                    HStack {
                        Text("Detail (Iterations)")
                        Spacer()
                        Text("\(renderer.iterations)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .help("How many times the distance-estimator formula iterates per sample. Higher resolves finer surface detail at a performance cost.")

                Toggle("Hollow Variant", isOn: $renderer.hollowVariant)
                    .help("Applies an abs-transform to the fractal formula, carving hollow, shell-like cavities into the surface.")
            }

            Section("Quality") {
                Picker("Quality", selection: $renderer.quality) {
                    ForEach(MandelbulbQuality.allCases) { q in
                        Text(q.rawValue).tag(q)
                    }
                }
                .help(renderer.quality.helpText)

                Picker("Render Resolution", selection: $renderer.renderResolution) {
                    ForEach(RenderResolution.allCases) { res in
                        Text(res.rawValue).tag(res)
                    }
                }
                .help("Internal render scale for the live canvas, independent of window size.")

                Toggle("Ambient Occlusion", isOn: $renderer.aoOverrideEnabled)
                    .help("Darkens crevices and tight surface folds for a stronger sense of depth. Only takes effect once the current quality tier allows it.")
                Toggle("Soft Shadows", isOn: $renderer.shadowsOverrideEnabled)
                    .help("Casts soft shadows from the surface's own geometry. Only takes effect once the current quality tier allows it.")
            }

            Section("Lighting") {
                VStack(alignment: .leading) {
                    Text("Light Direction")
                    Slider(value: $renderer.lightAzimuthDegrees, in: 0...360)
                }
                VStack(alignment: .leading) {
                    Text("Light Elevation")
                    Slider(value: $renderer.lightElevationDegrees, in: 5...90)
                }
                VStack(alignment: .leading) {
                    Text("Ambient Strength")
                    Slider(value: $renderer.ambientStrength, in: 0...1)
                }
            }

            Section("Camera") {
                Button {
                    renderer.resetCamera()
                } label: {
                    Label("Reset Camera", systemImage: "arrow.counterclockwise")
                }
            }

            Section("Export") {
                Picker("Resolution", selection: $exportResolution) {
                    ForEach(ExportResolution.all) { res in
                        Text(res.label).tag(res)
                    }
                }
                Button {
                    SaveMandelbulbImageAction.run(renderer: renderer, resolution: exportResolution)
                } label: {
                    Label("Save Screenshot…", systemImage: "camera")
                }
                Button {
                    SaveMandelbulbImageAction.run(renderer: renderer, resolution: ExportResolution.all.first(where: { $0.id == "uhd4k" }) ?? exportResolution)
                } label: {
                    Label("Export Render (4K)…", systemImage: "square.and.arrow.up")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 260, idealWidth: 280)
    }
}
