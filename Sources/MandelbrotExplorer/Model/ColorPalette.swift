import simd

/// A smooth color gradient used to map continuous escape values to color.
/// Stops are evaluated with linear interpolation and the whole gradient
/// cycles, which is what gives Mandelbrot renders their classic banding-free
/// psychedelic color sweeps.
struct ColorPalette: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let stops: [SIMD3<Float>]
    let interiorColor: SIMD3<Float>

    static let all: [ColorPalette] = [
        ColorPalette(
            id: "classic",
            name: "Classic",
            stops: [
                SIMD3(0.02, 0.02, 0.10),
                SIMD3(0.05, 0.10, 0.45),
                SIMD3(0.10, 0.35, 0.80),
                SIMD3(0.85, 0.95, 1.00),
                SIMD3(1.00, 0.85, 0.20),
                SIMD3(0.55, 0.10, 0.02),
                SIMD3(0.05, 0.02, 0.05),
            ],
            interiorColor: SIMD3(0, 0, 0)
        ),
        ColorPalette(
            id: "fire",
            name: "Fire",
            stops: [
                SIMD3(0.00, 0.00, 0.00),
                SIMD3(0.35, 0.02, 0.00),
                SIMD3(0.85, 0.20, 0.00),
                SIMD3(1.00, 0.65, 0.05),
                SIMD3(1.00, 0.95, 0.60),
                SIMD3(1.00, 1.00, 1.00),
            ],
            interiorColor: SIMD3(0.05, 0.0, 0.0)
        ),
        ColorPalette(
            id: "ocean",
            name: "Ocean",
            stops: [
                SIMD3(0.00, 0.02, 0.05),
                SIMD3(0.00, 0.15, 0.30),
                SIMD3(0.00, 0.45, 0.55),
                SIMD3(0.10, 0.80, 0.75),
                SIMD3(0.75, 0.98, 0.90),
                SIMD3(0.00, 0.10, 0.25),
            ],
            interiorColor: SIMD3(0, 0.01, 0.03)
        ),
        ColorPalette(
            id: "electric",
            name: "Electric",
            stops: [
                SIMD3(0.02, 0.00, 0.05),
                SIMD3(0.35, 0.00, 0.55),
                SIMD3(0.80, 0.00, 0.85),
                SIMD3(0.20, 0.80, 1.00),
                SIMD3(0.85, 1.00, 0.95),
                SIMD3(0.02, 0.00, 0.05),
            ],
            interiorColor: SIMD3(0, 0, 0)
        ),
        ColorPalette(
            id: "grayscale",
            name: "Grayscale",
            stops: [
                SIMD3(0.02, 0.02, 0.02),
                SIMD3(0.95, 0.95, 0.95),
                SIMD3(0.02, 0.02, 0.02),
            ],
            interiorColor: SIMD3(1, 1, 1)
        ),
        ColorPalette(
            id: "psychedelic",
            name: "Psychedelic",
            stops: [
                SIMD3(1.0, 0.0, 0.2),
                SIMD3(1.0, 0.8, 0.0),
                SIMD3(0.1, 1.0, 0.2),
                SIMD3(0.0, 0.7, 1.0),
                SIMD3(0.6, 0.0, 1.0),
                SIMD3(1.0, 0.0, 0.2),
            ],
            interiorColor: SIMD3(0, 0, 0)
        ),
        ColorPalette(
            id: "desert",
            name: "Desert",
            stops: [
                SIMD3(0.10, 0.05, 0.02),
                SIMD3(0.45, 0.22, 0.05),
                SIMD3(0.80, 0.55, 0.20),
                SIMD3(0.95, 0.85, 0.55),
                SIMD3(0.55, 0.15, 0.10),
                SIMD3(0.10, 0.05, 0.02),
            ],
            interiorColor: SIMD3(0.02, 0.01, 0.0)
        ),
    ]

    static let `default` = all[0]
}
