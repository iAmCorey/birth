import AppKit
import BirthCore
import SwiftUI

/// The toolbar refresh control both sections share: same ⌘R, same
/// disabled state, and the icon yields to a same-size spinner in place
/// (Mail/Xcode-style) so nothing in the toolbar moves.
struct RefreshToolbarButton: View {
    private var state: AppState { .shared }

    var body: some View {
        Button {
            Task { await state.refresh(userInitiated: true) }
        } label: {
            ZStack {
                Label("刷新", systemImage: "arrow.clockwise")
                    .opacity(state.isLoading ? 0 : 1)
                if state.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(state.isLoading)
    }
}

/// A bordered row-action button that swaps to an in-place spinner while
/// its System Events mutation is in flight — same footprint, no jumps.
struct MutationButton: View {
    let title: String
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isBusy ? 0 : 1)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isBusy)
    }
}

/// App icons looked up once per path — each lookup is an IconServices
/// round-trip, and rows re-render on every busy-set change and every
/// streamed signature result.
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(forPath path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}
