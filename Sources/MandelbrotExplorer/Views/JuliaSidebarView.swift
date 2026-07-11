import SwiftUI

/// Julia tab's sidebar: everything about choosing/tuning the fixed c
/// parameter, plus the exact same rendering/color/export machinery the
/// Mandelbrot tab uses (see `FractalCommonSidebarSections`).
struct JuliaSidebarView: View {
    @ObservedObject var renderer: FractalRenderer
    @ObservedObject var recorder: FractalRecorder
    @State private var showingRecorder = false
    @State private var showingPaletteEditor = false
    @State private var exportResolution: ExportResolution = .default
    @State private var favorites: [JuliaFavorite] = JuliaFavoritesStore.load()
    @State private var newFavoriteName = ""
    @State private var showingSaveFavorite = false

    @State private var reText: String = ""
    @State private var imText: String = ""

    var body: some View {
        Form {
            Section("Julia Parameter (c)") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Real")
                    HStack {
                        TextField("", text: $reText)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitTextFields() }
                            .onChange(of: reText) { _, _ in commitTextFields() }
                        Slider(
                            value: Binding(get: { renderer.juliaC.x }, set: { setC(re: $0, im: renderer.juliaC.y) }),
                            in: -2...2
                        )
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Imaginary")
                    HStack {
                        TextField("", text: $imText)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitTextFields() }
                            .onChange(of: imText) { _, _ in commitTextFields() }
                        Slider(
                            value: Binding(get: { renderer.juliaC.y }, set: { setC(re: renderer.juliaC.x, im: $0) }),
                            in: -2...2
                        )
                    }
                }
                .help("Live-updates the canvas as you drag or type -- c is fixed for the whole image; every pixel explores a different starting z.")

                HStack {
                    Button {
                        setC(renderer.randomJuliaC())
                    } label: {
                        Label("Random Julia", systemImage: "shuffle")
                    }
                    Spacer()
                    Button("Reset View") {
                        renderer.autoIterationsEnabled = true
                        renderer.viewport = Viewport.julia()
                    }
                }

                Picker("Preset", selection: Binding<String>(
                    get: { "" },
                    set: { id in
                        guard let preset = JuliaPreset.all.first(where: { $0.id == id }) else { return }
                        setC(preset.c)
                    }
                )) {
                    Text("Choose a Julia set…").tag("")
                    ForEach(JuliaPreset.all) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
            }

            Section("Favorites") {
                if favorites.isEmpty {
                    Text("No favorites saved yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(favorites) { favorite in
                        Button {
                            setC(favorite.c)
                        } label: {
                            HStack {
                                Text(favorite.name)
                                Spacer()
                                Text(String(format: "%.4f, %.4fi", favorite.re, favorite.im))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove", role: .destructive) { removeFavorite(favorite) }
                        }
                    }
                    .onDelete(perform: removeFavorites)
                }
                Button {
                    newFavoriteName = defaultFavoriteName()
                    showingSaveFavorite = true
                } label: {
                    Label("Save Current as Favorite…", systemImage: "star")
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
        .onAppear { syncTextFields() }
        .onChange(of: renderer.juliaC.x) { _, _ in syncTextFields() }
        .onChange(of: renderer.juliaC.y) { _, _ in syncTextFields() }
        .sheet(isPresented: $showingRecorder) {
            RecordingView(renderer: renderer, recorder: recorder)
        }
        .sheet(isPresented: $showingPaletteEditor) {
            PaletteEditorView(renderer: renderer)
        }
        .sheet(isPresented: $showingSaveFavorite) {
            saveFavoriteSheet
        }
    }

    private var saveFavoriteSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Favorite Julia Set").font(.headline)
            TextField("Name", text: $newFavoriteName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveFavorite() }
            Text(String(format: "c = %.6f, %.6fi", renderer.juliaC.x, renderer.juliaC.y))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showingSaveFavorite = false }
                Button("Save") { saveFavorite() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newFavoriteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    /// Only accepts fully-parseable text, so an in-progress edit (an empty
    /// field, a bare "-") doesn't reset the canvas to 0 mid-keystroke --
    /// this is what makes typing feel "live update" without fighting the
    /// user over invalid intermediate states.
    private func commitTextFields() {
        guard let re = Double(reText), let im = Double(imText) else { return }
        renderer.juliaC = SIMD2(re, im)
    }

    private func setC(_ c: SIMD2<Double>) {
        setC(re: c.x, im: c.y)
    }

    private func setC(re: Double, im: Double) {
        renderer.juliaC = SIMD2(re, im)
    }

    private func syncTextFields() {
        reText = trimmed(renderer.juliaC.x)
        imText = trimmed(renderer.juliaC.y)
    }

    private func trimmed(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private func defaultFavoriteName() -> String {
        String(format: "Julia (%.3f, %.3fi)", renderer.juliaC.x, renderer.juliaC.y)
    }

    private func saveFavorite() {
        let trimmedName = newFavoriteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        favorites.append(JuliaFavorite(name: trimmedName, re: renderer.juliaC.x, im: renderer.juliaC.y))
        JuliaFavoritesStore.save(favorites)
        showingSaveFavorite = false
    }

    private func removeFavorite(_ favorite: JuliaFavorite) {
        favorites.removeAll { $0.id == favorite.id }
        JuliaFavoritesStore.save(favorites)
    }

    private func removeFavorites(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        JuliaFavoritesStore.save(favorites)
    }
}
