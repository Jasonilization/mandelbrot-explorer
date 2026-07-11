import Foundation

/// Well-known Julia set constants, the c-space equivalent of `Preset` for
/// the Mandelbrot explorer -- each one is a fixed c value with a recognizable
/// resulting shape, jumping straight to a good starting framing.
struct JuliaPreset: Identifiable {
    let id: String
    let name: String
    let c: SIMD2<Double>

    static let all: [JuliaPreset] = [
        JuliaPreset(id: "dendrite", name: "Dendrite", c: SIMD2(-0.4, 0.6)),
        JuliaPreset(id: "douady-rabbit", name: "Douady's Rabbit", c: SIMD2(-0.123, 0.745)),
        JuliaPreset(id: "san-marco", name: "San Marco", c: SIMD2(-0.75, 0.0)),
        JuliaPreset(id: "siegel-disk", name: "Siegel Disk", c: SIMD2(-0.390541, -0.586788)),
        JuliaPreset(id: "spiral", name: "Spiral", c: SIMD2(-0.70176, -0.3842)),
        JuliaPreset(id: "airplane", name: "Airplane", c: SIMD2(-1.75, 0.0)),
        JuliaPreset(id: "galaxies", name: "Galaxies", c: SIMD2(-0.8, 0.156)),
        JuliaPreset(id: "feathers", name: "Feathers", c: SIMD2(0.285, 0.01)),
        JuliaPreset(id: "seahorse-julia", name: "Seahorse Julia", c: SIMD2(-0.75, 0.11)),
        JuliaPreset(id: "dust", name: "Cantor Dust", c: SIMD2(-0.5, 0.55)),
    ]
}
