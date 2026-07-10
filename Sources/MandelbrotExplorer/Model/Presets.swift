import Foundation

struct Preset: Identifiable {
    let id: String
    let name: String
    let realString: String
    let imagString: String
    let zoom: Double
    let suggestedIterations: Int

    func makeViewport() -> Viewport {
        let precision = requiredPrecisionTerms(forZoom: zoom)
        let re = Expansion(decimalString: realString, precision: precision)
        let im = Expansion(decimalString: imagString, precision: precision)
        return Viewport(center: ComplexExpansion(re: re, im: im), spanX: Viewport.initialSpanX / zoom)
    }

    /// Escape-time detail needs more iterations the deeper you zoom (points
    /// near the boundary take longer to resolve as escaping vs. interior).
    /// Quadratic-in-log(zoom) is a common, cheap-to-evaluate heuristic that
    /// tracks this well without the cost of the real adaptive alternative
    /// (measuring escaped-pixel fraction and re-rendering).
    static func suggestedIterations(forZoom zoom: Double) -> Int {
        let e = max(0, log10(max(zoom, 1)))
        return min(20000, Int(200 + e * e * 60))
    }

    static let all: [Preset] = [
        Preset(id: "full", name: "Full View", realString: "-0.5", imagString: "0.0", zoom: 1, suggestedIterations: suggestedIterations(forZoom: 1)),
        Preset(id: "seahorse", name: "Seahorse Valley", realString: "-0.743643887037151", imagString: "0.131825904205330", zoom: 8e4, suggestedIterations: suggestedIterations(forZoom: 8e4)),
        // Dialed back from a much deeper zoom: past ~12 significant digits
        // this hand-transcribed coordinate isn't independently verified, and
        // an under-specified deep-zoom coordinate reliably lands somewhere
        // visually uninteresting (confirmed by direct cross-check during
        // development -- see PerturbationRenderer verification). This depth
        // stays safely within the trusted digit range.
        Preset(id: "seahorse-deep", name: "Seahorse Valley (Deep)", realString: "-0.7436438870371587", imagString: "0.13182590420533", zoom: 5e11, suggestedIterations: suggestedIterations(forZoom: 5e11)),
        Preset(id: "elephant", name: "Elephant Valley", realString: "0.3245046418497685", imagString: "0.04855101129280834", zoom: 6e4, suggestedIterations: suggestedIterations(forZoom: 6e4)),
        Preset(id: "triple-spiral", name: "Triple Spiral Valley", realString: "-0.088", imagString: "0.654", zoom: 4e2, suggestedIterations: suggestedIterations(forZoom: 4e2)),
        Preset(id: "feigenbaum", name: "Feigenbaum Point", realString: "-1.401155", imagString: "0.0", zoom: 3e2, suggestedIterations: suggestedIterations(forZoom: 3e2)),
        Preset(id: "mini-mandelbrot", name: "Mini Mandelbrot", realString: "-1.7490151959", imagString: "0.00000000001", zoom: 8e5, suggestedIterations: suggestedIterations(forZoom: 8e5)),
    ]
}
