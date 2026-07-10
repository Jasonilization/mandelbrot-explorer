# Mandelbrot Explorer

A high-performance, native fractal visualization suite for Apple Silicon,
built with Swift, SwiftUI, and Metal. Two separate explorers live side by
side in one app:

- **Mandelbrot Explorer** -- GPU-accelerated compute shaders, adaptive
  render quality, three automatically-selected precision tiers (zoom from
  the full set down to ~10^100+ without the image breaking apart into
  pixelated noise), a professional color engine, and a smart auto-zoom that
  steers toward actual detail instead of flat, boring regions.
- **Mandelbulb Explorer** -- a true 3D fractal, ray-marched in real time
  with lighting, ambient occlusion, and soft shadows.

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
   zoom depth is effectively unbounded. Two further optimizations keep it
   fast and responsive:
   - **Series approximation** fits a small polynomial to the reference
     orbit so every pixel can skip the leading iterations that are still
     identical (within tolerance) across the whole frame, instead of
     iterating from scratch.
   - **Progressive tiled rendering** splits the image into tiles processed
     in parallel and streams each one back to the display as it finishes,
     so a slow deep-zoom render visibly fills in rather than freezing on
     the old frame until the whole buffer is ready.

## Smart auto-zoom

Auto-zoom doesn't just dive straight ahead -- it periodically scores a grid
over the last rendered frame for interior/exterior boundary presence and
iteration-count variation, then eases the zoom pivot toward the most
detailed cell. If the view goes flat (a big interior lake, a featureless
exterior) it backs off and sweeps the target around nearby instead of
zooming straight into it, so a journey stays visually interesting rather
than needing to be babysat.

## Color engine

The sidebar's Color section is a full palette/coloring pipeline, working
identically across all three precision tiers:

- **Color modes**: Escape Time (the classic look, smoothable or classic
  banded), Distance Estimation (crisp contour-like detail independent of
  iteration banding), and Orbit Trap (circle/line/cross/custom-point,
  painted across the whole set including the interior).
- **Palette Editor**: add, remove, and reposition color stops around the
  gradient; adjust each stop with a color picker or hue/saturation/
  brightness sliders; save the result as a custom palette that persists
  between launches. Ships with Classic Rainbow, Fire, Ice, Ocean, Neon,
  Monochrome, Scientific, and a few more presets.
- **Surface Shading**: an optional cheap relief-lighting pass that builds a
  fake normal from the color field's own local gradient and lights it, so
  boundary/orbit-trap structure reads as more three-dimensional.
- **Render Resolution**: an internal render scale (0.5x-2x) independent of
  window size, for trading sharpness against frame rate.
- **Lock Cursor to Detail**: while on, manual scroll/pinch zoom nudges its
  pivot point from the raw cursor position onto the most detailed nearby
  boundary structure, so zooming into fine detail doesn't need pixel-perfect
  aim.

## Mandelbulb Explorer

A separate tab, not a mode of the 2D explorer -- a true 3D fractal
generalizing z -> z² + c into three dimensions via spherical coordinates
(the standard power-n Mandelbulb formula), rendered by ray marching a
signed-distance estimate rather than direct pixel iteration.

- **Orbit camera**: click-drag to rotate, scroll/pinch to move closer or
  farther, with smooth eased camera motion.
- **Lighting**: diffuse lighting, ambient occlusion, and soft self-shadows
  (all from the same distance estimator), plus adjustable light direction,
  elevation, and ambient strength.
- **Quality tiers**: Low (fast preview) through Ultra (supersampled, full
  lighting) -- like the 2D explorer, it renders at reduced quality while the
  camera is moving and refines to full quality once it settles.
- **Presets**: Classic Mandelbulb (power 8), Seahorse-like (power 4, more
  organic), Hollow Forms (an abs-transformed variant with shell-like
  cavities), and Spiky Forms (power 12).
- **Export**: Save Screenshot / Export Render write the current view to a
  PNG at a chosen resolution.

## Recording

The sidebar's "Record Zoom Journey" drives that same smart auto-zoom path
offline, at a fixed simulated frame rate independent of how long each frame
actually takes to render, and encodes straight to H.264 `.mov` via
`AVAssetWriter`. Resolution (up to 4K), frame rate, duration, and an
optional zoom-level overlay are all adjustable. Recording takes over the
live viewport for its duration (manual interaction pauses) rather than
running a second, independent render pipeline.

## Help

The toolbar's Help button opens a built-in, beginner-friendly tutorial
covering what the Mandelbrot set actually is (z → z² + c, inside vs.
outside, how color encodes escape speed), controls, why deep zoom needs
perturbation theory, and what each of the three rendering modes does.

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

Mandelbrot tab:
- **Scroll / mouse wheel**: zoom, centered on the cursor (or the nearest
  detailed structure, if Lock Cursor to Detail is on)
- **Click + drag**: pan
- **Trackpad pinch**: zoom (bonus, in addition to the wheel)
- Sidebar: presets, iteration count (auto-scales with zoom unless you
  override it), render resolution, cursor lock, smart auto-zoom, recording,
  color engine (mode/palette/shading), save image
- Status bar: live coordinates, zoom factor, rendering-mode indicator, FPS,
  render time

Mandelbulb tab:
- **Click + drag**: orbit the camera
- **Scroll / pinch**: move closer or farther away
- Sidebar: presets, power/iterations/hollow variant, quality/resolution,
  lighting, reset camera, export

Both tabs share a toolbar (GitHub profile link, built-in Help & Tutorial).

## Project layout

```
Sources/MandelbrotExplorer/
  Model/        Viewport, presets, color palettes/modes/orbit traps,
                precision-tier selection, auto-zoom interestingness scoring,
                Mandelbulb presets/quality tiers
  Precision/    Arbitrary-precision "expansion" arithmetic, reference-orbit,
                series approximation, and the CPU perturbation renderer
  Rendering/    Metal compute shaders (2D Mandelbrot + 3D Mandelbulb) and
                the two renderers that drive them
  Recording/    Offline zoom-journey capture to video (AVFoundation)
  Views/        SwiftUI shell for both tabs (canvas, sidebar, status bar,
                palette editor, help, recording)
  Utils/        Save-image/screenshot, headless preview/diagnostic tooling
```

## Diagnostics

A few environment-variable-gated headless modes exist for verifying the
renderers without a display (used heavily during development to catch
precision and color-mode bugs by comparing tiers against direct
high-precision computation):

- `PRESET_PREVIEW_DIR=<dir>` -- renders every preset plus a zoom-depth
  ladder straight to PNGs.
- `PERTURBATION_DEBUG_SINGLE="re,im,zoom,iterations"` -- renders one
  perturbation-tier frame and cross-checks it against a direct
  arbitrary-precision computation.
- `COLOR_MODE_TEST_DIR=<dir>` -- renders every color mode/orbit trap
  shape/shading combination at both a GPU-tier and a perturbation-tier
  zoom, straight to PNGs.
- `MANDELBULB_TEST_DIR=<dir>` -- renders a handful of Mandelbulb power/
  variant/quality combinations straight to PNGs.
- `ICON_OUTPUT_PATH=<path>` -- renders the source image used for the app
  icon.
- `RECORDING_TEST_PATH=<path.mov>` -- records a short clip headlessly and
  pulls frames back out as PNGs, to catch encoding/orientation/overlay
  regressions without clicking through the record UI.

None of these run during normal use.
