import Foundation

/// Persists user-created custom palettes (from the Palette Editor) to disk
/// as JSON, so they survive relaunching the app.
enum PaletteStore {
    private static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let appDir = dir.appendingPathComponent("MandelbrotExplorer", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("custom_palettes.json")
    }

    static func load() -> [ColorPalette] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ColorPalette].self, from: data)) ?? []
    }

    static func save(_ palettes: [ColorPalette]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(palettes) else { return }
        try? data.write(to: url)
    }
}
