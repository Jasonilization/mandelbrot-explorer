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
        if let dir = ProcessInfo.processInfo.environment["COLOR_MODE_TEST_DIR"] {
            PresetPreviewTool.runColorModeTest(outputDir: dir)
        }
        if let dir = ProcessInfo.processInfo.environment["MANDELBULB_TEST_DIR"] {
            PresetPreviewTool.runMandelbulbTest(outputDir: dir)
        }
    }

    var body: some Scene {
        WindowGroup("Mandelbrot Explorer") {
            RootView()
                .frame(minWidth: 1000, minHeight: 700)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
