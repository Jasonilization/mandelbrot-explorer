import Foundation

/// Curated starting points for the Mandelbulb explorer. Applying one resets
/// the camera too, so picking a preset always lands on a clean, framed view
/// rather than whatever angle happened to be in use.
struct MandelbulbPreset: Identifiable {
    let id: String
    let name: String
    let power: Double
    let hollowVariant: Bool
    let subtitle: String

    static let all: [MandelbulbPreset] = [
        MandelbulbPreset(id: "classic", name: "Classic Mandelbulb", power: 8, hollowVariant: false,
                          subtitle: "The canonical power-8 Mandelbulb."),
        MandelbulbPreset(id: "seahorse", name: "Seahorse-like", power: 4, hollowVariant: false,
                          subtitle: "Lower power produces more organic, tendril-like structures."),
        MandelbulbPreset(id: "hollow", name: "Hollow Forms", power: 8, hollowVariant: true,
                          subtitle: "An abs-transformed variant that carves out hollow, shell-like cavities."),
        MandelbulbPreset(id: "spiky", name: "Spiky Forms", power: 12, hollowVariant: false,
                          subtitle: "Higher power sharpens the surface into fine spikes."),
    ]
}
