import Testing
@testable import BirthCore

/// Synthetic sample mirroring `sfltool dumpbtm` output structure on macOS 26.
private let sampleDump = """
========================
 Records for UID -2 : FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE
========================

 ServiceManagement migrated: true
 LaunchServices registered: false

 Items:

 #1:
                 UUID: 11111111-1111-1111-1111-111111111111
                 Name: (null)
       Developer Name: (null)
                 Type: developer (0x20)
                Flags: [  ] (0)
          Disposition: [disabled, allowed, not notified] (0x2)
           Identifier: Unknown Developer
                  URL: (null)
           Generation: 0
  Embedded Item Identifiers:
    #1: com.apple.example-embedded

========================
 Records for UID 501 : 89C11FFF-0000-0000-0000-000000000000
========================

 ServiceManagement migrated: true
 LaunchServices registered: true

 Items:

 #1:
                 UUID: 22222222-2222-2222-2222-222222222222
                 Name: Example Browser
       Developer Name: Example Corp Inc.
      Team Identifier: TEAM123456
                 Type: app (0x2)
                Flags: [  ] (0)
          Disposition: [disabled, allowed, notified] (0xa)
           Identifier: 2.com.example.browser
                  URL: file:///Applications/Example%20Browser.app/
           Generation: 1
    Bundle Identifier: com.example.browser

 #2:
                 UUID: 33333333-3333-3333-3333-333333333333
                 Name: HelperLoginItem
       Developer Name: Example Corp Inc.
      Team Identifier: TEAM123456
                 Type: login item (0x4)
                Flags: [  ] (0)
          Disposition: [enabled, allowed, notified] (0xb)
           Identifier: 4.com.example.helper
                  URL: Contents/Library/LoginItems/HelperLoginItem.app
           Generation: 1
    Bundle Identifier: com.example.helper
    Parent Identifier: 2.com.example.parent

 #3:
                 UUID: 44444444-4444-4444-4444-444444444444
                 Name: old-agent
       Developer Name: (null)
                 Type: legacy agent (0x10008)
                Flags: [ legacy ] (0x1)
          Disposition: [enabled, allowed, notified] (0xb)
           Identifier: 8.com.example.oldagent
                  URL: file:///Users/someone/Library/LaunchAgents/com.example.oldagent.plist
      Executable Path: /usr/local/bin/old-agent
           Generation: 1
    Parent Identifier: Unknown Developer

 #4:
                 UUID: 55555555-5555-5555-5555-555555555555
                 Name: Example Grouping
       Developer Name: Example Grouping
                 Type: developer (0x20)
                Flags: [ curated ] (0x4)
          Disposition: [enabled, allowed, notified] (0xb)
           Identifier: Example Grouping
                  URL: (null)
           Generation: 3
  Embedded Item Identifiers:
    #1: 16.com.example.grouped.daemon
    #2: 8.com.example.grouped.agent
"""

@Suite("BTM dump parsing")
struct BTMParserTests {
    @Test func splitsSectionsByUID() {
        let sections = BTMParser.parseSections(sampleDump)
        #expect(sections.count == 2)
        #expect(sections[0].uid == -2)
        #expect(sections[1].uid == 501)
        #expect(sections[0].items.count == 1)
        #expect(sections[1].items.count == 4)
    }

    @Test func parsesModernAppRecord() {
        let items = BTMParser.items(in: sampleDump, uid: 501)
        let app = items.first { $0.uuid == "22222222-2222-2222-2222-222222222222" }
        #expect(app?.name == "Example Browser")
        #expect(app?.developerName == "Example Corp Inc.")
        #expect(app?.teamIdentifier == "TEAM123456")
        #expect(app?.typeDescription == "app")
        #expect(app?.isEnabled == false)
        #expect(app?.bundleIdentifier == "com.example.browser")
        #expect(app?.urlString == "file:///Applications/Example%20Browser.app/")
    }

    @Test func parsesLoginItemWithParent() {
        let items = BTMParser.items(in: sampleDump, uid: 501)
        let helper = items.first { $0.typeDescription == "login item" }
        #expect(helper?.isEnabled == true)
        #expect(helper?.parentIdentifier == "2.com.example.parent")
    }

    @Test func nullValuesBecomeNil() {
        let items = BTMParser.items(in: sampleDump, uid: -2)
        let record = items.first
        #expect(record?.name == nil)
        #expect(record?.developerName == nil)
        #expect(record?.urlString == nil)
        #expect(record?.isEnabled == false)
    }

    @Test func embeddedIdentifiersDoNotStartNewItems() {
        let items = BTMParser.items(in: sampleDump, uid: 501)
        let grouping = items.first { $0.name == "Example Grouping" }
        #expect(grouping?.embeddedItemIdentifiers == [
            "16.com.example.grouped.daemon",
            "8.com.example.grouped.agent",
        ])
        // The "#1:"/"#2:" list rows must not have been counted as items.
        #expect(items.count == 4)
    }

    @Test func modernTypeFilterExcludesLegacyAndGrouping() {
        let items = BTMParser.items(in: sampleDump, uid: 501)
            .filter { BTMParser.modernItemTypes.contains($0.typeDescription) }
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.typeDescription == "app" || $0.typeDescription == "login item" })
    }

    @Test func bridgesToLaunchItem() {
        let items = BTMParser.items(in: sampleDump, uid: 501)
        let app = items.first { $0.typeDescription == "app" }!
        let launchItem = LaunchItem(btmItem: app)
        #expect(launchItem.domain == .loginItem)
        #expect(launchItem.label == "com.example.browser")
        #expect(launchItem.displayName == "Example Browser")
        #expect(launchItem.enablement == .managedBySystem(enabled: false))
        #expect(launchItem.signature?.teamID == "TEAM123456")
        #expect(launchItem.executablePath == "/Applications/Example Browser.app")
    }
}
