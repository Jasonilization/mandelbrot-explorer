#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Shared per-draw parameters. Field order/types are mirrored exactly by the
// Swift-side `FractalParams` struct (Rendering/ShaderTypes.swift) since the
// shader is compiled from source at runtime rather than through a shared
// bridging header.
// ---------------------------------------------------------------------------
struct FractalParams {
    float2 centerHi;      // double->float32 hi component of (re, im)
    float2 centerLo;      // residual (double - float(hi)) component of (re, im)
    float  spanX;         // view width in fractal-plane units
    float  aspect;         // height / width
    uint   width;
    uint   height;
    uint   maxIterations;
    float  escapeRadiusSq;
};

// ---------------------------------------------------------------------------
// Double-double (error-compensated float32 pair) arithmetic. Gives ~44-46
// mantissa bits, roughly matching real hardware float64, entirely in
// parallel on the GPU which has no native double type at all.
// ---------------------------------------------------------------------------
struct DD { float hi; float lo; };

inline DD dd_make(float hi, float lo) { DD r; r.hi = hi; r.lo = lo; return r; }

inline DD dd_quick_two_sum(float a, float b) {
    float s = a + b;
    float e = b - (s - a);
    return dd_make(s, e);
}

inline DD dd_two_sum(float a, float b) {
    float s = a + b;
    float bb = s - a;
    float e = (a - (s - bb)) + (b - bb);
    return dd_make(s, e);
}

inline DD dd_two_prod(float a, float b) {
    float p = a * b;
    float e = fma(a, b, -p);
    return dd_make(p, e);
}

inline DD dd_add(DD a, DD b) {
    DD s = dd_two_sum(a.hi, b.hi);
    float lo = s.lo + a.lo + b.lo;
    return dd_quick_two_sum(s.hi, lo);
}

inline DD dd_sub(DD a, DD b) {
    return dd_add(a, dd_make(-b.hi, -b.lo));
}

inline DD dd_mul(DD a, DD b) {
    DD p = dd_two_prod(a.hi, b.hi);
    float lo = p.lo + (a.hi * b.lo + a.lo * b.hi);
    return dd_quick_two_sum(p.hi, lo);
}

// ---------------------------------------------------------------------------
// Smooth (continuous) escape-time coloring value.
// ---------------------------------------------------------------------------
inline float smoothValue(uint n, float mag2) {
    float logZn = log(mag2) * 0.5;
    float nu = log(logZn / log(2.0)) / log(2.0);
    return float(n) + 1.0 - nu;
}

// ---------------------------------------------------------------------------
// Tier 1: direct float32 iteration. Fast path for zoom below ~5e4.
// ---------------------------------------------------------------------------
kernel void mandelbrotFloat32(texture2d<float, access::write> outTexture [[texture(0)]],
                               constant FractalParams &params [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= params.width || gid.y >= params.height) return;

    float pixelSize = params.spanX / float(params.width);
    float cRe = params.centerHi.x + (float(gid.x) - float(params.width) * 0.5) * pixelSize;
    float cIm = params.centerHi.y + (float(params.height) * 0.5 - float(gid.y)) * pixelSize;

    float zRe = 0.0, zIm = 0.0;
    uint n = 0;
    float mag2 = 0.0;
    for (; n < params.maxIterations; n++) {
        float zRe2 = zRe * zRe;
        float zIm2 = zIm * zIm;
        mag2 = zRe2 + zIm2;
        if (mag2 > params.escapeRadiusSq) break;
        float newIm = 2.0 * zRe * zIm + cIm;
        zRe = zRe2 - zIm2 + cRe;
        zIm = newIm;
    }

    float value = (n >= params.maxIterations) ? -1.0 : smoothValue(n, mag2);
    outTexture.write(float4(value, 0, 0, 0), gid);
}

// ---------------------------------------------------------------------------
// Tier 2: double-double iteration. Roughly float64-equivalent precision,
// still fully data-parallel on the GPU. Handles zoom up to ~3e13.
// ---------------------------------------------------------------------------
kernel void mandelbrotDoubleDouble(texture2d<float, access::write> outTexture [[texture(0)]],
                                    constant FractalParams &params [[buffer(0)]],
                                    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= params.width || gid.y >= params.height) return;

    DD centerRe = dd_make(params.centerHi.x, params.centerLo.x);
    DD centerIm = dd_make(params.centerHi.y, params.centerLo.y);

    float pixelSize = params.spanX / float(params.width);
    float dxPix = (float(gid.x) - float(params.width) * 0.5) * pixelSize;
    float dyPix = (float(params.height) * 0.5 - float(gid.y)) * pixelSize;

    DD cRe = dd_add(centerRe, dd_make(dxPix, 0.0));
    DD cIm = dd_add(centerIm, dd_make(dyPix, 0.0));

    DD zRe = dd_make(0.0, 0.0);
    DD zIm = dd_make(0.0, 0.0);
    uint n = 0;
    float mag2 = 0.0;
    for (; n < params.maxIterations; n++) {
        DD zRe2 = dd_mul(zRe, zRe);
        DD zIm2 = dd_mul(zIm, zIm);
        mag2 = zRe2.hi + zIm2.hi;
        if (mag2 > params.escapeRadiusSq) break;
        DD twoZReZIm = dd_mul(dd_make(2.0 * zRe.hi, 2.0 * zRe.lo), zIm);
        zIm = dd_add(twoZReZIm, cIm);
        zRe = dd_add(dd_sub(zRe2, zIm2), cRe);
    }

    float value = (n >= params.maxIterations) ? -1.0 : smoothValue(n, mag2);
    outTexture.write(float4(value, 0, 0, 0), gid);
}

// ---------------------------------------------------------------------------
// Palette pass: shared by all three tiers. Reads a (possibly lower
// resolution, linearly resampled -- this is what makes the fast preview
// during drag/zoom cheap) iteration-value texture and writes final color
// straight into the drawable.
// ---------------------------------------------------------------------------
// All-scalar layout: deliberately avoids embedding a float3/float4 inside
// this struct, since MSL pads vector members to 16-byte alignment in ways
// that are easy to get subtly wrong when hand-mirroring the layout on the
// Swift side. The interior (non-escaped) color instead rides along as the
// last extra element of the `stops` buffer, at index `stopCount`.
struct PaletteParams {
    uint   stopCount;
    float  colorScale;
    float  colorOffset;
    uint   sourceWidth;
    uint   sourceHeight;
    uint   outWidth;
    uint   outHeight;
};

kernel void paletteMap(texture2d<float, access::sample> sourceTexture [[texture(0)]],
                        texture2d<float, access::write> outTexture [[texture(1)]],
                        constant PaletteParams &params [[buffer(0)]],
                        constant float3 *stops [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= params.outWidth || gid.y >= params.outHeight) return;

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(params.outWidth, params.outHeight);
    float value = sourceTexture.sample(s, uv).r;

    float3 color;
    if (value < 0.0) {
        color = stops[params.stopCount];
    } else {
        float t = value * params.colorScale + params.colorOffset;
        t = fract(t / float(params.stopCount - 1)) * float(params.stopCount - 1);
        uint i0 = uint(t);
        uint i1 = min(i0 + 1, params.stopCount - 1);
        float frac = t - float(i0);
        color = mix(stops[i0], stops[i1], frac);
    }

    outTexture.write(float4(color, 1.0), gid);
}
