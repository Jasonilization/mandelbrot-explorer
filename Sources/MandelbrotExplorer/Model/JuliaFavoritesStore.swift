import Foundation

/// A user-saved Julia c value, named either by hand or auto-generated from
/// its coordinates.
struct JuliaFavorite: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var re: Double
    var im: Double

    var c: SIMD2<Double> { SIMD2(re, im) }
}

/// Persists user-saved favorite Julia c values to disk as JSON, so they
/// survive relaunching the app -- mirrors `PaletteStore`.
enum JuliaFavoritesStore {
    private static var fileURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let appDir = dir.appendingPathComponent("MandelbrotExplorer", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("julia_favorites.json")
    }

    static func load() -> [JuliaFavorite] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([JuliaFavorite].self, from: data)) ?? []
    }

    static func save(_ favorites: [JuliaFavorite]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(favorites) else { return }
        try? data.write(to: url)
    }
}
