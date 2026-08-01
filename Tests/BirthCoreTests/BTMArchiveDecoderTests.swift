import Foundation
import Testing
@testable import BirthCore

private let accountID = "89C11FFF-0000-0000-0000-000000000000"

@objc(BirthTestsVariantStorage)
private final class VariantStorage: NSObject, NSCoding {
    let itemsByUserIdentifier: NSDictionary

    init(itemsByUserIdentifier: NSDictionary) {
        self.itemsByUserIdentifier = itemsByUserIdentifier
    }

    required init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {
        coder.encode(itemsByUserIdentifier, forKey: "itemsByUserIdentifier")
    }
}

@objc(BirthTestsVariantRecord)
private final class VariantRecord: NSObject, NSCoding {
    required init?(coder: NSCoder) { nil }

    override init() {}

    func encode(with coder: NSCoder) {
        coder.encode("44444444-4444-4444-4444-444444444444", forKey: "uuid")
        coder.encode("Variant Helper", forKey: "name")
        coder.encode(0x4, forKey: "type")
        coder.encode(0xb, forKey: "disposition")
        coder.encode("4.com.example.variant", forKey: "identifier")
        coder.encode("file:///Applications/Variant%20Helper.app", forKey: "url")
        coder.encode(["8.com.example.agent"], forKey: "items")
        coder.encode(Set(["com.example.variant"]), forKey: "associatedBundleIdentifiers")
    }
}

@objc(BirthTestsVariantUserSettings)
private final class VariantUserSettings: NSObject, NSCoding {
    required init?(coder: NSCoder) { nil }

    override init() {}

    func encode(with coder: NSCoder) {}
}

@objc(BirthTestsVariantUserStorage)
private final class VariantUserStorage: NSObject, NSCoding {
    let records: NSArray
    let userIdentifier: String
    let userSettings = VariantUserSettings()

    init(records: [BTMArchiveRecord], userIdentifier: String) {
        self.records = records as NSArray
        self.userIdentifier = userIdentifier
    }

    required init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {
        coder.encode(records, forKey: "records")
        coder.encode(userIdentifier, forKey: "userIdentifier")
        coder.encode(userSettings, forKey: "userSettings")
    }
}

private func makeArchive(
    records: [BTMArchiveRecord],
    rootKey: String = "store",
    storageClassName: String = "Storage",
    recordClassName: String = "ItemRecord"
) -> Data {
    let storage = BTMArchiveStorage(itemsByUserIdentifier: [accountID: records])
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    archiver.setClassName(storageClassName, for: BTMArchiveStorage.self)
    archiver.setClassName(recordClassName, for: BTMArchiveRecord.self)
    archiver.encode(storage, forKey: rootKey)
    archiver.finishEncoding()
    return archiver.encodedData
}

private func makeNestedArchive(_ nestedData: Data, rootKey: String = "storeData") -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: false)
    archiver.encode(nestedData, forKey: rootKey)
    archiver.finishEncoding()
    return archiver.encodedData
}

private func makeMacOS27Archive(
    records: [BTMArchiveRecord],
    userIdentifier: String = accountID
) -> Data {
    let currentStorage = VariantUserStorage(
        records: records,
        userIdentifier: userIdentifier
    )
    let archiver = NSKeyedArchiver(requiringSecureCoding: false)
    archiver.setClassName("BTMUserStore", for: VariantUserStorage.self)
    archiver.setClassName("BTMUserSettings", for: VariantUserSettings.self)
    archiver.setClassName("ItemRecord", for: BTMArchiveRecord.self)
    archiver.encode(currentStorage, forKey: "store")
    archiver.finishEncoding()
    return archiver.encodedData
}

private func makeVariantArchive() -> Data {
    let record = VariantRecord()
    let storage = VariantStorage(itemsByUserIdentifier: [accountID: [record]])
    let archiver = NSKeyedArchiver(requiringSecureCoding: false)
    archiver.setClassName("Storage", for: VariantStorage.self)
    archiver.setClassName("ItemRecord", for: VariantRecord.self)
    archiver.encode(storage, forKey: "store")
    archiver.finishEncoding()
    return archiver.encodedData
}

private func sampleRecords() -> [BTMArchiveRecord] {
    [
        BTMArchiveRecord(
            uuid: UUID(uuidString: "22222222-2222-2222-2222-222222222222"),
            name: "Example Browser",
            developerName: "Example Corp Inc.",
            teamIdentifier: "TEAM123456",
            type: 0x2,
            disposition: 0xa,
            identifier: "2.com.example.browser",
            url: URL(filePath: "/Applications/Example Browser.app"),
            bundleIdentifier: "com.example.browser"
        ),
        BTMArchiveRecord(
            name: "Example Parent",
            type: 0x20,
            disposition: 0xb,
            identifier: "2.com.example.parent",
            url: URL(filePath: "/Applications/Example Parent.app")
        ),
        BTMArchiveRecord(
            uuid: UUID(uuidString: "33333333-3333-3333-3333-333333333333"),
            name: "HelperLoginItem",
            developerName: "Example Corp Inc.",
            teamIdentifier: "TEAM123456",
            type: 0x4,
            disposition: 0xb,
            identifier: "4.com.example.helper",
            url: URL(string: "Contents/Library/LoginItems/HelperLoginItem.app"),
            bundleIdentifier: "com.example.helper",
            container: "2.com.example.parent"
        ),
        BTMArchiveRecord(
            name: "old-agent",
            type: 0x10008,
            disposition: 0xb,
            identifier: "8.com.example.oldagent",
            executablePath: "/usr/local/bin/old-agent"
        ),
        BTMArchiveRecord(
            name: "Background Refresh",
            type: 0x1000,
            disposition: 0xb,
            identifier: "4096.com.example.refresh",
            url: URL(filePath: "/Applications/Refresh.app"),
            embeddedItems: ["8.com.example.agent", "16.com.example.daemon"]
        ),
    ]
}

@Suite("BTM archive decoding")
struct BTMArchiveDecoderTests {
    @Test func emptyArchiveDecodesAsAnEmptyList() throws {
        let items = try BTMArchiveDecoder.decode(
            makeArchive(records: []),
            accountIdentifier: accountID
        )
        #expect(items.isEmpty)
    }

    @Test func decodesCurrentAccountAndFiltersMetadataRecords() throws {
        let items = try BTMArchiveDecoder.decode(
            makeArchive(records: sampleRecords()),
            accountIdentifier: accountID
        )

        #expect(items.count == 3)
        #expect(items.map(\.typeDescription) == ["app", "login item", "background app refresh"])
        #expect(!items.contains { $0.identifier == "8.com.example.oldagent" })
        #expect(!items.contains { $0.identifier == "2.com.example.parent" })
    }

    @Test func acceptsEquivalentFoundationRepresentationsAcrossOSVersions() throws {
        let item = try #require(BTMArchiveDecoder.decode(
            makeVariantArchive(),
            accountIdentifier: accountID
        ).first)

        #expect(item.uuid == "44444444-4444-4444-4444-444444444444")
        #expect(item.urlString == "file:///Applications/Variant%20Helper.app")
        #expect(item.embeddedItemIdentifiers == ["8.com.example.agent"])
    }

    @Test func discoversRenamedPrivateClassesAndRootKeyFromStructure() throws {
        let data = makeArchive(
            records: sampleRecords(),
            rootKey: "database",
            storageClassName: "BackgroundTasks27.StoreEnvelope",
            recordClassName: "BackgroundTasks27.LoginRecord"
        )
        let items = try BTMArchiveDecoder.decode(data, accountIdentifier: accountID)

        #expect(items.count == 3)
        #expect(items.contains { $0.bundleIdentifier == "com.example.browser" })
    }

    @Test func retriesStructuralDiscoveryWhenOnlyRootKeyChanged() throws {
        let data = makeArchive(records: sampleRecords(), rootKey: "database")
        let items = try BTMArchiveDecoder.decode(data, accountIdentifier: accountID)

        #expect(items.count == 3)
    }

    @Test func retriesStructuralDiscoveryWhenOnlyRecordClassChanged() throws {
        let data = makeArchive(
            records: sampleRecords(),
            recordClassName: "BackgroundTasks27.LoginRecord"
        )
        let items = try BTMArchiveDecoder.decode(data, accountIdentifier: accountID)

        #expect(items.count == 3)
    }

    @Test func decodesMacOS27PerUserStoreLayout() throws {
        let data = makeMacOS27Archive(records: sampleRecords())
        let items = try BTMArchiveDecoder.decode(data, accountIdentifier: accountID)

        #expect(items.count == 3)
        #expect(items.contains { $0.bundleIdentifier == "com.example.browser" })
    }

    @Test func macOS27PerUserStoreRejectsAnotherAccountsRecords() throws {
        let data = makeMacOS27Archive(
            records: sampleRecords(),
            userIdentifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )
        let items = try BTMArchiveDecoder.decode(data, accountIdentifier: accountID)

        #expect(items.isEmpty)
    }

    @Test func unwrapsNestedStoreDataArchive() throws {
        let inner = makeArchive(
            records: sampleRecords(),
            rootKey: "root",
            storageClassName: "FutureStorage",
            recordClassName: "FutureRecord"
        )
        let items = try BTMArchiveDecoder.decode(
            makeNestedArchive(inner),
            accountIdentifier: accountID
        )

        #expect(items.map(\.typeDescription) == [
            "app",
            "login item",
            "background app refresh",
        ])
    }

    @Test func mapsIdentityDispositionAndBundlePath() throws {
        let items = try BTMArchiveDecoder.decode(
            makeArchive(records: sampleRecords()),
            accountIdentifier: accountID.lowercased()
        )
        let app = try #require(items.first { $0.bundleIdentifier == "com.example.browser" })

        #expect(app.name == "Example Browser")
        #expect(app.developerName == "Example Corp Inc.")
        #expect(app.teamIdentifier == "TEAM123456")
        #expect(app.isEnabled == false)
        #expect(app.executablePath == "/Applications/Example Browser.app")
    }

    @Test func resolvesRelativeLoginItemThroughItsParent() throws {
        let items = try BTMArchiveDecoder.decode(
            makeArchive(records: sampleRecords()),
            accountIdentifier: accountID
        )
        let helper = try #require(items.first { $0.typeDescription == "login item" })

        #expect(helper.parentIdentifier == "2.com.example.parent")
        #expect(helper.executablePath == "/Applications/Example Parent.app/Contents/Library/LoginItems/HelperLoginItem.app")
    }

    @Test func preservesEmbeddedIdentifiersDeterministically() throws {
        let items = try BTMArchiveDecoder.decode(
            makeArchive(records: sampleRecords()),
            accountIdentifier: accountID
        )
        let refresh = try #require(items.first { $0.typeDescription == "background app refresh" })
        #expect(refresh.embeddedItemIdentifiers == [
            "16.com.example.daemon",
            "8.com.example.agent",
        ])
    }

    @Test func missingAccountHasNoItemsRatherThanLeakingAnotherUsersRecords() throws {
        let items = try BTMArchiveDecoder.decode(
            makeArchive(records: sampleRecords()),
            accountIdentifier: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )
        #expect(items.isEmpty)
    }

    @Test func rejectsNonKeyedArchivesAsUnsupported() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["kind": "not a keyed archive"],
            format: .binary,
            options: 0
        )
        do {
            _ = try BTMArchiveDecoder.decode(data, accountIdentifier: accountID)
            Issue.record("Expected unsupported-format failure")
        } catch let error as BTMReader.BTMError {
            guard case .unsupportedFormat = error else {
                Issue.record("Expected unsupportedFormat, got \(error)")
                return
            }
        }
    }

    @Test func unsupportedArchivesIncludeSafeStructuralDiagnostics() throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode(["unexpected": "value"], forKey: "futureStore")
        archiver.finishEncoding()

        do {
            _ = try BTMArchiveDecoder.decode(
                archiver.encodedData,
                accountIdentifier: accountID
            )
            Issue.record("Expected unsupported-format failure")
        } catch let error as BTMReader.BTMError {
            guard case .unsupportedFormat(let detail) = error else {
                Issue.record("Expected unsupportedFormat, got \(error)")
                return
            }
            #expect(detail.contains("top=[futureStore]"))
            #expect(detail.contains("classes=["))
            #expect(!detail.contains("value"))
        }
    }

    @Test func bridgesToLaunchItem() throws {
        let items = try BTMArchiveDecoder.decode(
            makeArchive(records: sampleRecords()),
            accountIdentifier: accountID
        )
        let launchItem = LaunchItem(
            btmItem: try #require(items.first { $0.bundleIdentifier == "com.example.browser" })
        )
        #expect(launchItem.domain == .loginItem)
        #expect(launchItem.label == "com.example.browser")
        #expect(launchItem.displayName == "Example Browser")
        #expect(launchItem.enablement == .managedBySystem(enabled: false))
        #expect(launchItem.signature?.teamID == "TEAM123456")
    }
}
