import simd
import SwiftUI

/// A single gradient stop: a position around the cyclic [0, 1) gradient and
/// an RGB color. `Codable` so custom palettes can round-trip to disk from
/// the palette editor.
struct ColorStop: Identifiable, Equatable, Hashable, Codable {
    var id: UUID = UUID()
    /// Position around the cyclic gradient, in [0, 1).
    var position: Double
    var red: Double
    var green: Double
    var blue: Double

    var simd: SIMD3<Float> { SIMD3(Float(red), Float(green), Float(blue)) }
    var color: Color { Color(red: red, green: green, blue: blue) }

    init(position: Double, red: Double, green: Double, blue: Double) {
        self.position = position
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(position: Double, color: Color) {
        self.position = position
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        self.red = Double(ns.redComponent)
        self.green = Double(ns.greenComponent)
        self.blue = Double(ns.blueComponent)
    }

    /// Hue/saturation/brightness view onto the same stored RGB, for the
    /// palette editor's HSB sliders.
    var hsb: (h: Double, s: Double, b: Double) {
        let ns = NSColor(red: red, green: green, blue: blue, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }

    mutating func setHSB(h: Double, s: Double, b: Double) {
        let ns = NSColor(hue: h, saturation: s, brightness: b, alpha: 1)
        red = Double(ns.redComponent)
        green = Double(ns.greenComponent)
        blue = Double(ns.blueComponent)
    }
}

/// A smooth color gradient used to map a continuous per-pixel scalar (escape
/// time, distance estimate, or orbit trap distance -- see `ColorMode`) to
/// color. Stops carry an explicit position so the palette editor can move
/// them freely rather than assuming even spacing; the gradient wraps
/// (position 1.0 is the same as position 0.0), which is what gives
/// Mandelbrot renders their seamless, banding-free color cycles.
struct ColorPalette: Identifiable, Equatable, Hashable, Codable {
    var id: String
    var name: String
    var stops: [ColorStop]
    var interiorColor: ColorStop
    var isCustom: Bool = false

    /// Stops sorted by position ascending -- the order the renderer and the
    /// editor's gradient preview both need.
    var sortedStops: [ColorStop] { stops.sorted { $0.position < $1.position } }

    /// General constructor used by the palette editor to build/save custom
    /// palettes with arbitrary stop positions and colors.
    init(id: String, name: String, stops: [ColorStop], interiorColor: ColorStop, isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.stops = stops
        self.interiorColor = interiorColor
        self.isCustom = isCustom
    }

    private init(id: String, name: String, evenlySpaced colors: [SIMD3<Float>], interior: SIMD3<Float>) {
        self.id = id
        self.name = name
        let count = colors.count
        self.stops = colors.enumerated().map { i, c in
            ColorStop(position: Double(i) / Double(count), red: Double(c.x), green: Double(c.y), blue: Double(c.z))
        }
        self.interiorColor = ColorStop(position: 0, red: Double(interior.x), green: Double(interior.y), blue: Double(interior.z))
    }

    static let all: [ColorPalette] = [
        ColorPalette(
            id: "rainbow", name: "Classic Rainbow",
            evenlySpaced: [
                SIMD3(1.00, 0.00, 0.00),
                SIMD3(1.00, 0.55, 0.00),
                SIMD3(1.00, 0.95, 0.00),
                SIMD3(0.10, 0.85, 0.10),
                SIMD3(0.05, 0.35, 1.00),
                SIMD3(0.30, 0.05, 0.75),
                SIMD3(0.65, 0.00, 0.55),
            ],
            interior: SIMD3(0, 0, 0)
        ),
        ColorPalette(
            id: "classic", name: "Classic",
            evenlySpaced: [
                SIMD3(0.02, 0.02, 0.10),
                SIMD3(0.05, 0.10, 0.45),
                SIMD3(0.10, 0.35, 0.80),
                SIMD3(0.85, 0.95, 1.00),
                SIMD3(1.00, 0.85, 0.20),
                SIMD3(0.55, 0.10, 0.02),
                SIMD3(0.05, 0.02, 0.05),
            ],
            interior: SIMD3(0, 0, 0)
        ),
        ColorPalette(
            id: "fire", name: "Fire",
            evenlySpaced: [
                SIMD3(0.00, 0.00, 0.00),
                SIMD3(0.35, 0.02, 0.00),
                SIMD3(0.85, 0.20, 0.00),
                SIMD3(1.00, 0.65, 0.05),
                SIMD3(1.00, 0.95, 0.60),
                SIMD3(1.00, 1.00, 1.00),
            ],
            interior: SIMD3(0.05, 0.0, 0.0)
        ),
        ColorPalette(
            id: "ice", name: "Ice",
            evenlySpaced: [
                SIMD3(0.01, 0.02, 0.06),
                SIMD3(0.10, 0.20, 0.40),
                SIMD3(0.35, 0.55, 0.80),
                SIMD3(0.70, 0.90, 1.00),
                SIMD3(0.95, 0.98, 1.00),
                SIMD3(0.55, 0.75, 0.95),
            ],
            interior: SIMD3(0.02, 0.03, 0.08)
        ),
        ColorPalette(
            id: "ocean", name: "Ocean",
            evenlySpaced: [
                SIMD3(0.00, 0.02, 0.05),
                SIMD3(0.00, 0.15, 0.30),
                SIMD3(0.00, 0.45, 0.55),
                SIMD3(0.10, 0.80, 0.75),
                SIMD3(0.75, 0.98, 0.90),
                SIMD3(0.00, 0.10, 0.25),
            ],
            interior: SIMD3(0, 0.01, 0.03)
        ),
        ColorPalette(
            id: "neon", name: "Neon",
            evenlySpaced: [
                SIMD3(0.02, 0.00, 0.05),
                SIMD3(0.35, 0.00, 0.55),
                SIMD3(0.80, 0.00, 0.85),
                SIMD3(0.20, 0.80, 1.00),
                SIMD3(0.30, 1.00, 0.30),
                SIMD3(1.00, 1.00, 0.10),
            ],
            interior: SIMD3(0.03, 0, 0.05)
        ),
        ColorPalette(
            id: "monochrome", name: "Monochrome",
            evenlySpaced: [
                SIMD3(0.02, 0.02, 0.02),
                SIMD3(0.95, 0.95, 0.95),
                SIMD3(0.02, 0.02, 0.02),
            ],
            interior: SIMD3(1, 1, 1)
        ),
        ColorPalette(
            id: "scientific", name: "Scientific",
            evenlySpaced: [
                SIMD3(0.05, 0.03, 0.25),
                SIMD3(0.15, 0.15, 0.50),
                SIMD3(0.05, 0.45, 0.45),
                SIMD3(0.20, 0.65, 0.20),
                SIMD3(0.85, 0.80, 0.10),
                SIMD3(0.95, 0.95, 0.75),
            ],
            interior: SIMD3(0.02, 0.02, 0.08)
        ),
        ColorPalette(
            id: "psychedelic", name: "Psychedelic",
            evenlySpaced: [
                SIMD3(1.0, 0.0, 0.2),
                SIMD3(1.0, 0.8, 0.0),
                SIMD3(0.1, 1.0, 0.2),
                SIMD3(0.0, 0.7, 1.0),
                SIMD3(0.6, 0.0, 1.0),
            ],
            interior: SIMD3(0, 0, 0)
        ),
        ColorPalette(
            id: "desert", name: "Desert",
            evenlySpaced: [
                SIMD3(0.10, 0.05, 0.02),
                SIMD3(0.45, 0.22, 0.05),
                SIMD3(0.80, 0.55, 0.20),
                SIMD3(0.95, 0.85, 0.55),
                SIMD3(0.55, 0.15, 0.10),
            ],
            interior: SIMD3(0.02, 0.01, 0.0)
        ),
    ]

    static let `default` = all[0]
}
