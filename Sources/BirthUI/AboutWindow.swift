import AppKit
import SwiftUI

/// Custom About window (kooky-style): icon, version, tagline, repository
/// link, and the author credit — replacing the bare system about panel.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 78, height: 78)
                .padding(.bottom, 12)
            Text(BirthInfo.name)
                .font(.system(size: 28, weight: .medium))
            Text("版本 \(BirthInfo.displayVersion)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Text(BirthInfo.tagline)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
            aboutLink("GitHub ↗", url: BirthInfo.repositoryURL)
                .padding(.top, 14)
            Rectangle()
                .fill(.quaternary)
                .frame(width: 32, height: 1)
                .padding(.vertical, 16)
            Text("© \(BirthInfo.copyrightYear) \(BirthInfo.name). All rights reserved.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            HStack(spacing: 0) {
                Text("Built with ❤️ by ")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                aboutLink(BirthInfo.author, url: BirthInfo.authorURL, font: .system(size: 9, design: .monospaced))
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 36)
        .padding(.top, 44)
        .padding(.bottom, 28)
        .frame(width: 360)
    }

    private func aboutLink(
        _ title: String,
        url: URL,
        font: Font = .system(size: 11, design: .monospaced)
    ) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Text(title)
                .font(font)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

@MainActor
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private init() { super.init(window: nil) }
    required init?(coder: NSCoder) { fatalError("not a storyboard window") }

    func show() {
        buildWindowIfNeeded()
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindowIfNeeded() {
        guard window == nil else { return }
        let host = NSHostingController(rootView: AboutView())
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.title = "关于 \(BirthInfo.name)"
        window.styleMask = [.titled, .closable]
        // Name/version live in the content, so hide the titlebar text.
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        self.window = window
    }
}

private extension View {
    /// Pointing-hand cursor on hover — links should feel clickable.
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
