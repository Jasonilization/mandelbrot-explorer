import Foundation
import CoreGraphics

/// The camera. Center is stored at arbitrary precision so that repeated
/// pan/zoom operations at extreme depth never drift back down to float64 —
/// the precision budget (`precisionTerms`) grows automatically with zoom.
struct Viewport {
    var center: ComplexExpansion
    var spanX: Double

    static let initialSpanX = 4.0

    static func initial() -> Viewport {
        Viewport(center: ComplexExpansion(re: Expansion(-0.5), im: Expansion(0.0)), spanX: initialSpanX)
    }

    var zoomFactor: Double {
        Viewport.initialSpanX / spanX
    }

    var precisionTerms: Int {
        requiredPrecisionTerms(forZoom: zoomFactor)
    }

    var tier: RenderTier {
        RenderTier.select(forZoom: zoomFactor)
    }

    func pixelSize(viewWidthPixels: Double) -> Double {
        spanX / viewWidthPixels
    }

    mutating func pan(dxPixels: Double, dyPixels: Double, viewWidthPixels: Double) {
        guard viewWidthPixels > 0 else { return }
        let pixelSize = spanX / viewWidthPixels
        let dRe = -dxPixels * pixelSize
        let dIm = dyPixels * pixelSize
        let precision = precisionTerms
        center = center.adding(
            ComplexExpansion(re: Expansion(dRe), im: Expansion(dIm)),
            precision: precision
        )
    }

    /// Zoom by `factor` (>1 = in, <1 = out), keeping `screenPoint` fixed on screen.
    mutating func zoom(by factor: Double, aroundScreenPoint: CGPoint, viewSize: CGSize) {
        guard viewSize.width > 0, factor > 0 else { return }
        let pixelSize = spanX / Double(viewSize.width)
        let dx = (Double(aroundScreenPoint.x) - Double(viewSize.width) / 2) * pixelSize
        let dy = (Double(viewSize.height) / 2 - Double(aroundScreenPoint.y)) * pixelSize
        let precision = precisionTerms
        let shift = 1.0 - 1.0 / factor
        center = center.adding(
            ComplexExpansion(re: Expansion(dx * shift), im: Expansion(dy * shift)),
            precision: precision
        )
        spanX = spanX / factor
        // Clamp to avoid pathological zoom-out past the classic view or
        // zoom-in past what our precision budget / Double exponent range support.
        spanX = min(spanX, 6.0)
        spanX = max(spanX, 1e-290)
    }

    mutating func reset() {
        self = Viewport.initial()
    }

    /// Best double-precision approximation of the center, valid for tiers
    /// that don't need arbitrary precision (float32 / double-double GPU tiers).
    var centerApprox: SIMD2<Double> {
        center.approximateValue
    }
}
