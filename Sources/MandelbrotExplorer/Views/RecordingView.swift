import SwiftUI
import UniformTypeIdentifiers

/// Settings + progress sheet for `FractalRecorder`. Presented from the
/// sidebar's Recording section; owns nothing itself beyond the transient
/// `RecordingSettings` draft, since the actual capture state lives in the
/// shared `FractalRecorder` so progress survives the sheet being dismissed.
struct RecordingView: View {
    @ObservedObject var renderer: FractalRenderer
    @ObservedObject var recorder: FractalRecorder
    @Environment(\.dismiss) private var dismiss
    @State private var settings = RecordingSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Record Zoom Journey", systemImage: "video.badge.waveform")
                .font(.title3.bold())

            switch recorder.phase {
            case .idle, .finished, .failed, .cancelled:
                settingsForm
                statusMessage
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }
                    Button("Start Recording") { startRecording() }
                        .keyboardShortcut(.defaultAction)
                }
            case .recording, .finishing:
                progressSection
                HStack {
                    Spacer()
                    Button("Stop", role: .destructive) { recorder.cancel() }
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Picker("Resolution", selection: $settings.resolution) {
                    ForEach(RecordingSettings.Resolution.allCases) { res in
                        Text(res.rawValue).tag(res)
                    }
                }
                Picker("Frame Rate", selection: $settings.fps) {
                    ForEach([24, 30, 60], id: \.self) { fps in
                        Text("\(fps) fps").tag(fps)
                    }
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("Duration")
                        Spacer()
                        Text("\(Int(settings.durationSeconds))s (\(settings.totalFrames) frames)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.durationSeconds, in: 3...120, step: 1)
                }
                Toggle("Show zoom level overlay", isOn: $settings.showZoomOverlay)
            }
            Text("Auto-zooms from the current view, steering toward interesting structure -- the same smart auto-zoom used live. Manual interaction pauses until it finishes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        switch recorder.phase {
        case .finished(let url):
            Label("Saved to \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Label("Recording cancelled.", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: recorder.progress)
            Text(isFinishing ? "Finishing…" : "Frame \(recorder.currentFrame) of \(recorder.totalFrames)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var isFinishing: Bool {
        if case .finishing = recorder.phase { return true }
        return false
    }

    private func startRecording() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "mandelbrot-journey.mov"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recorder.reset()
        recorder.start(renderer: renderer, settings: settings, outputURL: url)
    }
}
