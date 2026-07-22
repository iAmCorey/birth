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

/// The enable/disable switch for a launchd item, with optimistic
/// animation: the knob slides immediately on click and slides back if
/// the operation fails. While the call is in flight the switch stays
/// visible (dimmed, disabled) instead of being swapped for a spinner —
/// swapping killed the slide, which IS the feedback.
struct EnablementToggle: View {
    private var state: AppState { .shared }
    let item: LaunchItem
    @State private var pending: Bool?

    private var isBusy: Bool { state.busyItemIDs.contains(item.id) }

    var body: some View {
        Toggle(
            "",
            isOn: Binding(
                get: {
                    // The pending value drives the knob for as long as it
                    // exists — it is only cleared (inside withAnimation)
                    // after the call settles, so a failed toggle slides
                    // back instead of snapping (Codex P2).
                    if let pending { return pending }
                    return item.enablement.isEnabled ?? false
                },
                set: { newValue in
                    withAnimation { pending = newValue }
                    state.setEnabled(newValue, item: item)
                }
            )
        )
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(isBusy)
        .opacity(isBusy ? 0.5 : 1)
        .onChange(of: isBusy) { _, busy in
            if !busy {
                // Success: the real value now equals pending — no motion.
                // Failure: clearing pending slides the knob back.
                withAnimation { pending = nil }
            }
        }
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
