import Foundation
import Testing
@testable import BirthCore
@testable import BirthUI

/// Policy-layer tests for AppState. Each test gets a scratch UserDefaults
/// suite so nothing touches the user's real preferences.
@MainActor
private struct StateBox {
    let state: AppState
    let defaults: UserDefaults
    private let suite: String

    init() {
        suite = "dev.birth.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        state = AppState(forTesting: defaults)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        // removePersistentDomain empties the domain but can leave the
        // plist shell behind — delete it so test runs don't litter
        // ~/Library/Preferences.
        let plist = NSHomeDirectory() + "/Library/Preferences/\(suite).plist"
        try? FileManager.default.removeItem(atPath: plist)
    }
}

private func makeItem(
    id: String = "t",
    label: String,
    displayName: String? = nil,
    domain: LaunchItem.Domain = .userAgent,
    executablePath: String? = nil
) -> LaunchItem {
    LaunchItem(
        id: id,
        label: label,
        displayName: displayName ?? label,
        domain: domain,
        executablePath: executablePath
    )
}

@MainActor
@Suite("AppState policy")
struct AppStateTests {
    @Test func sidebarSectionStorageRoundtrips() {
        let sections: [AppState.SidebarSection] = [
            .loginApps, .recentlyRemoved, .all,
            .domain(.userAgent), .domain(.globalAgent), .domain(.globalDaemon), .domain(.loginItem),
        ]
        for section in sections {
            #expect(AppState.SidebarSection(storageValue: section.storageValue) == section)
        }
        #expect(AppState.SidebarSection(storageValue: "garbage") == nil)
        #expect(AppState.SidebarSection(storageValue: "domain.garbage") == nil)
    }

    @Test func selectionPersistsAcrossInstances() {
        let box = StateBox()
        defer { box.cleanUp() }
        box.state.selection = .domain(.globalDaemon)
        let revived = AppState(forTesting: box.defaults)
        #expect(revived.selection == .domain(.globalDaemon))
    }

    /// The security property behind the 伪装系统项 fix: a com.apple.* label
    /// hides an item only until a signature verdict exists; a non-Apple
    /// verdict MUST surface the item in the third-party view.
    @Test func appleClaimStopsHidingOnceSignatureDisproves() {
        let box = StateBox()
        defer { box.cleanUp() }
        let fake = makeItem(label: "com.apple.totally.legit", executablePath: "/tmp/fake-bin")
        box.state.items = [fake]
        box.state.selection = .all
        box.state.showAppleItems = false

        // No signature yet: the claim provisionally hides it.
        #expect(box.state.visibleItems.isEmpty)
        #expect(!box.state.isMasquerading(fake))

        // Non-Apple signature arrives: the item must appear, flagged.
        box.state.signatures["/tmp/fake-bin"] = SignatureInfo(kind: .developerID, developerName: "Evil Corp")
        #expect(box.state.visibleItems.count == 1)
        #expect(box.state.isMasquerading(fake))

        // Genuine Apple signature: hidden again, not an accusation.
        box.state.signatures["/tmp/fake-bin"] = SignatureInfo(kind: .apple)
        #expect(box.state.visibleItems.isEmpty)
        #expect(!box.state.isMasquerading(fake))
    }

    @Test func sidebarCountsRespectAppleFilter() {
        let box = StateBox()
        defer { box.cleanUp() }
        box.state.items = [
            makeItem(id: "a", label: "com.vendor.tool", domain: .userAgent),
            makeItem(id: "b", label: "com.apple.service", domain: .globalDaemon),
        ]
        #expect(box.state.count(for: .all) == 1)
        #expect(box.state.count(for: .domain(.userAgent)) == 1)
        #expect(box.state.count(for: .domain(.globalDaemon)) == 0)

        box.state.showAppleItems = true
        #expect(box.state.count(for: .all) == 2)
        #expect(box.state.count(for: .domain(.globalDaemon)) == 1)
    }

    @Test func searchMatchesNameAndDeveloper() {
        let box = StateBox()
        defer { box.cleanUp() }
        let item = makeItem(label: "com.docker.helper", displayName: "Docker Helper", executablePath: "/tmp/docker")
        box.state.items = [item]
        box.state.selection = .all
        box.state.signatures["/tmp/docker"] = SignatureInfo(kind: .developerID, developerName: "Docker Inc")

        box.state.searchText = "docker"
        #expect(box.state.visibleItems.count == 1)
        box.state.searchText = "Docker Inc"
        #expect(box.state.visibleItems.count == 1)
        box.state.searchText = "nonexistent"
        #expect(box.state.visibleItems.isEmpty)
    }

    /// Restorable rows require the app to still exist on disk and to be
    /// absent from the live list.
    @Test func restorableRemovedFiltersDeadAndReaddedApps() {
        let box = StateBox()
        defer { box.cleanUp() }
        let calc = LoginApp(name: "计算器", path: "/System/Applications/Calculator.app")
        let ghost = LoginApp(name: "Ghost", path: "/nonexistent/Ghost.app")

        box.state.recentlyRemovedLoginApps = [calc, ghost]
        #expect(box.state.restorableRemovedLoginApps == [calc])

        // Back in the live list -> no longer restorable.
        box.state.loginApps = [calc]
        box.state.recentlyRemovedLoginApps = [calc, ghost]
        #expect(box.state.restorableRemovedLoginApps.isEmpty)
    }

    @Test func emptyingRecordsSnapsSelectionBack() {
        let box = StateBox()
        defer { box.cleanUp() }
        let calc = LoginApp(name: "计算器", path: "/System/Applications/Calculator.app")
        box.state.recentlyRemovedLoginApps = [calc]
        box.state.selection = .recentlyRemoved

        box.state.clearRemovedLoginAppRecords()
        #expect(box.state.selection == .loginApps)
    }

    @Test func recentlyRemovedRecordPersistsAcrossInstances() throws {
        let box = StateBox()
        defer { box.cleanUp() }
        let calc = LoginApp(name: "计算器", path: "/System/Applications/Calculator.app")
        box.state.recentlyRemovedLoginApps = [calc]

        let revived = AppState(forTesting: box.defaults)
        #expect(revived.recentlyRemovedLoginApps == [calc])
        #expect(revived.restorableRemovedLoginApps == [calc])
    }
}
