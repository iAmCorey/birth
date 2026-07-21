import Foundation

/// Scans the launchd job directories and produces bare `LaunchItem`s.
/// Enablement/runtime state is filled in later by `LaunchctlClient`.
public struct LaunchdScanner: Sendable {
    public var fileManager: FileManager { .default }

    public init() {}

    public static func directoryURL(for domain: LaunchItem.Domain) -> URL? {
        switch domain {
        case .userAgent:
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        case .globalAgent:
            URL(filePath: "/Library/LaunchAgents", directoryHint: .isDirectory)
        case .globalDaemon:
            URL(filePath: "/Library/LaunchDaemons", directoryHint: .isDirectory)
        case .loginItem:
            nil
        }
    }

    /// Scan one launchd directory. Unreadable or malformed plists still yield
    /// an item (with whatever we know) so nothing silently disappears.
    public func scan(domain: LaunchItem.Domain) -> [LaunchItem] {
        guard let dir = Self.directoryURL(for: domain) else { return [] }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries
            .filter { $0.pathExtension.lowercased() == "plist" }
            .map { url in item(for: url, domain: domain) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func item(for url: URL, domain: LaunchItem.Domain) -> LaunchItem {
        let fallbackLabel = url.deletingPathExtension().lastPathComponent
        let parsed = (try? Data(contentsOf: url)).flatMap { try? LaunchdPlist.parse(data: $0) }
        let label = parsed?.label ?? fallbackLabel

        return LaunchItem(
            id: url.path,
            label: label,
            displayName: fallbackLabel,
            domain: domain,
            plistURL: url,
            executablePath: parsed?.executablePath,
            // plist Disabled key is the legacy baseline; launchctl overrides win later.
            enablement: (parsed?.disabled ?? false) ? .disabled : .unknown,
            runAtLoad: parsed?.runAtLoad ?? false,
            keepAlive: parsed?.keepAlive ?? false,
            schedule: parsed?.scheduleDescription
        )
    }
}
