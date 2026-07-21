import Foundation
import Testing
@testable import BirthCore

@Suite("Signature summary parsing")
struct SigningTests {
    @Test func extractsDeveloperIDName() {
        #expect(CodeSignInspector.developerName(from: "Developer ID Application: Docker Inc (9BNSXJN65R)") == "Docker Inc")
        #expect(CodeSignInspector.developerName(from: "Apple Development: dev@example.com (ABC123)") == "dev@example.com")
        #expect(CodeSignInspector.developerName(from: "Some Plain Name") == "Some Plain Name")
        #expect(CodeSignInspector.developerName(from: nil) == nil)
    }

    @Test func inspectsRealAppleBinary() {
        // /bin/ls ships with macOS and is always Apple-signed — a stable
        // integration point for the Security-framework path.
        let signature = CodeSignInspector.inspect(path: "/bin/ls")
        #expect(signature?.kind == .apple)
    }

    @Test func missingPathReturnsNil() {
        #expect(CodeSignInspector.inspect(path: "/nonexistent/binary") == nil)
    }
}

@Suite("Snapshot merge logic")
struct MergeTests {
    let service = StartupItemService()

    func makeItem(_ enablement: LaunchItem.EnablementState = .unknown) -> LaunchItem {
        LaunchItem(
            id: "/tmp/test.plist",
            label: "com.example.test",
            displayName: "test",
            domain: .userAgent,
            enablement: enablement
        )
    }

    @Test func overrideBeatsPlistState() {
        let merged = service.merge(
            item: makeItem(.disabled),
            overrides: ["com.example.test": false],
            runtime: [:]
        )
        #expect(merged.enablement == .enabled)
    }

    @Test func plistDisabledHoldsWithoutOverride() {
        let merged = service.merge(item: makeItem(.disabled), overrides: [:], runtime: [:])
        #expect(merged.enablement == .disabled)
    }

    @Test func defaultsToEnabledWhenNothingSaysOtherwise() {
        let merged = service.merge(item: makeItem(.unknown), overrides: [:], runtime: [:])
        #expect(merged.enablement == .enabled)
    }

    @Test func runtimeFillsPIDAndLoadedFlag() {
        let merged = service.merge(
            item: makeItem(),
            overrides: [:],
            runtime: ["com.example.test": JobRuntime(pid: 4242)]
        )
        #expect(merged.isLoaded)
        #expect(merged.pid == 4242)
    }
}

@Suite("Masquerade detection")
struct MasqueradeTests {
    private func item(label: String) -> LaunchItem {
        LaunchItem(id: "t", label: label, displayName: label, domain: .userAgent)
    }

    @Test func appleLabelWithNonAppleSignatureIsMasquerading() {
        let fake = item(label: "com.apple.totally.legit")
        #expect(fake.isMasquerading(signature: SignatureInfo(kind: .unsigned)))
        #expect(fake.isMasquerading(signature: SignatureInfo(kind: .untrusted)))
        #expect(fake.isMasquerading(signature: SignatureInfo(kind: .developerID)))
    }

    @Test func appleLabelWithAppleSignatureIsGenuine() {
        #expect(!item(label: "com.apple.Finder").isMasquerading(signature: SignatureInfo(kind: .apple)))
    }

    @Test func unverifiedSignatureIsNotAnAccusation() {
        #expect(!item(label: "com.apple.pending").isMasquerading(signature: nil))
        #expect(!item(label: "com.vendor.tool").isMasquerading(signature: SignatureInfo(kind: .unsigned)))
    }
}
