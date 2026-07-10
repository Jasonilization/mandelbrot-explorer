import SwiftUI

@main
struct MandelbrotExplorerApp: App {
    init() {
        if let dir = ProcessInfo.processInfo.environment["PRESET_PREVIEW_DIR"] {
            PresetPreviewTool.run(outputDir: dir)
        }
        if let spec = ProcessInfo.processInfo.environment["PERTURBATION_DEBUG_SINGLE"] {
            PresetPreviewTool.runSingle(spec: spec)
        }
        if let path = ProcessInfo.processInfo.environment["ICON_OUTPUT_PATH"] {
            PresetPreviewTool.renderIcon(to: path)
        }
        if let path = ProcessInfo.processInfo.environment["RECORDING_TEST_PATH"] {
            PresetPreviewTool.runRecordingTest(outputPath: path)
        }
    }

    var body: some Scene {
        WindowGroup("Mandelbrot Explorer") {
            ContentView()
                .frame(minWidth: 1000, minHeight: 700)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
