import CoreGraphics
import Foundation

/// Composites a rendered fractal image into a macOS "Liquid Glass"-style app
/// icon: a dark squircle background, a circular glass panel holding the
/// fractal with a soft drop shadow, a bright rim-light along its top edge,
/// and a soft specular highlight -- the visual language macOS Tahoe icons
/// use (dark glass card, top-lit) approximated with plain CoreGraphics
/// gradients/shadows rather than the system's live glass material, since
/// this app ships a single flat PNG rather than a layered Icon Composer
/// asset.
enum AppIconRenderer {
    static func compositeGlassIcon(fractal: CGImage, canvasSize: CGFloat = 1024) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(canvasSize), height: Int(canvasSize),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let full = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
        let cornerRadius = canvasSize * 0.223 // matches macOS's own squircle proportions closely enough
        let bgPath = CGPath(roundedRect: full, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        // 1. Dark glass background: a cool near-black vertical gradient,
        // clipped to the squircle so the corners stay transparent.
        ctx.saveGState()
        ctx.addPath(bgPath)
        ctx.clip()
        let bgColors = [
            CGColor(red: 0.055, green: 0.06, blue: 0.085, alpha: 1),
            CGColor(red: 0.015, green: 0.017, blue: 0.03, alpha: 1)
        ] as CFArray
        let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0, 1])!
        ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 0, y: canvasSize), end: CGPoint(x: 0, y: 0), options: [])

        // Faint cool vignette glow behind the panel so the dark background
        // doesn't read as perfectly flat.
        let glowColors = [
            CGColor(red: 0.10, green: 0.14, blue: 0.22, alpha: 0.9),
            CGColor(red: 0.10, green: 0.14, blue: 0.22, alpha: 0)
        ] as CFArray
        let glowGradient = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0, 1])!
        ctx.drawRadialGradient(
            glowGradient,
            startCenter: CGPoint(x: canvasSize * 0.5, y: canvasSize * 0.54), startRadius: 0,
            endCenter: CGPoint(x: canvasSize * 0.5, y: canvasSize * 0.54), endRadius: canvasSize * 0.62,
            options: []
        )
        ctx.restoreGState()

        // 2. Glass panel: a circle holding the fractal, inset with margin.
        let margin = canvasSize * 0.12
        let panelRect = full.insetBy(dx: margin, dy: margin)

        ctx.saveGState()
        ctx.addPath(bgPath)
        ctx.clip()

        // Soft drop shadow beneath the panel for depth.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -canvasSize * 0.018), blur: canvasSize * 0.05, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.65))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.addEllipse(in: panelRect)
        ctx.fillPath()
        ctx.restoreGState()

        // Fractal image, clipped to the circular panel, scaled to fill it.
        ctx.saveGState()
        ctx.addEllipse(in: panelRect)
        ctx.clip()
        ctx.draw(fractal, in: panelRect)

        // Subtle glass sheen: a soft light-to-clear diagonal gradient over
        // the top half of the panel, on top of the fractal.
        let sheenColors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0)
        ] as CFArray
        let sheenGradient = CGGradient(colorsSpace: colorSpace, colors: sheenColors, locations: [0, 1])!
        ctx.drawLinearGradient(
            sheenGradient,
            start: CGPoint(x: panelRect.midX, y: panelRect.maxY),
            end: CGPoint(x: panelRect.midX, y: panelRect.midY),
            options: []
        )
        ctx.restoreGState()

        // Soft specular highlight blob, upper-left of the panel.
        ctx.saveGState()
        ctx.addEllipse(in: panelRect)
        ctx.clip()
        let specColors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.38),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0)
        ] as CFArray
        let specGradient = CGGradient(colorsSpace: colorSpace, colors: specColors, locations: [0, 1])!
        let specCenter = CGPoint(x: panelRect.minX + panelRect.width * 0.30, y: panelRect.maxY - panelRect.height * 0.26)
        ctx.drawRadialGradient(specGradient, startCenter: specCenter, startRadius: 0, endCenter: specCenter, endRadius: panelRect.width * 0.4, options: [])
        ctx.restoreGState()

        // Bright, thin rim-light tracing the panel's top edge -- the
        // clearest "glass" tell. Built by stroking the circle then
        // clipping a gradient to that thin ring, so the highlight fades
        // smoothly from the top down to nothing at the sides/bottom.
        ctx.saveGState()
        ctx.addEllipse(in: panelRect)
        ctx.setLineWidth(canvasSize * 0.01)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let rimColors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.75),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0)
        ] as CFArray
        let rimGradient = CGGradient(colorsSpace: colorSpace, colors: rimColors, locations: [0, 1])!
        ctx.drawLinearGradient(rimGradient, start: CGPoint(x: panelRect.midX, y: panelRect.maxY), end: CGPoint(x: panelRect.midX, y: panelRect.midY), options: [])
        ctx.restoreGState()

        ctx.restoreGState() // panel clip

        // 3. Faint outer rim-light along the whole squircle's top edge, the
        // same trick applied to the icon's own outer boundary.
        ctx.saveGState()
        ctx.addPath(bgPath)
        ctx.setLineWidth(canvasSize * 0.006)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let outerRimColors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.28),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0)
        ] as CFArray
        let outerRimGradient = CGGradient(colorsSpace: colorSpace, colors: outerRimColors, locations: [0, 1])!
        ctx.drawLinearGradient(outerRimGradient, start: CGPoint(x: canvasSize / 2, y: canvasSize), end: CGPoint(x: canvasSize / 2, y: canvasSize * 0.6), options: [])
        ctx.restoreGState()

        return ctx.makeImage()
    }
}
