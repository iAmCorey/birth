import Foundation

/// A single startup item, unified across launchd domains and BTM login items.
public struct LaunchItem: Identifiable, Hashable, Sendable {
    /// Where the item lives and which mechanism manages it.
    public enum Domain: String, CaseIterable, Codable, Sendable {
        /// `~/Library/LaunchAgents` — per-user agents, no privileges needed.
        case userAgent
        /// `/Library/LaunchAgents` — agents loaded into every user's session.
        case globalAgent
        /// `/Library/LaunchDaemons` — system daemons, root-owned.
        case globalDaemon
        /// Background Task Management login items (System Settings > Login Items).
        case loginItem
    }

    /// Whether the item is allowed to launch.
    public enum EnablementState: Hashable, Sendable {
        case enabled
        case disabled
        /// BTM items whose state we can read but not change.
        case managedBySystem(enabled: Bool)
        case unknown

        public var isEnabled: Bool? {
            switch self {
            case .enabled: true
            case .disabled: false
            case .managedBySystem(let enabled): enabled
            case .unknown: nil
            }
        }
    }

    public var id: String
    public var label: String
    public var displayName: String
    public var domain: Domain
    public var plistURL: URL?
    public var executablePath: String?
    public var enablement: EnablementState
    /// PID if the job is currently running, nil if not running or unknown.
    public var pid: Int?
    /// True when we positively know the job is loaded but idle (pid == nil).
    public var isLoaded: Bool
    public var runAtLoad: Bool
    public var keepAlive: Bool
    /// Human-readable schedule summary ("Every 3600s", "Calendar schedule"), if any.
    public var schedule: String?
    public var signature: SignatureInfo?
    /// BTM-only: item type description from the BTM database ("app", "login item"...).
    public var btmTypeDescription: String?

    /// The label claims Apple's namespace. A claim, not proof: any plist
    /// author can write a com.apple.* label, so this only stands in for
    /// "Apple" until a signature check confirms or disproves it.
    public var claimsAppleLabel: Bool {
        label.hasPrefix("com.apple.")
    }

    /// The label claims Apple but the verified signature says otherwise —
    /// the classic disguise for malicious launchd persistence. nil
    /// signature means "not verified yet", which is not an accusation.
    public func isMasquerading(signature: SignatureInfo?) -> Bool {
        guard let signature else { return false }
        return claimsAppleLabel && signature.kind != .apple
    }

    /// BTM login items are macOS-managed: Birth can neither toggle nor
    /// remove them, only point at System Settings. Single source for
    /// every "offer removal?" decision in the UI.
    public var isUserRemovable: Bool {
        domain != .loginItem
    }

    public init(
        id: String,
        label: String,
        displayName: String,
        domain: Domain,
        plistURL: URL? = nil,
        executablePath: String? = nil,
        enablement: EnablementState = .unknown,
        pid: Int? = nil,
        isLoaded: Bool = false,
        runAtLoad: Bool = false,
        keepAlive: Bool = false,
        schedule: String? = nil,
        signature: SignatureInfo? = nil,
        btmTypeDescription: String? = nil
    ) {
        self.id = id
        self.label = label
        self.displayName = displayName
        self.domain = domain
        self.plistURL = plistURL
        self.executablePath = executablePath
        self.enablement = enablement
        self.pid = pid
        self.isLoaded = isLoaded
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.schedule = schedule
        self.signature = signature
        self.btmTypeDescription = btmTypeDescription
    }
}

/// Code-signing identity of the item's executable.
public struct SignatureInfo: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case apple            // Chain anchored at Apple's root (Apple's own binaries)
        case appStore         // Apple-generic anchor, App Store leaf
        case developerID      // Apple-generic anchor, third-party developer leaf
        case adhoc            // Signed without an identity
        case untrusted        // Has certificates, but no Apple anchor (e.g. self-signed)
        case unsigned
        case invalid          // Signature exists but fails validation
    }

    public var kind: Kind
    /// e.g. "Docker Inc" from "Developer ID Application: Docker Inc (9BNSXJN65R)"
    public var developerName: String?
    public var teamID: String?

    public init(kind: Kind, developerName: String? = nil, teamID: String? = nil) {
        self.kind = kind
        self.developerName = developerName
        self.teamID = teamID
    }
}
