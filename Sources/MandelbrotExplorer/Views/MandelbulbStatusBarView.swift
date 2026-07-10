import SwiftUI

struct MandelbulbStatusBarView: View {
    @ObservedObject var renderer: MandelbulbRenderer

    var body: some View {
        HStack(spacing: 18) {
            Label(String(format: "yaw %.0f° / pitch %.0f°", renderer.yaw * 180 / .pi, renderer.pitch * 180 / .pi), systemImage: "rotate.3d")
            Label(String(format: "%.2f× distance", MandelbulbRenderer.defaultDistance / max(renderer.distance, 0.001)), systemImage: "arrow.up.left.and.arrow.down.right")

            HStack(spacing: 5) {
                Circle().fill(.purple).frame(width: 7, height: 7)
                Text(renderer.quality.rawValue)
            }

            Spacer()

            Label(String(format: "%.0f FPS", renderer.fps), systemImage: "speedometer")
            Label(String(format: "%.1f ms", renderer.lastRenderTimeMs), systemImage: "timer")
            Label("\(renderer.renderWidth)×\(renderer.renderHeight)", systemImage: "rectangle.dashed")
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
