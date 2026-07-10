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
        case deepZoom = "Deep Zoom & Precision"
        case renderingModes = "Rendering Modes"
        case about = "About"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .whatIsMandelbrot: "sparkles"
            case .controls: "hand.draw"
            case .deepZoom: "magnifyingglass"
            case .renderingModes: "cpu"
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
        case .deepZoom: deepZoomContent
        case .renderingModes: renderingModesContent
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

            Paragraph("""
            Iteration count normally auto-scales with zoom depth -- deeper zooms need more \
            iterations to resolve fine detail near the boundary. Touch the Iterations stepper \
            yourself to take manual control; it won't be silently overridden after that.
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
