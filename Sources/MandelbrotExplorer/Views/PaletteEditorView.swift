import SwiftUI

/// Full gradient editor for the active palette: add/remove/reposition
/// stops, tune each stop's color (both a system `ColorPicker` and compact
/// HSB sliders), edit the interior color, and save the result as a new
/// custom palette. Edits apply to `renderer.palette` live as they're made
/// (rather than only on "Done"), so the canvas behind this sheet always
/// shows exactly what the current draft looks like.
struct PaletteEditorView: View {
    @ObservedObject var renderer: FractalRenderer
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ColorPalette
    @State private var originalPalette: ColorPalette
    @State private var newPaletteName = ""
    @State private var showingSaveSheet = false

    init(renderer: FractalRenderer) {
        self.renderer = renderer
        _draft = State(initialValue: renderer.palette)
        _originalPalette = State(initialValue: renderer.palette)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Palette Editor", systemImage: "paintpalette")
                    .font(.title3.bold())
                Spacer()
                Text(draft.name)
                    .foregroundStyle(.secondary)
            }

            PaletteGradientPreview(palette: draft, height: 36)
                .help("Live preview -- edits below apply to the canvas immediately.")

            ScrollView {
                VStack(spacing: 10) {
                    ForEach($draft.stops) { $stop in
                        stopRow($stop)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 280)

            HStack {
                Button {
                    addStop()
                } label: {
                    Label("Add Stop", systemImage: "plus.circle")
                }
                .help("Inserts a new stop at the midpoint of the largest gap in the gradient.")
                Spacer()
                Text("\(draft.stops.count) stops")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("Interior Color")
                Spacer()
                ColorPicker("", selection: Binding(
                    get: { draft.interiorColor.color },
                    set: { draft.interiorColor = ColorStop(position: 0, color: $0) }
                ))
                .labelsHidden()
                .frame(width: 60)
            }
            .help("Solid color used for points that never escape (the interior of the set).")

            Divider()

            HStack {
                Button("Reset to Default") { draft = originalPalette }
                    .disabled(draft == originalPalette)
                Spacer()
                Button("Save As New Palette…") { showingSaveSheet = true }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 560)
        .onChange(of: draft) { _, newValue in
            renderer.palette = newValue
        }
        .sheet(isPresented: $showingSaveSheet) {
            saveSheet
        }
    }

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save As New Palette").font(.headline)
            TextField("Palette name", text: $newPaletteName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveAsNew() }
            HStack {
                Spacer()
                Button("Cancel") { showingSaveSheet = false }
                Button("Save") { saveAsNew() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newPaletteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func stopRow(_ stop: Binding<ColorStop>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ColorPicker("", selection: Binding(
                    get: { stop.wrappedValue.color },
                    set: { stop.wrappedValue = ColorStop(position: stop.wrappedValue.position, color: $0) }
                ))
                .labelsHidden()
                .frame(width: 32)

                Slider(value: stop.position, in: 0...0.999)
                    .help("Position around the gradient cycle.")
                Text(String(format: "%.2f", stop.wrappedValue.position))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)

                Button {
                    draft.stops.removeAll { $0.id == stop.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(draft.stops.count <= 2)
                .help("Remove this stop (at least 2 must remain).")
            }
            hsbSliders(stop)
        }
        .padding(8)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func hsbSliders(_ stop: Binding<ColorStop>) -> some View {
        let hsb = stop.wrappedValue.hsb
        return HStack(spacing: 10) {
            hsbSlider("H", value: Binding(
                get: { hsb.h },
                set: { var s = stop.wrappedValue; s.setHSB(h: $0, s: hsb.s, b: hsb.b); stop.wrappedValue = s }
            ))
            hsbSlider("S", value: Binding(
                get: { hsb.s },
                set: { var s = stop.wrappedValue; s.setHSB(h: hsb.h, s: $0, b: hsb.b); stop.wrappedValue = s }
            ))
            hsbSlider("B", value: Binding(
                get: { hsb.b },
                set: { var s = stop.wrappedValue; s.setHSB(h: hsb.h, s: hsb.s, b: $0); stop.wrappedValue = s }
            ))
        }
    }

    private func hsbSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 10)
            Slider(value: value, in: 0...1)
        }
    }

    /// Inserts a new stop at the midpoint of the gradient's largest gap
    /// (wrapping across the 1.0/0.0 seam), with a color blended from its two
    /// new neighbors -- so it starts as a plausible extra shade rather than
    /// an arbitrary default that the user has to fix immediately.
    private func addStop() {
        let sorted = draft.sortedStops
        guard let first = sorted.first else {
            draft.stops.append(ColorStop(position: 0, red: 1, green: 1, blue: 1))
            return
        }
        guard sorted.count > 1 else {
            draft.stops.append(ColorStop(position: 0.5, red: first.red, green: first.green, blue: first.blue))
            return
        }

        var bestGap = -1.0
        var bestMid = 0.5
        var bestStop = first
        var bestNext = first
        for i in 0..<sorted.count {
            let a = sorted[i]
            let b = sorted[(i + 1) % sorted.count]
            var bPos = b.position
            if bPos <= a.position { bPos += 1 }
            let gap = bPos - a.position
            if gap > bestGap {
                bestGap = gap
                var mid = (a.position + bPos) / 2
                if mid >= 1 { mid -= 1 }
                bestMid = mid
                bestStop = a
                bestNext = b
            }
        }
        let blended = ColorStop(
            position: bestMid,
            red: (bestStop.red + bestNext.red) / 2,
            green: (bestStop.green + bestNext.green) / 2,
            blue: (bestStop.blue + bestNext.blue) / 2
        )
        draft.stops.append(blended)
    }

    private func saveAsNew() {
        let trimmed = newPaletteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let saved = ColorPalette(
            id: "custom-\(UUID().uuidString)",
            name: trimmed,
            stops: draft.stops,
            interiorColor: draft.interiorColor,
            isCustom: true
        )
        renderer.customPalettes.append(saved)
        renderer.palette = saved
        draft = saved
        originalPalette = saved
        newPaletteName = ""
        showingSaveSheet = false
    }
}
