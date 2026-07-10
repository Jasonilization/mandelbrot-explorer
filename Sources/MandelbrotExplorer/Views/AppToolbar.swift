import AppKit
import SwiftUI

/// The GitHub link + Help button shared by both the Mandelbrot and
/// Mandelbulb tabs, so switching tabs never loses either -- each tab hosts
/// its own `NavigationSplitView` (and thus its own toolbar), so this is a
/// small reusable `ToolbarContent` rather than something hoisted to a
/// single shared ancestor.
struct AppToolbarButtons: ToolbarContent {
    @Binding var showingHelp: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                if let url = URL(string: GitHubLink.profileURL) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .help("Open GitHub profile")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingHelp = true
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .help("Help & Tutorial")
        }
    }
}
