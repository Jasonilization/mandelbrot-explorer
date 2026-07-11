import SwiftUI

/// Built-in tutorial + about sheet, presented from the toolbar's Help
/// button. Beginner-friendly but technically accurate, per topic: what the
/// Mandelbrot set actually is, controls, why deep zoom needs perturbation,
/// what the three rendering modes are, and who built this.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: HelpTopic = .whatIsMandelbrot

    enum HelpTopic: String, CaseIterable, Identifiable, Hashable {
        case whatIsMandelbrot = "What is the Mandelbrot Set?"
        case controls = "Controls"
        case juliaSet = "Julia Set Explorer"
        case deepZoom = "Deep Zoom & Precision"
        case renderingModes = "Rendering Modes"
        case colorEngine = "Color Engine"
        case mandelbulb = "Mandelbulb Explorer"
        case about = "About"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .whatIsMandelbrot: "sparkles"
            case .controls: "hand.draw"
            case .juliaSet: "atom"
            case .deepZoom: "magnifyingglass"
            case .renderingModes: "cpu"
            case .colorEngine: "paintpalette"
            case .mandelbulb: "cube.transparent"
            case .about: "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: $selection) { topic in
                Label(topic.rawValue, systemImage: topic.icon).tag(topic)
            }
            .navigationSplitViewColumnWidth(210)
        } detail: {
            ScrollView {
                HStack {
                    content
                        .frame(maxWidth: 540, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .padding(28)
            }
        }
        .frame(width: 760, height: 540)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .whatIsMandelbrot: whatIsMandelbrotContent
        case .controls: controlsContent
        case .juliaSet: juliaSetContent
        case .deepZoom: deepZoomContent
        case .renderingModes: renderingModesContent
        case .colorEngine: colorEngineContent
        case .mandelbulb: mandelbulbContent
        case .about: aboutContent
        }
    }

    // MARK: - What is the Mandelbrot Set?

    private var whatIsMandelbrotContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Heading("What is the Mandelbrot Set?")

            Paragraph("""
            For every point c on this screen, the app repeats one simple rule, starting from z = 0:
            """)

            FormulaBadge("z → z² + c")

            Paragraph("""
            That means: square the current value of z, add c, and use the result as the new z. \
            Then do it again. And again. Every pixel on screen is a different value of c, and \
            each one runs this rule independently.
            """)

            BulletPoint(
                title: "Points that stay bounded are \"inside\" the set",
                body: "If z never grows past a certain size no matter how many times you repeat the rule, c belongs to the Mandelbrot set. Those points are colored with the interior color -- black by default."
            )
            BulletPoint(
                title: "Points that escape are \"outside\" the set",
                body: "If z's magnitude blows past the escape radius, it will keep growing forever -- c is not in the set. The only question left is how quickly it escaped."
            )
            BulletPoint(
                title: "Color encodes escape speed, not position",
                body: "Points that escape almost immediately get one color; points that take hundreds of iterations to escape get another. That's what produces the bands and swirls -- they're contour lines of \"how long this point resisted escaping,\" smoothly interpolated so they don't look blocky."
            )

            gradientSwatch

            Paragraph("""
            The infinitely detailed boundary between "escapes" and "never escapes" is the actual \
            fractal -- and it looks different at every scale, which is why zooming in never runs out \
            of new detail to show you.
            """)
        }
    }

    private var gradientSwatch: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fast escape → slow escape → never escapes")
                .font(.caption)
                .foregroundStyle(.secondary)
            LinearGradient(
                colors: ColorPalette.default.sortedStops.map(\.color) + [.black],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    // MARK: - Controls

    private var controlsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Heading("Controls")

            ControlRow(icon: "computermouse", title: "Scroll / mouse wheel", body: "Zoom in or out, centered on the cursor.")
            ControlRow(icon: "hand.draw", title: "Click and drag", body: "Pan around the current view.")
            ControlRow(icon: "arrow.up.left.and.arrow.down.right", title: "Trackpad pinch", body: "Zoom, as an alternative to scrolling.")
            ControlRow(icon: "mappin.and.ellipse", title: "Presets", body: "Jump straight to well-known interesting locations, from the full set down to a deep Seahorse Valley coordinate.")
            ControlRow(icon: "scope", title: "Smart Auto Zoom", body: "Continuously zooms in on its own, steering toward detailed boundary structure and searching nearby if it wanders somewhere flat and boring.")
            ControlRow(icon: "video.badge.waveform", title: "Record Zoom Journey", body: "Renders an auto-zoom journey to a video file at full quality, independent of how fast your Mac can actually render it live.")
            ControlRow(icon: "square.and.arrow.down", title: "Save Image", body: "Exports the current view as a full-resolution PNG.")
            ControlRow(icon: "atom", title: "Double-click a point", body: "Jumps to the Julia Set Explorer tab, using that exact point as its fixed c value -- see the Julia Set Explorer topic. The sidebar's \"Open Julia Set at Center\" button does the same for the current view's center.")

            Paragraph("""
            Iteration count normally auto-scales with zoom depth -- deeper zooms need more \
            iterations to resolve fine detail near the boundary. Touch the Iterations stepper \
            yourself to take manual control; it won't be silently overridden after that.
            """)
        }
    }

    // MARK: - Julia Set Explorer

    private var juliaSetContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Heading("Julia Set Explorer")

            Paragraph("""
            The Julia Set Explorer uses the exact same rule as the Mandelbrot Set, z → z² + c, and the \
            exact same rendering engine -- GPU tiers, perturbation for deep zoom, series approximation, \
            progressive rendering, the whole color pipeline. The only thing that changes is which \
            quantity is fixed and which one varies:
            """)

            FormulaBadge("z → z² + c")

            BulletPoint(
                title: "Mandelbrot: c varies, z starts at 0",
                body: "Every pixel is a different value of c, and each one asks the same question: starting from z=0, does this c's orbit stay bounded?"
            )
            BulletPoint(
                title: "Julia: c is fixed, z varies",
                body: "One single c value applies to the entire image. Every pixel is a different starting value of z, and each one asks: starting from this z, does the orbit stay bounded under this one fixed c?"
            )

            Paragraph("""
            The Mandelbrot set is a map of all possible Julia sets. Each point in the Mandelbrot set \
            represents a different Julia universe -- points deep inside a bulb tend to produce Julia \
            sets that are one connected blob; points out in the filaments and dust tend to produce Julia \
            sets that shatter into disconnected, dust-like pieces. Points right on the boundary -- where \
            the Mandelbrot set's own infinite detail lives -- tend to produce the most intricate Julia \
            sets of all.
            """)

            BulletPoint(
                title: "Jumping from Mandelbrot to Julia",
                body: "Double-click any point in the Mandelbrot Explorer (or use its sidebar's \"Open Julia Set at Center\" button) to open the Julia Set Explorer with that exact point as c."
            )
            BulletPoint(
                title: "Julia Parameter controls",
                body: "Type exact real/imaginary values, drag their sliders for a live-updating preview, hit Random Julia for a c value biased toward the Mandelbrot set's richly-detailed boundary region, or jump straight to a named preset like Douady's Rabbit or San Marco."
            )
            BulletPoint(
                title: "Favorites",
                body: "Save any c value you land on with a name of your choosing; saved favorites persist between launches, just like custom palettes."
            )

            Paragraph("""
            Everything else works exactly like the Mandelbrot tab: smooth zooming (including all the way \
            down into perturbation-tier deep zoom on the Julia set's own boundary detail), the full color \
            engine and palette editor, and the same PNG export and zoom-journey recording.
            """)
        }
    }

    // MARK: - Deep Zoom & Precision

    private var deepZoomContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Heading("Deep Zoom & Precision")

            Paragraph("""
            Ordinary computer math (a "double") only carries about 15-16 decimal digits of \
            precision. Zoom in past roughly 10¹³× and the coordinates of neighboring pixels become \
            so close together that a double can no longer tell them apart -- the image dissolves \
            into flat, blocky noise instead of detail.
            """)

            BulletPoint(
                title: "The fix isn't \"more digits everywhere\"",
                body: "Recomputing every pixel from scratch at arbitrary precision would work, but it's far too slow to feel interactive -- arbitrary-precision arithmetic can be hundreds of times slower than hardware math."
            )
            BulletPoint(
                title: "Perturbation theory: one expensive orbit, many cheap deltas",
                body: "The app computes one single high-precision \"reference\" orbit at arbitrary precision. Every pixel then only tracks its own tiny difference (delta) from that shared reference, using ordinary fast hardware math -- because the delta stays small, ordinary precision is enough to represent it accurately, however deep the zoom."
            )
            BulletPoint(
                title: "Series approximation skips the boring part",
                body: "Early iterations tend to be nearly identical for every pixel in the frame. The app fits a small polynomial to the reference orbit and uses it to jump every pixel straight to the iteration where they actually start to diverge, instead of recomputing that shared history one pixel at a time."
            )
            BulletPoint(
                title: "Glitch detection keeps it honest",
                body: "Occasionally a pixel's true orbit passes too close to the reference orbit for the delta math to stay accurate. The renderer detects this (the \"Pauldelbrot\" criterion) and quietly re-computes a fresh reference for just those pixels, so accuracy never silently degrades."
            )

            Paragraph("""
            The practical result: this explorer can zoom to roughly 10¹³× and well beyond -- \
            10⁸⁰× and deeper is routine -- without the image ever breaking down into precision noise.
            """)
        }
    }

    // MARK: - Rendering Modes

    private var renderingModesContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Heading("Rendering Modes")

            Paragraph("""
            The sidebar's Precision Tier and the status bar both show which of three modes is \
            active. The app switches between them automatically as you zoom -- there's nothing to \
            configure, but it helps to know what's happening under the hood.
            """)

            ModeRow(
                icon: "bolt.fill", color: .green,
                title: "GPU -- Float32",
                body: "Direct iteration in native 32-bit float, fully parallel on the GPU. Fastest mode; used up to about 10⁵× zoom, where float32's ~7 digits of precision start to run out."
            )
            ModeRow(
                icon: "bolt.badge.clock", color: .blue,
                title: "GPU -- Double-Double",
                body: "Apple GPUs have no native 64-bit double, so this emulates one by pairing two float32s per coordinate with error-compensated arithmetic. Roughly matches real hardware double precision, still fully parallel on the GPU. Covers zoom up to about 10¹³×."
            )
            ModeRow(
                icon: "cpu", color: .orange,
                title: "CPU -- Perturbation (arbitrary precision)",
                body: "Beyond ~10¹³×, even double-double isn't enough. This mode computes one arbitrary-precision reference orbit on the CPU, then every pixel tracks its delta from it in parallel across all your CPU cores, accelerated by series approximation. Effectively unbounded zoom depth, at CPU rather than GPU speed."
            )

            Paragraph("""
            The transition between modes is designed to be invisible: quality never visibly drops \
            at a tier boundary, and the CPU tier renders a fast low-resolution preview immediately, \
            filling in full detail progressively rather than freezing the view.
            """)
        }
    }

    // MARK: - Color Engine

    private var colorEngineContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Heading("Color Engine")

            Paragraph("""
            The sidebar's Color section controls how the same underlying render data gets turned \
            into pixels. All of it -- color mode, palette, smoothing, shading -- works identically \
            whether the current view is on the GPU float32/double-double tiers or the CPU \
            perturbation tier.
            """)

            ModeRow(icon: "timer", color: .green, title: "Escape Time",
                    body: "The classic mode: colors by how many iterations a point takes to escape. Smooth Coloring blends between iterations for a continuous gradient; turning it off shows the classic discrete bands instead.")
            ModeRow(icon: "ruler", color: .blue, title: "Distance Estimation",
                    body: "Colors by the estimated distance from each point to the fractal boundary itself, producing crisp contour-like detail that doesn't depend on iteration banding.")
            ModeRow(icon: "scope", color: .orange, title: "Orbit Trap",
                    body: "Colors by how closely each point's orbit passes a chosen shape -- circle, line, cross, or a custom point -- painted across the whole set (interior included), which is what gives it a richly patterned, almost woven look.")

            BulletPoint(title: "Palette Editor", body: "Add, remove, and reposition color stops around the gradient; fine-tune each one with a color picker or hue/saturation/brightness sliders; save the result as a custom palette that persists between launches.")
            BulletPoint(title: "Surface Shading", body: "An optional cheap relief-lighting pass: it builds a fake surface normal from the color field's local gradient and lights it, so boundary and orbit-trap structure read as more three-dimensional.")
        }
    }

    // MARK: - Mandelbulb Explorer

    private var mandelbulbContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Heading("Mandelbulb Explorer")

            Paragraph("""
            A separate tab, not a mode of the 2D explorer: a true 3D fractal, generalizing \
            z → z² + c into three dimensions using spherical coordinates.
            """)

            FormulaBadge("r, θ, φ → rⁿ · (spherical basis of n·θ, n·φ) + c")

            Paragraph("""
            Where n is the power (8 for the "classic" Mandelbulb), and r/θ/φ are the point's \
            distance, inclination, and azimuth. Unlike the 2D explorer's direct pixel-by-pixel \
            iteration, this shape has no closed-form 2D slice to just draw -- it's rendered by ray \
            marching: stepping each pixel's ray forward by a distance estimate (derived from the \
            same iteration) until it's close enough to count as a hit.
            """)

            ControlRow(icon: "hand.draw", title: "Click and drag", body: "Orbits the camera around the fractal.")
            ControlRow(icon: "computermouse", title: "Scroll / pinch", body: "Moves the camera closer or farther away.")
            ControlRow(icon: "arrow.counterclockwise", title: "Reset Camera", body: "Returns to the default framing.")

            BulletPoint(title: "Quality tiers", body: "Low is a fast preview; Medium adds ambient occlusion; High adds soft shadows too; Ultra raises ray-march steps and supersamples. Like the 2D explorer, the view automatically renders at reduced quality while the camera is moving and refines to full quality once it settles.")
            BulletPoint(title: "Power and variant", body: "Power reshapes the whole fractal -- lower values look more organic, higher values sharper and spikier. The Hollow Variant toggle applies an abs-transform that carves shell-like cavities into the surface.")
            BulletPoint(title: "Lighting", body: "Direction, elevation, and ambient strength control a simple diffuse light, combined with ambient occlusion and soft self-shadowing when the quality tier allows them.")
        }
    }

    // MARK: - About

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Heading("About")

            Paragraph("Mandelbrot Explorer is a native Swift, SwiftUI, and Metal deep-zoom fractal explorer for Apple Silicon.")

            VStack(alignment: .leading, spacing: 10) {
                Text("Created by Jason")
                    .font(.headline)
                Button {
                    if let url = URL(string: GitHubLink.profileURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(GitHubLink.profileURL, systemImage: "link")
                }
                .buttonStyle(.link)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Shared building blocks

private struct Heading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title2.bold())
    }
}

private struct Paragraph: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
    }
}

private struct FormulaBadge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 22, weight: .semibold, design: .serif))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct BulletPoint: View {
    let title: String
    let body_: String
    init(title: String, body: String) { self.title = title; self.body_ = body }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.bold())
            Text(body_).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ControlRow: View {
    let icon: String
    let title: String
    let body_: String
    init(icon: String, title: String, body: String) { self.icon = icon; self.title = title; self.body_ = body }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(body_).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ModeRow: View {
    let icon: String
    let color: Color
    let title: String
    let body_: String
    init(icon: String, color: Color, title: String, body: String) { self.icon = icon; self.color = color; self.title = title; self.body_ = body }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(body_).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
