import SwiftUI

/// A compact strip showing a palette's cyclic gradient, shared by the
/// sidebar's live preview and the Palette Editor. SwiftUI's `LinearGradient`
/// doesn't wrap, so the first stop's color is appended once more at
/// location 1.0 to make the strip read as the seamless cycle the renderer
/// actually produces.
struct PaletteGradientPreview: View {
    let palette: ColorPalette
    var height: CGFloat = 22

    var body: some View {
        let sorted = palette.sortedStops
        var stops = sorted.map { Gradient.Stop(color: $0.color, location: $0.position) }
        if let first = sorted.first {
            stops.append(Gradient.Stop(color: first.color, location: 1.0))
        }
        return LinearGradient(gradient: Gradient(stops: stops), startPoint: .leading, endPoint: .trailing)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary, lineWidth: 1))
    }
}
