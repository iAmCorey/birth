import Foundation

/// Reads BTM login items via `sfltool dumpbtm`, which requires
/// Full Disk Access. Failure degrades gracefully — the caller shows
/// the launchd-based lists and a hint about granting access.
public struct BTMReader: Sendable {
    public enum BTMError: Error, LocalizedError {
        case accessDenied(detail: String)

        public var errorDescription: String? {
            switch self {
            case .accessDenied:
                "无法读取登录项数据库。请在系统设置 > 隐私与安全性中授予 Birth“完全磁盘访问权限”。"
            }
        }
    }

    public init() {}

    /// `sfltool dumpbtm` reads the BTM store directly when this process has
    /// Full Disk Access — but WITHOUT it, the tool falls back to requesting
    /// admin rights via Authorization Services, which surfaces a system
    /// password dialog ("sfltool wants to make changes") on every refresh.
    /// Probe FDA first so we never spawn a prompting sfltool: the user-level
    /// TCC database exists on every account and is exactly FDA-gated, so
    /// being able to open it for reading == FDA granted. POSIX permissions
    /// would pass regardless (the user owns the file), which is why this
    /// must be a real open, not an access() check.
    public static func hasFullDiskAccess() -> Bool {
        let probe = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        guard let handle = FileHandle(forReadingAtPath: probe) else { return false }
        try? handle.close()
        return true
    }

    /// Login items for the given user, excluding legacy launchd duplicates,
    /// grouping containers, and plugin records.
    public func loginItems(uid: Int = Int(getuid())) async throws -> [BTMItem] {
        guard Self.hasFullDiskAccess() else {
            throw BTMError.accessDenied(detail: "Full Disk Access not granted")
        }
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run("/usr/bin/sfltool", ["dumpbtm"])
        } catch {
            throw BTMError.accessDenied(detail: String(describing: error))
        }
        guard result.succeeded, !result.stdout.isEmpty else {
            throw BTMError.accessDenied(detail: result.stderr)
        }
        return BTMParser.items(in: result.stdout, uid: uid)
            .filter { BTMParser.modernItemTypes.contains($0.typeDescription) }
    }
}

extension LaunchItem {
    /// Bridge a BTM record into the unified item model.
    public init(btmItem: BTMItem) {
        let name = btmItem.name
            ?? btmItem.bundleIdentifier
            ?? btmItem.identifier
            ?? btmItem.uuid
        let label = btmItem.bundleIdentifier ?? btmItem.identifier ?? name

        var executable = btmItem.executablePath
        if executable == nil,
           let urlString = btmItem.urlString,
           let url = URL(string: urlString), url.isFileURL {
            executable = url.path
        }

        // BTM records carry the developer identity directly; trust it for
        // display instead of re-verifying the binary.
        var signature: SignatureInfo?
        if let team = btmItem.teamIdentifier {
            signature = SignatureInfo(
                kind: .developerID,
                developerName: btmItem.developerName,
                teamID: team
            )
        } else if label.hasPrefix("com.apple.") {
            signature = SignatureInfo(kind: .apple)
        }

        self.init(
            id: "btm:\(btmItem.uuid)",
            label: label,
            displayName: name,
            domain: .loginItem,
            plistURL: nil,
            executablePath: executable,
            enablement: .managedBySystem(enabled: btmItem.isEnabled ?? true),
            signature: signature,
            btmTypeDescription: btmItem.typeDescription
        )
    }
}
