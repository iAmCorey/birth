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

    /// What one filesystem probe can testify about Full Disk Access.
    enum ProbeSignal {
        case granted        // open/listing succeeded — FDA is on
        case denied         // EPERM: TCC refused — FDA is off
        case inconclusive   // ENOENT (path moved between OS releases) or
                            // EACCES etc. (plain POSIX, says nothing re TCC)
    }

    /// The store `sfltool dumpbtm` reads; home of BackgroundItems-v*.btm
    /// since macOS 13.
    static let btmStoreDirectory = "/var/db/com.apple.backgroundtaskmanagement"

    /// `sfltool dumpbtm` reads the BTM store directly when this process has
    /// Full Disk Access — but WITHOUT it, the tool falls back to requesting
    /// admin rights via Authorization Services, which surfaces a system
    /// password dialog ("sfltool wants to make changes") on every refresh.
    /// Probe FDA first so we never spawn a prompting sfltool.
    ///
    /// Probe chain, first conclusive signal wins:
    /// 1. Listing the BTM store directory — the very data we're about to
    ///    read, POSIX-open (755 root:wheel) so only TCC can refuse it.
    /// 2./3. Opening the user/system TCC.db — the classic probe, kept for
    ///    macOS ≤ 26. macOS 27 moved the user database into a ProtectedSystem
    ///    container that even FDA can't read (by design, so FDA processes
    ///    can no longer edit privacy grants) — there it reports ENOENT and
    ///    defers to probe 1 instead of false-negating (issue #1).
    ///
    /// An exhausted chain counts as denied: wrongly showing the grant-access
    /// hint costs a click, wrongly spawning sfltool costs a password dialog.
    public static func hasFullDiskAccess() -> Bool {
        let probes: [() -> ProbeSignal] = [
            { probeListing(btmStoreDirectory) },
            { probeOpen(NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db") },
            { probeOpen("/Library/Application Support/com.apple.TCC/TCC.db") },
        ]
        for probe in probes {
            switch probe() {
            case .granted: return true
            case .denied: return false
            case .inconclusive: continue
            }
        }
        return false
    }

    /// TCC refusals are EPERM; a moved path is ENOENT; POSIX-mode refusals
    /// are EACCES. Only the first two testify about FDA, which is why this
    /// inspects errno instead of nil-checking a FileHandle. Must be a real
    /// open — access() would pass on user-owned files regardless of TCC.
    static func probeOpen(_ path: String) -> ProbeSignal {
        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return .granted
        }
        return errno == EPERM ? .denied : .inconclusive
    }

    /// Directory flavor of `probeOpen`. TCC gates the listing itself, so
    /// read one entry ("." at minimum) before calling it granted.
    static func probeListing(_ path: String) -> ProbeSignal {
        guard let dir = opendir(path) else {
            return errno == EPERM ? .denied : .inconclusive
        }
        defer { closedir(dir) }
        errno = 0
        if readdir(dir) != nil { return .granted }
        return errno == EPERM ? .denied : .inconclusive
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
