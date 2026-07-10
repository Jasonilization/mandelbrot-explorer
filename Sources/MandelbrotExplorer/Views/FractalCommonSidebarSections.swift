import SwiftUI

/// Shared "Rendering / Interaction / Auto Zoom / Recording / Color / Export"
/// sidebar sections -- identical behavior on the Mandelbrot and Julia tabs,
/// since both are driven by the exact same `FractalRenderer` engine. Only
/// each tab's own "where am I" section (Mandelbrot's Location presets vs.
/// Julia's c-parameter controls) differs, and lives in that tab's own
/// sidebar view instead of here.
struct FractalCommonSidebarSections: View {
    @ObservedObject var renderer: FractalRenderer
    @ObservedObject var recorder: FractalRecorder
    @Binding var showingRecorder: Bool
    @Binding var showingPaletteEditor: Bool
    @Binding var exportResolution: ExportResolution

    var body: some View {
        Group {
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

                Picker("Render Resolution", selection: $renderer.renderResolution) {
                    ForEach(RenderResolution.allCases) { res in
                        Text(res.rawValue).tag(res)
                    }
                }
                .help("Internal render scale for the live canvas, independent of window size. Below native trades sharpness for frame rate; above native supersamples for a crisper still image.")
            }

            Section("Interaction") {
                Toggle("Lock Cursor to Detail", isOn: $renderer.isCursorLockEnabled)
                    .disabled(renderer.isInputLocked)
                    .help("While on, scrolling or pinching to zoom nudges the zoom point from your literal cursor position onto the most detailed nearby boundary structure, so you don't need pixel-perfect aim.")
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
                PaletteGradientPreview(palette: renderer.palette)
                    .help("Live preview of the active palette's gradient cycle.")

                Picker("Palette", selection: $renderer.palette) {
                    if !renderer.customPalettes.isEmpty {
                        Section("Custom") {
                            ForEach(renderer.customPalettes) { p in
                                Text(p.name).tag(p)
                            }
                        }
                    }
                    Section("Presets") {
                        ForEach(ColorPalette.all) { p in
                            Text(p.name).tag(p)
                        }
                    }
                }
                .pickerStyle(.menu)

                Button {
                    showingPaletteEditor = true
                } label: {
                    Label("Edit Palette…", systemImage: "slider.horizontal.below.square.filled.and.square")
                }
                .help("Add, remove, or reposition color stops; adjust hue/saturation/brightness; save as a custom palette.")

                VStack(alignment: .leading) {
                    Text("Color Scale")
                    Slider(value: $renderer.colorScale, in: 0.1...5.0)
                }
                VStack(alignment: .leading) {
                    Text("Color Offset")
                    Slider(value: $renderer.colorOffset, in: 0...1)
                }

                Picker("Color Mode", selection: $renderer.colorMode) {
                    ForEach(ColorMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .help(renderer.colorMode.helpText)

                if renderer.colorMode == .escapeTime {
                    Toggle("Smooth Coloring", isOn: $renderer.smoothingEnabled)
                        .help("Continuous gradient (on) vs. classic discrete iteration bands (off).")
                }

                if renderer.colorMode == .orbitTrap {
                    Picker("Trap Shape", selection: $renderer.orbitTrap.type) {
                        ForEach(OrbitTrapType.allCases) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    .help("Shape the orbit's distance is measured against -- circle, line, cross, or a custom point.")

                    switch renderer.orbitTrap.type {
                    case .circle:
                        VStack(alignment: .leading) {
                            Text("Trap Radius")
                            Slider(value: $renderer.orbitTrap.scale, in: 0.02...1.5)
                        }
                    case .line:
                        VStack(alignment: .leading) {
                            Text("Trap Angle")
                            Slider(value: $renderer.orbitTrap.angleDegrees, in: 0...180)
                        }
                    case .cross:
                        EmptyView()
                    case .custom:
                        VStack(alignment: .leading) {
                            Text("Trap Position")
                            HStack {
                                Slider(value: $renderer.orbitTrap.customX, in: -2...2)
                                Slider(value: $renderer.orbitTrap.customY, in: -2...2)
                            }
                        }
                    }
                }

                Toggle("Surface Shading", isOn: $renderer.shadingEnabled)
                    .help("Adds cheap relief-style lighting derived from the color field's local gradient, so boundary structure reads as more three-dimensional.")

                if renderer.shadingEnabled {
                    VStack(alignment: .leading) {
                        Text("Light Direction")
                        Slider(value: $renderer.lightAzimuthDegrees, in: 0...360)
                    }
                    VStack(alignment: .leading) {
                        Text("Light Elevation")
                        Slider(value: $renderer.lightElevationDegrees, in: 5...90)
                    }
                    VStack(alignment: .leading) {
                        Text("Shading Strength")
                        Slider(value: $renderer.shadingStrength, in: 0.5...20)
                    }
                }
            }

            Section("Export") {
                Picker("Resolution", selection: $exportResolution) {
                    ForEach(ExportResolution.all) { res in
                        Text(res.label).tag(res)
                    }
                }
                Button {
                    SaveImageAction.run(renderer: renderer, resolution: exportResolution)
                } label: {
                    Label("Save Image…", systemImage: "square.and.arrow.down")
                }
            }
        }
    }
}
