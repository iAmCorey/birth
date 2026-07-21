import Foundation

/// Single source of truth for product metadata — surfaced by the About
/// panel and the sidebar header. The packaged app reads its version from
/// Info.plist (injected by make-app.sh); the fallback covers `swift run`.
enum BirthInfo {
    static let name = "Birth"
    static let tagline = "一目了然地管理你的电脑启动项"
    static let author = "Corey Chiu"
    static let authorURL = URL(string: "https://coreychiu.com?utm_source=birth")!
    static let copyrightYear = "2026"
    static let repositoryURL = URL(string: "https://github.com/iAmCorey/birth")!

    static var displayVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.1"
    }
}
