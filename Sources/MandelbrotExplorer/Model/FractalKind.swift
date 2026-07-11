import Foundation

/// Which fractal family a `FractalRenderer` instance draws. Both share the
/// exact same GPU compute kernels, perturbation engine, and color pipeline --
/// only the roles of the two complex quantities in z -> z² + c differ:
///
///  - Mandelbrot: z starts at 0; c is the value being explored, one per pixel.
///  - Julia: c is a single fixed value for the whole image; z starts at the
///    value being explored, one per pixel.
///
/// Raw value is mirrored exactly by the `mode` field in both `FractalParams`
/// (ShaderTypes.swift) and the Metal-side struct.
enum FractalKind: UInt32 {
    case mandelbrot = 0
    case julia = 1
}
