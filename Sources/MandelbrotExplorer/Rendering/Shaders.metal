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
    uint   mode;           // 0 Mandelbrot, 1 Julia -- see FractalKind
    float2 juliaC;         // Julia's fixed c parameter (unused for Mandelbrot)
};

#define COLOR_MODE_ESCAPE_TIME 0u
#define COLOR_MODE_DISTANCE_EST 1u
#define COLOR_MODE_ORBIT_TRAP 2u

#define TRAP_CIRCLE 0u
#define TRAP_LINE 1u
#define TRAP_CROSS 2u
#define TRAP_CUSTOM 3u

#define MODE_MANDELBROT 0u
#define MODE_JULIA 1u

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
    // The pixel's own plane coordinate: Mandelbrot's per-pixel c, or Julia's
    // per-pixel starting z0, depending on mode (see below).
    float pRe = params.centerHi.x + (float(gid.x) - float(params.width) * 0.5) * pixelSize;
    float pIm = params.centerHi.y + (float(params.height) * 0.5 - float(gid.y)) * pixelSize;

    bool isJulia = params.mode == MODE_JULIA;
    float zRe = isJulia ? pRe : 0.0;
    float zIm = isJulia ? pIm : 0.0;
    float addRe = isJulia ? params.juliaC.x : pRe;
    float addIm = isJulia ? params.juliaC.y : pIm;

    // d(z)/d(varying quantity), for distance estimation: d(z)/dc for
    // Mandelbrot (seeded 0, since z0=0 doesn't depend on c) or d(z)/dz0 for
    // Julia (seeded 1, the identity derivative at the starting point).
    float dzRe = isJulia ? 1.0 : 0.0;
    float dzIm = 0.0;
    float trapDist = 1e10;
    uint n = 0;
    float mag2 = 0.0;
    for (; n < params.maxIterations; n++) {
        float zRe2 = zRe * zRe;
        float zIm2 = zIm * zIm;
        mag2 = zRe2 + zIm2;
        if (mag2 > params.escapeRadiusSq) break;

        // n > 0 (Mandelbrot only): skip the trivial z=(0,0) starting point --
        // a cross or line trap (both pass exactly through the origin by
        // construction) would otherwise register a guaranteed, meaningless 0
        // for every single pixel right there, before any pixel-dependent
        // structure exists. Julia's z at n=0 is the pixel-varying z0 itself,
        // so it's kept.
        if (params.colorMode == COLOR_MODE_ORBIT_TRAP && (n > 0 || isJulia)) {
            trapDist = min(trapDist, orbitTrapDistance(zRe, zIm, params.trapType, params.trapParamX, params.trapParamY));
        }
        if (params.colorMode == COLOR_MODE_DISTANCE_EST) {
            float newDzRe = 2.0 * (zRe * dzRe - zIm * dzIm) + (isJulia ? 0.0 : 1.0);
            float newDzIm = 2.0 * (zRe * dzIm + zIm * dzRe);
            dzRe = newDzRe;
            dzIm = newDzIm;
        }

        float newIm = 2.0 * zRe * zIm + addIm;
        zRe = zRe2 - zIm2 + addRe;
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

    // The pixel's own plane coordinate: Mandelbrot's per-pixel c, or Julia's
    // per-pixel starting z0, depending on mode (see below).
    DD pRe = dd_add(centerRe, dd_make(dxPix, 0.0));
    DD pIm = dd_add(centerIm, dd_make(dyPix, 0.0));

    bool isJulia = params.mode == MODE_JULIA;
    DD zRe = isJulia ? pRe : dd_make(0.0, 0.0);
    DD zIm = isJulia ? pIm : dd_make(0.0, 0.0);
    // Julia's added constant is a single fixed value, never itself the
    // target of deep zoom, so plain float precision (no low component) is
    // plenty -- unlike the coordinate DDs above.
    DD addRe = isJulia ? dd_make(params.juliaC.x, 0.0) : pRe;
    DD addIm = isJulia ? dd_make(params.juliaC.y, 0.0) : pIm;

    // The coloring-only derivative/trap tracking below deliberately uses
    // plain float precision (the dd z's .hi component) rather than full
    // double-double arithmetic: distance estimation and orbit traps only
    // need a visually plausible gradient/trap distance, not positional
    // accuracy, and the actual escape-time iteration above is untouched.
    // d(z)/d(varying quantity): d(z)/dc for Mandelbrot (seeded 0) or
    // d(z)/dz0 for Julia (seeded 1, the identity derivative at the start).
    float dzRe = isJulia ? 1.0 : 0.0, dzIm = 0.0;
    float trapDist = 1e10;
    uint n = 0;
    float mag2 = 0.0;
    for (; n < params.maxIterations; n++) {
        DD zRe2 = dd_mul(zRe, zRe);
        DD zIm2 = dd_mul(zIm, zIm);
        mag2 = zRe2.hi + zIm2.hi;
        if (mag2 > params.escapeRadiusSq) break;

        // See the matching guard in mandelbrotFloat32 for why Julia keeps n=0.
        if (params.colorMode == COLOR_MODE_ORBIT_TRAP && (n > 0 || isJulia)) {
            trapDist = min(trapDist, orbitTrapDistance(zRe.hi, zIm.hi, params.trapType, params.trapParamX, params.trapParamY));
        }
        if (params.colorMode == COLOR_MODE_DISTANCE_EST) {
            float newDzRe = 2.0 * (zRe.hi * dzRe - zIm.hi * dzIm) + (isJulia ? 0.0 : 1.0);
            float newDzIm = 2.0 * (zRe.hi * dzIm + zIm.hi * dzRe);
            dzRe = newDzRe;
            dzIm = newDzIm;
        }

        DD twoZReZIm = dd_mul(dd_make(2.0 * zRe.hi, 2.0 * zRe.lo), zIm);
        zIm = dd_add(twoZReZIm, addIm);
        zRe = dd_add(dd_sub(zRe2, zIm2), addRe);
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

// ---------------------------------------------------------------------------
// Mandelbulb: 3D ray-marched fractal, a separate explorer sharing this
// library only for build/compile-pipeline convenience. All-scalar layout for
// the same reason as `PaletteParams` above (no float3/float4 struct members).
// ---------------------------------------------------------------------------
struct MandelbulbParams {
    float eyeX, eyeY, eyeZ;
    float rightX, rightY, rightZ;
    float upX, upY, upZ;
    float forwardX, forwardY, forwardZ;
    uint  width;
    uint  height;
    float tanHalfFov;
    float power;
    uint  maxIterations;   // DE fractal-formula iteration count
    uint  maxRaySteps;
    float epsilon;
    float maxDistance;
    uint  variant;         // 0 classic, 1 abs-transform (hollow/boxy look)
    uint  aoEnabled;
    uint  shadowsEnabled;
    float lightAzimuth;
    float lightElevation;
    float ambientStrength;
};

/// Standard Mandelbulb distance estimator (power-N triplex formula, per
/// Inigo Quilez / White & Nylander): r = |z|, theta = acos(z.z/r),
/// phi = atan2(z.y, z.x), then z = r^power * (spherical basis of
/// power*theta, power*phi) + pos. `trapOut` returns the orbit's closest
/// approach to the origin, reused as a cheap coloring signal.
inline float mandelbulbDE(float3 pos, float power, int maxIterations, int variant, thread float &trapOut) {
    float3 z = pos;
    float dr = 1.0;
    float r = 0.0;
    float trap = 1e10;
    for (int i = 0; i < maxIterations; i++) {
        r = length(z);
        trap = min(trap, r);
        if (r > 2.0) break;

        float theta = acos(clamp(z.z / max(r, 1e-6), -1.0, 1.0));
        float phi = atan2(z.y, z.x);
        float zr = pow(r, power);
        dr = pow(r, power - 1.0) * power * dr + 1.0;
        theta *= power;
        phi *= power;

        float3 z2 = zr * float3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta));
        if (variant == 1) { z2 = fabs(z2); } // hollow/boxy variant
        z = z2 + pos;
    }
    trapOut = trap;
    float safeR = max(r, 1e-6);
    return 0.5 * log(safeR) * safeR / dr;
}

inline float mandelbulbDESimple(float3 pos, float power, int maxIterations, int variant) {
    float unused;
    return mandelbulbDE(pos, power, maxIterations, variant, unused);
}

inline float3 mandelbulbNormal(float3 p, float power, int maxIterations, int variant) {
    float2 e = float2(1.0, -1.0) * 0.0005;
    return normalize(
        e.xyy * mandelbulbDESimple(p + e.xyy, power, maxIterations, variant) +
        e.yyx * mandelbulbDESimple(p + e.yyx, power, maxIterations, variant) +
        e.yxy * mandelbulbDESimple(p + e.yxy, power, maxIterations, variant) +
        e.xxx * mandelbulbDESimple(p + e.xxx, power, maxIterations, variant)
    );
}

/// Cheap ambient occlusion: samples the DE outward along the normal at a few
/// increasing distances -- a big gap between "how far we moved" and "how
/// much empty space the DE reports" means nearby geometry is crowding this
/// point in, so darken it.
inline float mandelbulbAO(float3 p, float3 n, float power, int maxIterations, int variant) {
    float occlusion = 0.0;
    float weight = 1.0;
    for (int i = 1; i <= 5; i++) {
        float dist = 0.02 * float(i);
        float d = mandelbulbDESimple(p + n * dist, power, maxIterations, variant);
        occlusion += (dist - d) * weight;
        weight *= 0.6;
    }
    return saturate(1.0 - 1.5 * occlusion);
}

/// Classic IQ soft-shadow trick: march toward the light and track the
/// tightest ratio of (distance to nearest surface) / (distance traveled) --
/// a ray that stays comfortably clear of everything the whole way reports
/// near 1 (fully lit); one that grazes past something nearby reports a
/// small ratio (penumbra) well before it would actually be blocked outright.
inline float mandelbulbSoftShadow(float3 ro, float3 rd, float power, int maxIterations, int variant, float maxDist) {
    float res = 1.0;
    float t = 0.02;
    for (int i = 0; i < 32; i++) {
        float d = mandelbulbDESimple(ro + rd * t, power, maxIterations, variant);
        if (d < 0.0005) { return 0.0; }
        res = min(res, 16.0 * d / t);
        t += clamp(d, 0.005, 0.5);
        if (t > maxDist) break;
    }
    return saturate(res);
}

/// Bilinear-resamples `sourceTexture` into `outTexture`, whatever their
/// relative sizes -- used to composite the Mandelbulb's render-resolution
/// output texture into the (generally differently-sized) drawable, the same
/// sampling trick the 2D palette pass already relies on for its fast
/// reduced-quality preview path.
kernel void resampleColor(texture2d<float, access::sample> sourceTexture [[texture(0)]],
                          texture2d<float, access::write> outTexture [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]])
{
    uint outWidth = outTexture.get_width();
    uint outHeight = outTexture.get_height();
    if (gid.x >= outWidth || gid.y >= outHeight) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(outWidth, outHeight);
    outTexture.write(sourceTexture.sample(s, uv), gid);
}

kernel void mandelbulbRender(texture2d<float, access::write> outTexture [[texture(0)]],
                              constant MandelbulbParams &params [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= params.width || gid.y >= params.height) return;

    float3 eye = float3(params.eyeX, params.eyeY, params.eyeZ);
    float3 right = float3(params.rightX, params.rightY, params.rightZ);
    float3 up = float3(params.upX, params.upY, params.upZ);
    float3 forward = float3(params.forwardX, params.forwardY, params.forwardZ);

    float2 uv = (float2(gid) + 0.5) / float2(params.width, params.height);
    float2 ndc = uv * 2.0 - 1.0;
    ndc.y = -ndc.y;
    float aspect = float(params.width) / float(params.height);

    float3 rd = normalize(forward + ndc.x * params.tanHalfFov * aspect * right + ndc.y * params.tanHalfFov * up);
    float3 ro = eye;

    int maxIterations = int(params.maxIterations);
    int variant = int(params.variant);

    float t = 0.0;
    bool hit = false;
    float trap = 1e10;
    for (int steps = 0; steps < int(params.maxRaySteps); steps++) {
        float3 p = ro + rd * t;
        float localTrap;
        float d = mandelbulbDE(p, params.power, maxIterations, variant, localTrap);
        if (d < params.epsilon * max(1.0, t)) {
            hit = true;
            trap = localTrap;
            break;
        }
        t += d;
        if (t > params.maxDistance) break;
    }

    float3 lightDir = normalize(float3(
        cos(params.lightAzimuth) * cos(params.lightElevation),
        sin(params.lightElevation),
        sin(params.lightAzimuth) * cos(params.lightElevation)
    ));

    float3 color;
    if (hit) {
        float3 p = ro + rd * t;
        float3 n = mandelbulbNormal(p, params.power, maxIterations, variant);
        float ao = (params.aoEnabled != 0) ? mandelbulbAO(p, n, params.power, maxIterations, variant) : 1.0;
        float shadow = (params.shadowsEnabled != 0)
            ? mandelbulbSoftShadow(p + n * 0.01, lightDir, params.power, maxIterations, variant, params.maxDistance)
            : 1.0;
        float diffuse = max(dot(n, lightDir), 0.0);

        // Base material color from the orbit trap (closest approach to the
        // origin during the DE iteration) mixed across a small fixed
        // gradient, so the surface reads with some richness rather than a
        // single flat material tone.
        float tNorm = saturate(trap / 2.0);
        float3 colorA = float3(0.12, 0.05, 0.35);
        float3 colorB = float3(0.90, 0.40, 0.10);
        float3 base = mix(colorA, colorB, tNorm);

        float ambient = params.ambientStrength;
        float lighting = ambient * ao + diffuse * shadow * (1.0 - ambient);
        color = base * lighting;

        // Cheap depth fog so distant structure recedes instead of every
        // surface reading at the same brightness regardless of distance.
        float fog = 1.0 - saturate(t / params.maxDistance);
        float3 skyColor = float3(0.015, 0.015, 0.035);
        color = mix(skyColor, color, fog);
    } else {
        float skyT = saturate(rd.y * 0.5 + 0.5);
        color = mix(float3(0.015, 0.015, 0.035), float3(0.05, 0.07, 0.12), skyT);
    }

    outTexture.write(float4(color, 1.0), gid);
}
