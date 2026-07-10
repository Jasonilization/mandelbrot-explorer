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
    uint   colorMode;      // 0 escape time, 1 distance estimation, 2 orbit trap
    uint   smoothingEnabled;
    uint   trapType;       // 0 circle, 1 line, 2 cross, 3 custom point
    float  trapParamX;
    float  trapParamY;
};

#define COLOR_MODE_ESCAPE_TIME 0u
#define COLOR_MODE_DISTANCE_EST 1u
#define COLOR_MODE_ORBIT_TRAP 2u

#define TRAP_CIRCLE 0u
#define TRAP_LINE 1u
#define TRAP_CROSS 2u
#define TRAP_CUSTOM 3u

// Orbit trap distances naturally live in a tiny range (roughly [0, the trap's
// own scale], often well under 1) compared to escape-time/distance-estimation
// values (tens to thousands) -- without this multiplier a default colorScale
// of 1.0 would cram the entire image into a sliver of the palette's first
// stop. Mirrored exactly by `Perturbation.orbitTrapColorScale` so the CPU
// tier matches.
#define ORBIT_TRAP_COLOR_SCALE 6.0

// ---------------------------------------------------------------------------
// Orbit trap distance functions, shared by both escape-time kernels. `px`/`py`
// double as the circle radius / line angle (radians) / custom point (x, y)
// depending on `trapType` -- see `FractalParams.trapParamX/Y`.
// ---------------------------------------------------------------------------
inline float orbitTrapDistance(float zRe, float zIm, uint trapType, float px, float py) {
    if (trapType == TRAP_CIRCLE) {
        float r = sqrt(zRe * zRe + zIm * zIm);
        return fabs(r - px);
    } else if (trapType == TRAP_LINE) {
        return fabs(zRe * sin(px) - zIm * cos(px));
    } else if (trapType == TRAP_CROSS) {
        return min(fabs(zRe), fabs(zIm));
    } else {
        float dx = zRe - px;
        float dy = zIm - py;
        return sqrt(dx * dx + dy * dy);
    }
}

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
    float dzRe = 0.0, dzIm = 0.0; // d(z)/d(c), for distance estimation
    float trapDist = 1e10;
    uint n = 0;
    float mag2 = 0.0;
    for (; n < params.maxIterations; n++) {
        float zRe2 = zRe * zRe;
        float zIm2 = zIm * zIm;
        mag2 = zRe2 + zIm2;
        if (mag2 > params.escapeRadiusSq) break;

        // n > 0: skip the trivial z=(0,0) starting point -- a cross or line
        // trap (both pass exactly through the origin by construction) would
        // otherwise register a guaranteed, meaningless 0 for every single
        // pixel right there, before any pixel-dependent structure exists.
        if (params.colorMode == COLOR_MODE_ORBIT_TRAP && n > 0) {
            trapDist = min(trapDist, orbitTrapDistance(zRe, zIm, params.trapType, params.trapParamX, params.trapParamY));
        }
        if (params.colorMode == COLOR_MODE_DISTANCE_EST) {
            float newDzRe = 2.0 * (zRe * dzRe - zIm * dzIm) + 1.0;
            float newDzIm = 2.0 * (zRe * dzIm + zIm * dzRe);
            dzRe = newDzRe;
            dzIm = newDzIm;
        }

        float newIm = 2.0 * zRe * zIm + cIm;
        zRe = zRe2 - zIm2 + cRe;
        zIm = newIm;
    }

    float value;
    if (n >= params.maxIterations) {
        value = (params.colorMode == COLOR_MODE_ORBIT_TRAP) ? (trapDist * ORBIT_TRAP_COLOR_SCALE) : -1.0;
    } else if (params.colorMode == COLOR_MODE_DISTANCE_EST) {
        float dzMag = sqrt(dzRe * dzRe + dzIm * dzIm);
        float zMag = sqrt(mag2);
        float de = (dzMag > 1e-20) ? (0.5 * zMag * log(zMag) / dzMag) : 0.0;
        // Normalize by pixel size rather than clamping to an absolute
        // fractal-plane epsilon: DE shrinks proportionally with the zoomed-in
        // field of view, so a fixed absolute floor (e.g. 1e-9) is far larger
        // than the *entire visible frame* at deep zoom and clamps every
        // pixel to the same flat value. Measuring in pixel-size units keeps
        // the result in a sane, zoom-independent range at any depth.
        value = -log(max(de / pixelSize, 1e-6));
    } else if (params.colorMode == COLOR_MODE_ORBIT_TRAP) {
        value = trapDist * ORBIT_TRAP_COLOR_SCALE;
    } else {
        value = (params.smoothingEnabled != 0) ? smoothValue(n, mag2) : float(n);
    }
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
    // The coloring-only derivative/trap tracking below deliberately uses
    // plain float precision (the dd z's .hi component) rather than full
    // double-double arithmetic: distance estimation and orbit traps only
    // need a visually plausible gradient/trap distance, not positional
    // accuracy, and the actual escape-time iteration above is untouched.
    float dzRe = 0.0, dzIm = 0.0;
    float trapDist = 1e10;
    uint n = 0;
    float mag2 = 0.0;
    for (; n < params.maxIterations; n++) {
        DD zRe2 = dd_mul(zRe, zRe);
        DD zIm2 = dd_mul(zIm, zIm);
        mag2 = zRe2.hi + zIm2.hi;
        if (mag2 > params.escapeRadiusSq) break;

        if (params.colorMode == COLOR_MODE_ORBIT_TRAP && n > 0) {
            trapDist = min(trapDist, orbitTrapDistance(zRe.hi, zIm.hi, params.trapType, params.trapParamX, params.trapParamY));
        }
        if (params.colorMode == COLOR_MODE_DISTANCE_EST) {
            float newDzRe = 2.0 * (zRe.hi * dzRe - zIm.hi * dzIm) + 1.0;
            float newDzIm = 2.0 * (zRe.hi * dzIm + zIm.hi * dzRe);
            dzRe = newDzRe;
            dzIm = newDzIm;
        }

        DD twoZReZIm = dd_mul(dd_make(2.0 * zRe.hi, 2.0 * zRe.lo), zIm);
        zIm = dd_add(twoZReZIm, cIm);
        zRe = dd_add(dd_sub(zRe2, zIm2), cRe);
    }

    float value;
    if (n >= params.maxIterations) {
        value = (params.colorMode == COLOR_MODE_ORBIT_TRAP) ? (trapDist * ORBIT_TRAP_COLOR_SCALE) : -1.0;
    } else if (params.colorMode == COLOR_MODE_DISTANCE_EST) {
        float dzMag = sqrt(dzRe * dzRe + dzIm * dzIm);
        float zMag = sqrt(mag2);
        float de = (dzMag > 1e-20) ? (0.5 * zMag * log(zMag) / dzMag) : 0.0;
        // Normalize by pixel size rather than clamping to an absolute
        // fractal-plane epsilon: DE shrinks proportionally with the zoomed-in
        // field of view, so a fixed absolute floor (e.g. 1e-9) is far larger
        // than the *entire visible frame* at deep zoom and clamps every
        // pixel to the same flat value. Measuring in pixel-size units keeps
        // the result in a sane, zoom-independent range at any depth.
        value = -log(max(de / pixelSize, 1e-6));
    } else if (params.colorMode == COLOR_MODE_ORBIT_TRAP) {
        value = trapDist * ORBIT_TRAP_COLOR_SCALE;
    } else {
        value = (params.smoothingEnabled != 0) ? smoothValue(n, mag2) : float(n);
    }
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
    float  interiorR;
    float  interiorG;
    float  interiorB;
    uint   shadingEnabled;
    float  lightAzimuth;
    float  lightElevation;
    float  shadingStrength;
};

kernel void paletteMap(texture2d<float, access::sample> sourceTexture [[texture(0)]],
                        texture2d<float, access::write> outTexture [[texture(1)]],
                        constant PaletteParams &params [[buffer(0)]],
                        constant float3 *stopColors [[buffer(1)]],
                        constant float *stopPositions [[buffer(2)]],
                        uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= params.outWidth || gid.y >= params.outHeight) return;

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(params.outWidth, params.outHeight);
    float value = sourceTexture.sample(s, uv).r;

    float3 color;
    if (value < 0.0) {
        color = float3(params.interiorR, params.interiorG, params.interiorB);
    } else {
        // Divide by stopCount before wrapping: stop positions span a single
        // [0, 1) cycle, so without this a colorScale of 1.0 would complete a
        // full palette rotation every single iteration of `value` instead of
        // every `stopCount` iterations, aliasing into rainbow static on any
        // view with more than a few iterations of contrast pixel-to-pixel.
        float t = (value * params.colorScale + params.colorOffset) / max(float(params.stopCount), 1.0);
        t = fract(t);
        if (t < 0.0) t += 1.0;

        // Stops are sorted ascending by position; walk to the last stop at
        // or before `t`, then wrap to stop 0 for the far end of the bracket
        // -- this is what makes the gradient cycle seamlessly.
        uint i0 = 0;
        for (uint i = 0; i < params.stopCount; i++) {
            if (stopPositions[i] <= t) { i0 = i; } else { break; }
        }
        uint i1 = (i0 + 1) % params.stopCount;
        float p0 = stopPositions[i0];
        float p1 = stopPositions[i1];
        float span = p1 - p0;
        if (span <= 0.0) span += 1.0;
        float localT = t - p0;
        if (localT < 0.0) localT += 1.0;
        localT = (span > 0.0) ? saturate(localT / span) : 0.0;
        color = mix(stopColors[i0], stopColors[i1], localT);
    }

    // Cheap relief shading: treat the scalar field itself as a heightmap,
    // build a fake normal from its screen-space gradient, and light it --
    // makes boundary/orbit-trap structure read as more three-dimensional
    // without needing an actual 3D model.
    if (params.shadingEnabled != 0 && value >= 0.0) {
        float2 texel = 1.0 / float2(params.sourceWidth, params.sourceHeight);
        float vL = sourceTexture.sample(s, uv - float2(texel.x, 0)).r;
        float vR = sourceTexture.sample(s, uv + float2(texel.x, 0)).r;
        float vU = sourceTexture.sample(s, uv - float2(0, texel.y)).r;
        float vD = sourceTexture.sample(s, uv + float2(0, texel.y)).r;
        vL = (vL < 0.0) ? value : vL;
        vR = (vR < 0.0) ? value : vR;
        vU = (vU < 0.0) ? value : vU;
        vD = (vD < 0.0) ? value : vD;

        float dx = (vR - vL) * params.shadingStrength;
        float dy = (vD - vU) * params.shadingStrength;
        float3 normal = normalize(float3(-dx, -dy, 1.0));
        float3 lightDir = normalize(float3(
            cos(params.lightAzimuth) * cos(params.lightElevation),
            sin(params.lightAzimuth) * cos(params.lightElevation),
            sin(params.lightElevation)
        ));
        float diffuse = max(dot(normal, lightDir), 0.0);
        float ambient = 0.35;
        float lighting = ambient + diffuse * (1.0 - ambient);
        color *= lighting;
    }

    outTexture.write(float4(color, 1.0), gid);
}
