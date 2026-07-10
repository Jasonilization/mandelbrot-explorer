import Foundation

/// Mirrors `MandelbulbParams` in Shaders.metal field-for-field. All-scalar,
/// same rationale as `PaletteParams`: no float3/float4 struct members, so
/// there's no cross-language padding risk to get subtly wrong.
struct MandelbulbParams {
    var eyeX: Float, eyeY: Float, eyeZ: Float
    var rightX: Float, rightY: Float, rightZ: Float
    var upX: Float, upY: Float, upZ: Float
    var forwardX: Float, forwardY: Float, forwardZ: Float
    var width: UInt32
    var height: UInt32
    var tanHalfFov: Float
    var power: Float
    var maxIterations: UInt32
    var maxRaySteps: UInt32
    var epsilon: Float
    var maxDistance: Float
    var variant: UInt32
    var aoEnabled: UInt32
    var shadowsEnabled: UInt32
    var lightAzimuth: Float
    var lightElevation: Float
    var ambientStrength: Float
}
