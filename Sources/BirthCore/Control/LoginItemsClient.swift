@preconcurrency import CoreServices
import Foundation

/// An app in the user's "Open at Login" list (System Settings > General >
/// Login Items > Open at Login).
public struct LoginApp: Identifiable, Hashable, Sendable, Codable {
    public var name: String
    public var path: String

    public var id: String { path }

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// Manages the "Open at Login" list. Reading goes through the deprecated
/// LSSharedFileList API — still backed by the live BTM store as of macOS 26
/// and the only zero-consent way to read the list. Mutations go through
/// System Events (the sanctioned path; macOS shows an Automation consent
/// prompt on first use), because SFL's write side is dead — its insert call
/// segfaults. Net effect: browsing needs no permission, changing does.
public struct LoginItemsClient: Sendable {
    public enum LoginItemsError: Error, LocalizedError {
        case automationDenied
        case scriptFailed(String)

        public var errorDescription: String? {
            switch self {
            case .automationDenied:
                "Birth 未获准控制“系统事件”。请在系统设置 > 隐私与安全性 > 自动化中允许 Birth。"
            case .scriptFailed(let detail):
                detail
            }
        }
    }

    /// Separates fields/records in the AppleScript output. Chosen because it
    /// cannot appear in file paths or app names.
    static let fieldSeparator = "\u{1F}"
    static let recordSeparator = "\u{1E}"

    public init() {}

    public func list() async throws -> [LoginApp] {
        // Zero-consent fast path; AppleScript only if the API ever dies.
        if let apps = Self.listViaSharedFileList() {
            return apps
        }
        let script = """
        set out to ""
        tell application "System Events"
            repeat with li in login items
                set out to out & (name of li) & "\(Self.fieldSeparator)" & (path of li) & "\(Self.recordSeparator)"
            end repeat
        end tell
        return out
        """
        let result = try await runAppleScript(script)
        return Self.parseListOutput(result)
    }

    /// Reads the list through LSSharedFileList. Deprecated since 10.11 but
    /// verified on macOS 26 to return exactly what System Events reports —
    /// with no TCC prompt of any kind. Returns nil when the API itself fails
    /// (a future macOS may finally remove it), so callers can fall back to
    /// AppleScript; an empty array is a genuinely empty list.
    static func listViaSharedFileList() -> [LoginApp]? {
        guard let list = LSSharedFileListCreate(
            kCFAllocatorDefault,
            kLSSharedFileListSessionLoginItems.takeUnretainedValue(),
            nil
        )?.takeRetainedValue() else { return nil }
        var seed: UInt32 = 0
        guard let snapshot = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue()
            as? [LSSharedFileListItem] else { return nil }
        // No user interaction / no volume mounting: resolving an item that
        // lives on an unmounted network share must not block or prompt.
        let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
        return snapshot.compactMap { item in
            guard let url = LSSharedFileListItemCopyResolvedURL(item, flags, nil)?
                .takeRetainedValue() as URL? else { return nil }
            let name = LSSharedFileListItemCopyDisplayName(item).takeRetainedValue() as String
            let fallback = url.deletingPathExtension().lastPathComponent
            return LoginApp(name: name.isEmpty ? fallback : name, path: url.path)
        }
    }

    public func add(appURL: URL) async throws {
        let script = """
        tell application "System Events"
            make login item at end with properties {path:"\(PrivilegedRunner.appleScriptQuote(appURL.path))", hidden:false}
        end tell
        """
        _ = try await runAppleScript(script)
    }

    /// Removes by path — names in the list are not guaranteed unique.
    public func remove(appPath: String) async throws {
        let script = """
        tell application "System Events"
            delete (every login item whose path is "\(PrivilegedRunner.appleScriptQuote(appPath))")
        end tell
        """
        _ = try await runAppleScript(script)
    }

    static func parseListOutput(_ text: String) -> [LoginApp] {
        text.split(separator: recordSeparator)
            .compactMap { record in
                let fields = record.split(separator: fieldSeparator, maxSplits: 1, omittingEmptySubsequences: false)
                guard fields.count == 2 else { return nil }
                let name = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let path = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { return nil }
                return LoginApp(name: name.isEmpty ? (path as NSString).lastPathComponent : name, path: path)
            }
    }

    private func runAppleScript(_ script: String) async throws -> String {
        // Long timeout: first use blocks on the Automation consent dialog.
        let result = try await ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 120)
        guard result.succeeded else {
            // -1743: the user declined the Automation consent prompt.
            if result.stderr.contains("-1743") {
                throw LoginItemsError.automationDenied
            }
            throw LoginItemsError.scriptFailed(
                result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.stdout
    }
}
