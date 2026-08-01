import Foundation
import OpenDirectory
import OSLog

/// Reads the Background Task Management store directly. The caller needs
/// Full Disk Access, but no subprocess or administrator prompt is involved.
public struct BTMReader: Sendable {
    public enum BTMError: Error, LocalizedError, Sendable, Equatable {
        case fullDiskAccessRequired
        case storeUnavailable(detail: String)
        case unsupportedFormat(detail: String)
        case accountUnavailable(detail: String)

        public var errorDescription: String? {
            switch self {
            case .fullDiskAccessRequired:
                L("error.fdaNeeded")
            case .storeUnavailable:
                L("error.btmUnavailable")
            case .unsupportedFormat:
                L("error.btmUnsupported")
            case .accountUnavailable:
                L("error.btmAccount")
            }
        }

        public var requiresFullDiskAccess: Bool {
            self == .fullDiskAccessRequired
        }

        public var diagnosticDetail: String {
            switch self {
            case .fullDiskAccessRequired:
                "Full Disk Access is required"
            case .storeUnavailable(let detail),
                 .unsupportedFormat(let detail),
                 .accountUnavailable(let detail):
                detail
            }
        }
    }

    enum ProbeSignal: Equatable {
        case granted
        case denied
        case inconclusive
    }

    static let btmStoreDirectory = "/var/db/com.apple.backgroundtaskmanagement"
    private static let storePrefix = "BackgroundItems-v"
    private static let storeSuffix = ".btm"
    private static let logger = Logger(subsystem: "dev.birth.Birth", category: "BTM")

    public init() {}

    /// Capability probe for the exact resource Birth consumes. It does not
    /// infer FDA from TCC databases or directory permissions that can move or
    /// change semantics between macOS releases.
    public static func hasFullDiskAccess() -> Bool {
        guard let accountIdentifier = try? accountIdentifier(for: Int(getuid())),
              let storeURL = try? latestStoreURL(accountIdentifier: accountIdentifier)
        else { return false }
        return probeOpen(storeURL.path) == .granted
    }

    /// Login items for the current account, excluding legacy launchd
    /// duplicates and grouping/plugin records.
    public func loginItems(uid: Int = Int(getuid())) async throws -> [BTMItem] {
        do {
            return try await Task.detached(priority: .userInitiated) {
                let accountIdentifier = try Self.accountIdentifier(for: uid)
                let storeURL = try Self.latestStoreURL(
                    accountIdentifier: accountIdentifier
                )
                let data = try Self.readStore(at: storeURL)
                return try BTMArchiveDecoder.decode(data, accountIdentifier: accountIdentifier)
            }.value
        } catch let error as BTMError {
            Self.logger.error("BTM read failed: \(error.diagnosticDetail, privacy: .public)")
            throw error
        } catch {
            Self.logger.error("BTM read failed: \(error.localizedDescription, privacy: .public)")
            throw BTMError.storeUnavailable(detail: error.localizedDescription)
        }
    }

    static func latestStoreURL(
        in directory: URL = URL(filePath: btmStoreDirectory, directoryHint: .isDirectory),
        accountIdentifier: String? = nil
    ) throws -> URL {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw classifyReadError(error)
        }

        let candidates = urls.compactMap {
            url -> (url: URL, version: Int, userIdentifier: String?, modified: Date)? in
            let name = url.lastPathComponent
            guard name.hasPrefix(storePrefix), name.hasSuffix(storeSuffix) else { return nil }
            let versionStart = name.index(name.startIndex, offsetBy: storePrefix.count)
            let versionEnd = name.index(name.endIndex, offsetBy: -storeSuffix.count)
            guard versionStart < versionEnd else { return nil }
            let identity = name[versionStart..<versionEnd].split(
                separator: "-",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard let rawVersion = identity.first,
                  let version = Int(rawVersion),
                  identity.count < 2 || !identity[1].isEmpty
            else { return nil }
            let userIdentifier = identity.count == 2 ? String(identity[1]) : nil
            if let accountIdentifier,
               let userIdentifier,
               userIdentifier.caseInsensitiveCompare(accountIdentifier) != .orderedSame {
                return nil
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile != false else { return nil }
            return (
                url,
                version,
                userIdentifier,
                values?.contentModificationDate ?? .distantPast
            )
        }
        guard let newest = candidates.max(by: { lhs, rhs in
            if lhs.version != rhs.version { return lhs.version < rhs.version }
            let lhsSpecific = lhs.userIdentifier != nil
            let rhsSpecific = rhs.userIdentifier != nil
            if lhsSpecific != rhsSpecific { return !lhsSpecific && rhsSpecific }
            return lhs.modified < rhs.modified
        }) else {
            throw BTMError.storeUnavailable(
                detail: "No BackgroundItems-v*.btm store found for the current account"
            )
        }
        return newest.url
    }

    static func readStore(at url: URL) throws -> Data {
        do {
            // The daemon replaces this archive while updating it. Keep an
            // owned snapshot: memory-mapped Data can otherwise observe a
            // truncated/replaced file halfway through decoding.
            return try Data(contentsOf: url)
        } catch {
            throw classifyReadError(error)
        }
    }

    static func probeOpen(_ path: String) -> ProbeSignal {
        let descriptor = open(path, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return .granted
        }
        if errno == EPERM || errno == EACCES { return .denied }
        return .inconclusive
    }

    static func classifyReadError(_ error: Error) -> BTMError {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
            return .fullDiskAccessRequired
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileReadNoPermission.rawValue {
            return .fullDiskAccessRequired
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           case .fullDiskAccessRequired = classifyReadError(underlying) {
            return .fullDiskAccessRequired
        }
        return .storeUnavailable(detail: nsError.localizedDescription)
    }

    /// The BTM store groups records by the account's GeneratedUID rather
    /// than numeric POSIX UID. OpenDirectory is public and performs this
    /// lookup without extra privileges or external commands.
    static func accountIdentifier(for uid: Int) throws -> String {
        do {
            let node = try ODNode(
                session: .default(),
                type: ODNodeType(kODNodeTypeLocalNodes)
            )
            let query = try ODQuery(
                node: node,
                forRecordTypes: kODRecordTypeUsers,
                attribute: kODAttributeTypeUniqueID,
                matchType: ODMatchType(kODMatchEqualTo),
                queryValues: String(uid),
                returnAttributes: kODAttributeTypeGUID,
                maximumResults: 1
            )
            let records = try query.resultsAllowingPartial(false) as? [ODRecord] ?? []
            let values = try records.first?.values(forAttribute: kODAttributeTypeGUID) as? [String]
            guard let identifier = values?.first, !identifier.isEmpty else {
                throw BTMError.accountUnavailable(detail: "No GeneratedUID for POSIX UID \(uid)")
            }
            return identifier
        } catch let error as BTMError {
            throw error
        } catch {
            throw BTMError.accountUnavailable(detail: error.localizedDescription)
        }
    }
}
