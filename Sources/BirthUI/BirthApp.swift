import AppKit
import SwiftUI

public struct BirthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    public init() {}

    public var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1040, height: 680)
        .commands {
            // Custom About panel with the author credit (kooky-style).
            CommandGroup(replacing: .appInfo) {
                Button("关于 \(BirthInfo.name)") {
                    AboutWindowController.shared.show()
                }
            }
            // Finder-style quick jumps to the two everyday destinations.
            CommandGroup(after: .sidebar) {
                Divider()
                Button("启动应用") { AppState.shared.selection = .loginApps }
                    .keyboardShortcut("1", modifiers: .command)
                Button("全部启动项") { AppState.shared.selection = .all }
                    .keyboardShortcut("2", modifiers: .command)
            }
        }
    }
}

/// Makes the app behave like a real GUI app even when launched from
/// `swift run` without a bundle (no Info.plist, no Dock icon by default).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
