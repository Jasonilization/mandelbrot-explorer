import SwiftUI

struct StatusBarView: View {
    @ObservedObject var renderer: FractalRenderer

    var body: some View {
        HStack(spacing: 18) {
            Label(coordinateText, systemImage: "location")
            Label(zoomText, systemImage: "plus.magnifyingglass")

            Spacer()

            if renderer.isRefining {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Refining…")
                }
                .foregroundStyle(.secondary)
            }

            Label(String(format: "%.0f FPS", renderer.fps), systemImage: "speedometer")
            Label(String(format: "%.1f ms", renderer.lastRenderTimeMs), systemImage: "timer")
            Label("\(renderer.renderWidth)×\(renderer.renderHeight)", systemImage: "rectangle.dashed")
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var coordinateText: String {
        let c = renderer.viewport.centerApprox
        return String(format: "%.12f, %.12fi", c.x, c.y)
    }

    private var zoomText: String {
        let z = renderer.viewport.zoomFactor
        if z < 1000 { return String(format: "%.1f×", z) }
        return String(format: "%.2e×", z)
    }
}
