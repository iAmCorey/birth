import Foundation

/// One record from the Background Task Management database
/// (what System Settings > General > Login Items shows).
public struct BTMItem: Hashable, Sendable {
    public var uuid: String
    public var name: String?
    public var developerName: String?
    public var teamIdentifier: String?
    /// "app", "login item", "agent", "legacy agent", "developer", ...
    public var typeDescription: String
    public var isEnabled: Bool?
    public var identifier: String?
    public var urlString: String?
    public var executablePath: String?
    public var bundleIdentifier: String?
    public var parentIdentifier: String?
    public var embeddedItemIdentifiers: [String] = []
}

public struct BTMSection: Sendable {
    public var uid: Int
    public var items: [BTMItem]
}

/// Parses the text output of `sfltool dumpbtm`. The format is not a public
/// contract, so unrecognized lines are skipped rather than treated as errors.
public enum BTMParser {
    /// Item types that represent actual login/background items. The rest are
    /// either duplicates of launchd jobs (legacy agent/daemon), grouping
    /// containers (developer), or plugins (quicklook, spotlight, dock tile).
    public static let modernItemTypes: Set<String> = [
        "app", "login item", "agent", "daemon", "background app refresh",
    ]

    public static func parseSections(_ text: String) -> [BTMSection] {
        var sections: [BTMSection] = []
        var currentUID: Int?
        var currentItems: [BTMItem] = []
        var currentItem: BTMItem?
        var collectingEmbedded = false

        func commitItem() {
            if let item = currentItem { currentItems.append(item) }
            currentItem = nil
            collectingEmbedded = false
        }

        func commitSection() {
            commitItem()
            if let uid = currentUID {
                sections.append(BTMSection(uid: uid, items: currentItems))
            }
            currentItems = []
            currentUID = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("Records for UID ") {
                commitSection()
                // "Records for UID 501 : 89C11FFF-..."
                let remainder = line.dropFirst("Records for UID ".count)
                let uidToken = remainder.split(separator: " ").first ?? ""
                currentUID = Int(uidToken)
                continue
            }

            // A bare "#N:" starts a new item; "#N: value" inside an embedded
            // identifier list is a list entry — distinguish by trailing content.
            if line.hasPrefix("#"), let colon = line.firstIndex(of: ":") {
                let afterColon = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                let numberPart = line[line.index(after: line.startIndex)..<colon]
                if Int(numberPart) != nil {
                    if afterColon.isEmpty {
                        commitItem()
                        currentItem = BTMItem(uuid: "", typeDescription: "unknown")
                        continue
                    } else if collectingEmbedded {
                        currentItem?.embeddedItemIdentifiers.append(String(afterColon))
                        continue
                    }
                }
            }

            guard currentItem != nil else { continue }

            if line == "Embedded Item Identifiers:" {
                collectingEmbedded = true
                continue
            }

            guard let separator = line.range(of: ": ") else { continue }
            collectingEmbedded = false
            let key = line[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = nullable(String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces))

            switch key {
            case "UUID": currentItem?.uuid = value ?? ""
            case "Name": currentItem?.name = value
            case "Developer Name": currentItem?.developerName = value
            case "Team Identifier": currentItem?.teamIdentifier = value
            case "Type": currentItem?.typeDescription = stripTrailingCode(value ?? "unknown")
            case "Disposition": currentItem?.isEnabled = parseDisposition(value)
            case "Identifier": currentItem?.identifier = value
            case "URL": currentItem?.urlString = value
            case "Executable Path": currentItem?.executablePath = value
            case "Bundle Identifier": currentItem?.bundleIdentifier = value
            case "Parent Identifier": currentItem?.parentIdentifier = value
            default: break
            }
        }
        commitSection()
        return sections
    }

    public static func items(in text: String, uid: Int) -> [BTMItem] {
        parseSections(text).first(where: { $0.uid == uid })?.items ?? []
    }

    /// "(null)" and empty strings mean no value.
    private static func nullable(_ value: String) -> String? {
        value.isEmpty || value == "(null)" ? nil : value
    }

    /// "legacy agent (0x10008)" -> "legacy agent"
    private static func stripTrailingCode(_ value: String) -> String {
        guard let parenIndex = value.lastIndex(of: "("),
              value.hasSuffix(")")
        else { return value }
        return String(value[..<parenIndex]).trimmingCharacters(in: .whitespaces)
    }

    /// "[enabled, allowed, notified] (0xb)" -> true
    private static func parseDisposition(_ value: String?) -> Bool? {
        guard let value,
              let open = value.firstIndex(of: "["),
              let close = value.firstIndex(of: "]")
        else { return nil }
        let flags = value[value.index(after: open)..<close]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if flags.contains("enabled") { return true }
        if flags.contains("disabled") { return false }
        return nil
    }
}
