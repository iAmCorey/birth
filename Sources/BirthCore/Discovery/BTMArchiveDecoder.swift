import Foundation

/// Decodes Apple's NSKeyedArchiver-based Background Task Management store
/// without loading private frameworks or launching `sfltool`.
enum BTMArchiveDecoder {
    static func decode(_ data: Data, accountIdentifier: String) throws -> [BTMItem] {
        try decode(data, accountIdentifier: accountIdentifier, nestingDepth: 0)
    }

    /// Apple's private archive has used both a direct top-level storage object
    /// and Data containing a second keyed archive. Discover both layouts from
    /// structure instead of treating private class and root-key names as API.
    private static func decode(
        _ data: Data,
        accountIdentifier: String,
        nestingDepth: Int
    ) throws -> [BTMItem] {
        var failures: [String] = []

        // Keep the current macOS path cheap: class-table inspection plus one
        // unarchive, matching the original decoder. The normalized structural
        // scan below is reserved for variants that break the conventional
        // Storage/ItemRecord/store contract.
        if let conventional = try? conventionalClasses(in: data) {
            do {
                return try decodeDirect(
                    data,
                    accountIdentifier: accountIdentifier,
                    rootKey: "store",
                    storageClassNames: conventional.storage,
                    recordClassNames: conventional.records
                )
            } catch let error as BTMReader.BTMError {
                failures.append("store: \(error.diagnosticDetail)")
            } catch {
                failures.append("store: \(error.localizedDescription)")
            }
        }

        let layout = try ArchiveLayout(data: data)
        for rootKey in layout.storageRootKeys {
            do {
                return try decodeDirect(
                    data,
                    accountIdentifier: accountIdentifier,
                    rootKey: rootKey,
                    storageClassNames: layout.storageClassNames,
                    recordClassNames: layout.recordClassNames
                )
            } catch let error as BTMReader.BTMError {
                failures.append("\(rootKey): \(error.diagnosticDetail)")
            } catch {
                failures.append("\(rootKey): \(error.localizedDescription)")
            }
        }

        // Bound recursion so a malformed archive cannot create an unbounded
        // chain of nested Data payloads.
        if nestingDepth < 3 {
            for nested in layout.nestedArchives {
                do {
                    return try decode(
                        nested.data,
                        accountIdentifier: accountIdentifier,
                        nestingDepth: nestingDepth + 1
                    )
                } catch let error as BTMReader.BTMError {
                    failures.append("\(nested.key): \(error.diagnosticDetail)")
                } catch {
                    failures.append("\(nested.key): \(error.localizedDescription)")
                }
            }
        }

        let reason = failures.isEmpty
            ? "No compatible storage object"
            : failures.joined(separator: " | ")
        throw BTMReader.BTMError.unsupportedFormat(
            detail: "\(reason); \(layout.diagnosticSummary)"
        )
    }

    private static func decodeDirect(
        _ data: Data,
        accountIdentifier: String,
        rootKey: String,
        storageClassNames: [String],
        recordClassNames: [String]
    ) throws -> [BTMItem] {
        let unarchiver: NSKeyedUnarchiver
        do {
            unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        } catch {
            throw BTMReader.BTMError.unsupportedFormat(
                detail: "Unarchiver initialization: \(error.localizedDescription)"
            )
        }
        // The BTM archive is root-owned and protected by TCC. Apple has
        // changed otherwise equivalent Foundation representations between
        // releases (for example UUID/string and set/array). We still map only
        // the two BTM model classes and decode only fields Birth consumes,
        // but do not make one representation mismatch reject the whole store.
        unarchiver.requiresSecureCoding = false
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        storageClassNames.forEach {
            unarchiver.setClass(BTMArchiveStorage.self, forClassName: $0)
        }
        recordClassNames.forEach {
            unarchiver.setClass(BTMArchiveRecord.self, forClassName: $0)
        }

        guard let storage = unarchiver.decodeObject(forKey: rootKey) as? BTMArchiveStorage else {
            let detail = unarchiver.error?.localizedDescription
                ?? "Root '\(rootKey)' is not a compatible storage object"
            unarchiver.finishDecoding()
            throw BTMReader.BTMError.unsupportedFormat(detail: "Storage decoding: \(detail)")
        }
        unarchiver.finishDecoding()
        if let error = unarchiver.error {
            throw BTMReader.BTMError.unsupportedFormat(
                detail: "Archive completion: \(error.localizedDescription)"
            )
        }

        return makeItems(from: storage.records(for: accountIdentifier))
    }

    private static func conventionalClasses(
        in data: Data
    ) throws -> (storage: [String], records: [String])? {
        let root = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let archive = root as? [String: Any],
              archive["$archiver"] as? String == "NSKeyedArchiver",
              let objects = archive["$objects"] as? [Any]
        else { return nil }
        let classNames = objects.compactMap { object in
            (object as? [String: Any])?["$classname"] as? String
        }
        let storage = classNames.filter { classBaseName($0) == "Storage" }
        guard !storage.isEmpty else { return nil }
        let records = classNames.filter {
            let name = classBaseName($0)
            return name == "ItemRecord" || name == "BTMItem"
        }
        return (storage, records)
    }

    private static func classBaseName(_ name: String) -> String {
        name.split(separator: ".").last.map(String.init) ?? name
    }

    /// Structural description of a keyed archive. UID objects are a private
    /// CoreFoundation type when PropertyListSerialization reads binary data.
    /// Serializing to XML makes them explicit `CF$UID` dictionaries; rename
    /// that marker before parsing the XML back so Foundation does not turn
    /// them opaque again.
    private struct ArchiveLayout {
        let storageRootKeys: [String]
        let storageClassNames: [String]
        let recordClassNames: [String]
        let nestedArchives: [(key: String, data: Data)]
        let diagnosticSummary: String

        init(data: Data) throws {
            let archive = try Self.normalizedArchive(from: data)
            guard archive["$archiver"] as? String == "NSKeyedArchiver",
                  let objects = archive["$objects"] as? [Any],
                  let top = archive["$top"] as? [String: Any]
            else {
                throw BTMReader.BTMError.unsupportedFormat(
                    detail: "Not an NSKeyedArchiver store"
                )
            }

            let storageIndices = Set(objects.indices.filter { index in
                guard let object = objects[index] as? [String: Any] else { return false }
                return BTMArchiveStorage.groupedItemKeys.contains { object[$0] != nil }
                    || (object["records"] != nil && object["userIdentifier"] != nil)
            })
            let recordIndices = objects.indices.filter { index in
                guard let object = objects[index] as? [String: Any],
                      object["type"] != nil,
                      object["disposition"] != nil
                else { return false }
                return object["identifier"] != nil
                    || object["uuid"] != nil
                    || object["name"] != nil
            }

            storageClassNames = Set(storageIndices.compactMap {
                Self.className(forObjectAt: $0, objects: objects)
            }).sorted()
            recordClassNames = Set(recordIndices.compactMap {
                Self.className(forObjectAt: $0, objects: objects)
            }).sorted()

            storageRootKeys = top.compactMap { key, value in
                guard let index = Self.uidIndex(value),
                      storageIndices.contains(index)
                else { return nil }
                return key
            }.sorted { lhs, rhs in
                if lhs == "store" { return true }
                if rhs == "store" { return false }
                return lhs < rhs
            }

            nestedArchives = top.compactMap { key, value in
                guard let index = Self.uidIndex(value),
                      objects.indices.contains(index),
                      let nestedData = objects[index] as? Data
                else { return nil }
                return (key, nestedData)
            }.sorted { $0.key < $1.key }

            let classNames = objects.compactMap { object in
                (object as? [String: Any])?["$classname"] as? String
            }
            let classSummary = classNames.sorted().prefix(16).joined(separator: ",")
            let topSummary = top.keys.sorted().joined(separator: ",")
            diagnosticSummary = "top=[\(topSummary)] classes=[\(classSummary)] objects=\(objects.count)"
        }

        private static func normalizedArchive(from data: Data) throws -> [String: Any] {
            let root: Any
            do {
                root = try PropertyListSerialization.propertyList(from: data, format: nil)
            } catch {
                throw BTMReader.BTMError.unsupportedFormat(
                    detail: "Property-list inspection: \(error.localizedDescription)"
                )
            }
            guard let rawArchive = root as? [String: Any],
                  rawArchive["$archiver"] as? String == "NSKeyedArchiver"
            else {
                throw BTMReader.BTMError.unsupportedFormat(
                    detail: "Not an NSKeyedArchiver store"
                )
            }

            do {
                let xml = try PropertyListSerialization.data(
                    fromPropertyList: rawArchive,
                    format: .xml,
                    options: 0
                )
                let normalizedXML = String(decoding: xml, as: UTF8.self)
                    .replacingOccurrences(
                        of: "<key>CF$UID</key>",
                        with: "<key>BirthArchiveUID</key>"
                    )
                guard let normalized = try PropertyListSerialization.propertyList(
                    from: Data(normalizedXML.utf8),
                    format: nil
                ) as? [String: Any] else {
                    throw BTMReader.BTMError.unsupportedFormat(
                        detail: "Normalized archive root is not a dictionary"
                    )
                }
                return normalized
            } catch let error as BTMReader.BTMError {
                throw error
            } catch {
                throw BTMReader.BTMError.unsupportedFormat(
                    detail: "Archive normalization: \(error.localizedDescription)"
                )
            }
        }

        private static func uidIndex(_ value: Any) -> Int? {
            guard let uid = value as? [String: Any],
                  let number = uid["BirthArchiveUID"] as? NSNumber
            else { return nil }
            return number.intValue
        }

        private static func className(forObjectAt index: Int, objects: [Any]) -> String? {
            guard objects.indices.contains(index),
                  let object = objects[index] as? [String: Any],
                  let classIndex = uidIndex(object["$class"] as Any),
                  objects.indices.contains(classIndex),
                  let descriptor = objects[classIndex] as? [String: Any]
            else { return nil }
            return descriptor["$classname"] as? String
        }
    }

    private static func makeItems(from records: [BTMArchiveRecord]) -> [BTMItem] {
        let parents = Dictionary(
            records.compactMap { record in
                record.identifier.map { ($0, record) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        return records.compactMap { record in
            guard let kind = modernKind(for: record.type) else { return nil }
            let fallbackID = record.identifier
                ?? record.bundleIdentifier
                ?? record.url?.absoluteString
                ?? "type-\(record.type)"
            return BTMItem(
                uuid: record.uuid?.uuidString ?? fallbackID,
                name: record.name,
                developerName: record.developerName,
                teamIdentifier: record.teamIdentifier,
                typeDescription: kind.description,
                isEnabled: record.disposition & 0x1 != 0,
                identifier: record.identifier,
                urlString: record.url?.absoluteString,
                executablePath: executablePath(
                    for: record,
                    kind: kind,
                    parent: record.container.flatMap { parents[$0] }
                ),
                bundleIdentifier: record.bundleIdentifier,
                parentIdentifier: record.container,
                embeddedItemIdentifiers: record.embeddedItems.sorted()
            )
        }
    }

    private enum ModernKind {
        case app
        case loginItem
        case agent
        case daemon
        case backgroundAppRefresh

        var description: String {
            switch self {
            case .app: "app"
            case .loginItem: "login item"
            case .agent: "agent"
            case .daemon: "daemon"
            case .backgroundAppRefresh: "background app refresh"
            }
        }
    }

    private static func modernKind(for rawType: Int) -> ModernKind? {
        // Legacy launchd records duplicate Birth's plist scan and grouping
        // records are metadata, not runnable items.
        guard rawType & 0x10000 == 0 else { return nil }
        if rawType & 0x2 != 0 { return .app }
        if rawType & 0x4 != 0 { return .loginItem }
        if rawType & 0x8 != 0 { return .agent }
        if rawType & 0x10 != 0 { return .daemon }
        if rawType & 0x1000 != 0 { return .backgroundAppRefresh }
        return nil
    }

    private static func executablePath(
        for record: BTMArchiveRecord,
        kind: ModernKind,
        parent: BTMArchiveRecord?
    ) -> String? {
        if let executablePath = record.executablePath, !executablePath.isEmpty {
            return executablePath
        }
        guard let url = record.url else { return nil }

        switch kind {
        case .app, .backgroundAppRefresh:
            return bundleExecutableOrPath(url)
        case .loginItem:
            if url.isFileURL { return bundleExecutableOrPath(url) }
            guard let parentURL = parent?.url, parentURL.isFileURL else { return nil }
            let childURL = parentURL.appending(path: url.relativeString)
            return bundleExecutableOrPath(childURL)
        case .agent, .daemon:
            return nil
        }
    }

    private static func bundleExecutableOrPath(_ url: URL) -> String? {
        guard url.isFileURL else { return nil }
        return Bundle(url: url)?.executableURL?.path ?? url.path
    }
}

/// Local stand-ins for the two private model classes named in the archive.
/// Decoding never loads Apple's private daemon executable.
final class BTMArchiveStorage: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    static let groupedItemKeys = ["itemsByUserIdentifier", "itemsByUserID"]

    let itemsByUserIdentifier: NSDictionary?
    let directRecords: [BTMArchiveRecord]?
    let userIdentifier: String?

    init(itemsByUserIdentifier: [String: [BTMArchiveRecord]]) {
        self.itemsByUserIdentifier = itemsByUserIdentifier as NSDictionary
        directRecords = nil
        userIdentifier = nil
    }

    required init?(coder: NSCoder) {
        var decodedItems: NSDictionary?
        for key in Self.groupedItemKeys where coder.containsValue(forKey: key) {
            if let items = coder.decodeObject(forKey: key) as? NSDictionary {
                decodedItems = items
                break
            }
        }

        if let decodedItems {
            itemsByUserIdentifier = decodedItems
            directRecords = nil
            userIdentifier = nil
            return
        }

        guard coder.containsValue(forKey: "records"),
              let records = coder.decodeObject(forKey: "records") as? NSArray,
              let identifier = Self.identifierString(
                  coder.decodeObject(forKey: "userIdentifier")
              )
        else { return nil }
        itemsByUserIdentifier = nil
        directRecords = records.compactMap { $0 as? BTMArchiveRecord }
        userIdentifier = identifier
    }

    func encode(with coder: NSCoder) {
        if let itemsByUserIdentifier {
            coder.encode(itemsByUserIdentifier, forKey: "itemsByUserIdentifier")
        } else {
            coder.encode(directRecords, forKey: "records")
            coder.encode(userIdentifier, forKey: "userIdentifier")
        }
    }

    func records(for accountIdentifier: String) -> [BTMArchiveRecord] {
        if let itemsByUserIdentifier {
            for (rawKey, rawValue) in itemsByUserIdentifier {
                guard Self.identifierString(rawKey)?
                    .caseInsensitiveCompare(accountIdentifier) == .orderedSame
                else { continue }
                if let records = rawValue as? [BTMArchiveRecord] {
                    return records
                }
                if let records = rawValue as? NSArray {
                    return records.compactMap { $0 as? BTMArchiveRecord }
                }
                return []
            }
            return []
        }

        guard userIdentifier?.caseInsensitiveCompare(accountIdentifier) == .orderedSame else {
            return []
        }
        return directRecords ?? []
    }

    private static func identifierString(_ rawValue: Any?) -> String? {
        switch rawValue {
        case let value as String:
            value
        case let value as UUID:
            value.uuidString
        case let value as NSUUID:
            value.uuidString
        default:
            nil
        }
    }
}

final class BTMArchiveRecord: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let uuid: UUID?
    let name: String?
    let developerName: String?
    let teamIdentifier: String?
    let type: Int
    let disposition: Int
    let identifier: String?
    let url: URL?
    let executablePath: String?
    let bundleIdentifier: String?
    let container: String?
    let embeddedItems: Set<String>
    let associatedBundleIdentifiers: [String]

    init(
        uuid: UUID? = nil,
        name: String? = nil,
        developerName: String? = nil,
        teamIdentifier: String? = nil,
        type: Int,
        disposition: Int,
        identifier: String? = nil,
        url: URL? = nil,
        executablePath: String? = nil,
        bundleIdentifier: String? = nil,
        container: String? = nil,
        embeddedItems: Set<String> = [],
        associatedBundleIdentifiers: [String] = []
    ) {
        self.uuid = uuid
        self.name = name
        self.developerName = developerName
        self.teamIdentifier = teamIdentifier
        self.type = type
        self.disposition = disposition
        self.identifier = identifier
        self.url = url
        self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier
        self.container = container
        self.embeddedItems = embeddedItems
        self.associatedBundleIdentifiers = associatedBundleIdentifiers
    }

    required init?(coder: NSCoder) {
        let archivedUUID = coder.decodeObject(forKey: "uuid")
        if let value = archivedUUID as? UUID {
            uuid = value
        } else if let value = archivedUUID as? String {
            uuid = UUID(uuidString: value)
        } else {
            uuid = nil
        }
        name = coder.decodeObject(forKey: "name") as? String
        developerName = coder.decodeObject(forKey: "developerName") as? String
        teamIdentifier = coder.decodeObject(forKey: "teamIdentifier") as? String
        type = coder.decodeInteger(forKey: "type")
        disposition = coder.decodeInteger(forKey: "disposition")
        identifier = coder.decodeObject(forKey: "identifier") as? String
        let archivedURL = coder.decodeObject(forKey: "url")
        if let value = archivedURL as? URL {
            url = value
        } else if let value = archivedURL as? String {
            url = URL(string: value)
        } else {
            url = nil
        }
        executablePath = coder.decodeObject(forKey: "executablePath") as? String
        bundleIdentifier = coder.decodeObject(forKey: "bundleIdentifier") as? String
        container = coder.decodeObject(forKey: "container") as? String
        let embeddedItemsKey = coder.containsValue(forKey: "items")
            ? "items"
            : "embeddedItems"
        let archivedItems = coder.decodeObject(forKey: embeddedItemsKey)
        if let values = archivedItems as? Set<String> {
            embeddedItems = values
        } else if let values = archivedItems as? [String] {
            embeddedItems = Set(values)
        } else {
            embeddedItems = []
        }
        let archivedBundleIdentifiers = coder.decodeObject(
            forKey: "associatedBundleIdentifiers"
        )
        if let values = archivedBundleIdentifiers as? [String] {
            associatedBundleIdentifiers = values
        } else if let values = archivedBundleIdentifiers as? Set<String> {
            associatedBundleIdentifiers = values.sorted()
        } else {
            associatedBundleIdentifiers = []
        }
    }

    func encode(with coder: NSCoder) {
        coder.encode(uuid, forKey: "uuid")
        coder.encode(name, forKey: "name")
        coder.encode(developerName, forKey: "developerName")
        coder.encode(teamIdentifier, forKey: "teamIdentifier")
        coder.encode(type, forKey: "type")
        coder.encode(disposition, forKey: "disposition")
        coder.encode(identifier, forKey: "identifier")
        coder.encode(url, forKey: "url")
        coder.encode(executablePath, forKey: "executablePath")
        coder.encode(bundleIdentifier, forKey: "bundleIdentifier")
        coder.encode(container, forKey: "container")
        coder.encode(embeddedItems as NSSet, forKey: "items")
        coder.encode(associatedBundleIdentifiers, forKey: "associatedBundleIdentifiers")
    }
}
