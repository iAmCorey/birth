import Foundation
import Testing
@testable import BirthCore

@Suite("Login items parsing")
struct LoginItemsTests {
    private let fs = LoginItemsClient.fieldSeparator
    private let rs = LoginItemsClient.recordSeparator

    @Test func parsesRecords() {
        let output = "Paste\(fs)/Applications/Paste.app\(rs)Magnet\(fs)/Applications/Magnet.app\(rs)"
        let apps = LoginItemsClient.parseListOutput(output)
        #expect(apps.count == 2)
        #expect(apps[0] == LoginApp(name: "Paste", path: "/Applications/Paste.app"))
        #expect(apps[1].name == "Magnet")
    }

    @Test func emptyOutputMeansNoItems() {
        #expect(LoginItemsClient.parseListOutput("").isEmpty)
        #expect(LoginItemsClient.parseListOutput("\n").isEmpty)
    }

    @Test func fallsBackToPathComponentWhenNameMissing() {
        let output = "\(fs)/Applications/Some App.app\(rs)"
        let apps = LoginItemsClient.parseListOutput(output)
        #expect(apps.count == 1)
        #expect(apps[0].name == "Some App.app")
    }

    @Test func skipsMalformedRecords() {
        let output = "just-a-name-no-separator\(rs)Good\(fs)/Applications/Good.app\(rs)"
        let apps = LoginItemsClient.parseListOutput(output)
        #expect(apps.count == 1)
        #expect(apps[0].name == "Good")
    }

    @Test func handlesCommasAndUnicodeInNames() {
        let output = "App, With Commas\(fs)/Applications/App, With Commas.app\(rs)闪电说\(fs)/Applications/闪电说.app\(rs)"
        let apps = LoginItemsClient.parseListOutput(output)
        #expect(apps.count == 2)
        #expect(apps[0].name == "App, With Commas")
        #expect(apps[1].name == "闪电说")
    }
}

@Suite("Shared-file-list login items")
struct SharedFileListLoginItemsTests {
    /// Sentinel for the zero-consent read path: if a future macOS finally
    /// removes the deprecated LSSharedFileList API, this fails and list()
    /// silently falls back to System Events — which needs an Automation
    /// grant. That regression should be loud, not discovered by users.
    @Test func sharedFileListReadStillWorks() {
        #expect(LoginItemsClient.listViaSharedFileList() != nil)
    }
}

@Suite("LoginApp persistence")
struct LoginAppPersistenceTests {
    /// The 最近移除 list round-trips through JSON in UserDefaults.
    @Test func codableRoundtrip() throws {
        let apps = [
            LoginApp(name: "计算器", path: "/System/Applications/Calculator.app"),
            LoginApp(name: "Paste", path: "/Applications/Paste.app"),
        ]
        let data = try JSONEncoder().encode(apps)
        let decoded = try JSONDecoder().decode([LoginApp].self, from: data)
        #expect(decoded == apps)
    }
}
