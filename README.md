# Mandelbrot Explorer

A high-performance, native Mandelbrot Set explorer for Apple Silicon, built
with Swift, SwiftUI, and Metal. GPU-accelerated compute shaders, adaptive
render quality, and three automatically-selected precision tiers so you can
zoom from the full set down to ~10^100+ without the image breaking apart
into pixelated noise.

## Precision tiers (auto-selected by zoom depth)

1. **Float32 (GPU)** -- direct escape-time iteration, up to ~10^5 zoom.
2. **Double-double (GPU)** -- two error-compensated float32s per component
   (Apple GPUs have no native `double`), giving roughly real float64
   precision, fully parallel, up to ~10^13 zoom.
3. **Perturbation (CPU, arbitrary precision)** -- one high-precision
   reference orbit computed via a custom arbitrary-precision "expansion"
   type, with every pixel tracking only its tiny delta from that orbit in
   plain hardware `Double`, multithreaded across all CPU cores. This avoids
   the catastrophic cancellation that breaks naive deep-zoom rendering, so
   zoom depth is effectively unbounded.

## Requirements

- Apple Silicon Mac, macOS 14+
- Xcode Command Line Tools (Swift 5.10+ toolchain)

## Development

```bash
./run.sh              # build (debug) and launch
./run.sh release       # build (release) and launch
```

or directly via Swift Package Manager:

```bash
swift build
swift run
```

## Building a distributable app

```bash
Scripts/build_app.sh   # -> dist/Mandelbrot Explorer.app (ad-hoc signed)
Scripts/make_dmg.sh    # -> dist/MandelbrotExplorer-<version>.dmg
```

The app bundle is ad-hoc code signed so it runs directly on this machine.
It is **not** notarized, so on another Mac, Gatekeeper will require the user
to right-click the app and choose "Open" the first time (or run
`xattr -dr com.apple.quarantine "Mandelbrot Explorer.app"` after unzipping).
Proper distribution outside your own machines would need an Apple Developer
ID for signing + notarization.

## Controls

- **Scroll / mouse wheel**: zoom, centered on the cursor
- **Click + drag**: pan
- **Trackpad pinch**: zoom (bonus, in addition to the wheel)
- Sidebar: presets, iteration count (auto-scales with zoom unless you
  override it), color palette, save image
- Status bar: live coordinates, zoom factor, precision tier, FPS, render time

## Project layout

```
Sources/MandelbrotExplorer/
  Model/        Viewport, presets, color palettes, precision-tier selection
  Precision/    Arbitrary-precision "expansion" arithmetic, reference-orbit
                and CPU perturbation renderer
  Rendering/    Metal compute shaders + the renderer that drives them
  Views/        SwiftUI shell (canvas, sidebar, status bar)
  Utils/        Save-image, headless preview/diagnostic tooling
```

## Diagnostics

A few environment-variable-gated headless modes exist for verifying the
renderer without a display (used heavily during development to catch
precision bugs by comparing tiers against direct high-precision
computation):

- `PRESET_PREVIEW_DIR=<dir>` -- renders every preset plus a zoom-depth
  ladder straight to PNGs.
- `PERTURBATION_DEBUG_SINGLE="re,im,zoom,iterations"` -- renders one
  perturbation-tier frame and cross-checks it against a direct
  arbitrary-precision computation.
- `ICON_OUTPUT_PATH=<path>` -- renders the source image used for the app
  icon.

None of these run during normal use.
