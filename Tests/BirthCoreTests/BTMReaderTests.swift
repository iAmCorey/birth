import Foundation
import Testing
@testable import BirthCore

@Suite("BTM store reader")
struct BTMReaderTests {
    @Test func missingPathIsInconclusiveAndReadableFileIsGranted() throws {
        #expect(BTMReader.probeOpen("/nonexistent-birth-btm-probe/file") == .inconclusive)

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "birth-btm-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "probe.btm")
        try Data("birth".utf8).write(to: file)
        #expect(BTMReader.probeOpen(file.path) == .granted)
    }

    @Test func selectsHighestNumericStoreVersion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "birth-btm-stores-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["BackgroundItems-v7.btm", "BackgroundItems-v10.btm", "notes.txt"] {
            try Data(name.utf8).write(to: directory.appending(path: name))
        }

        let selected = try BTMReader.latestStoreURL(in: directory)
        #expect(selected.lastPathComponent == "BackgroundItems-v10.btm")
    }

    @Test func selectsCurrentUsersVersionedStoreAndIgnoresOtherUsers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "birth-btm-user-stores-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let currentAccount = "89C11FFF-0000-0000-0000-000000000000"
        for name in [
            "BackgroundItems-v16.btm",
            "BackgroundItems-v17-\(currentAccount.lowercased()).btm",
            "BackgroundItems-v99-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.btm",
        ] {
            try Data(name.utf8).write(to: directory.appending(path: name))
        }

        let selected = try BTMReader.latestStoreURL(
            in: directory,
            accountIdentifier: currentAccount
        )
        #expect(
            selected.lastPathComponent
                == "BackgroundItems-v17-\(currentAccount.lowercased()).btm"
        )
    }

    @Test func permissionErrorsAreNotMisreportedAsFormatFailures() {
        let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        #expect(BTMReader.classifyReadError(denied) == .fullDiskAccessRequired)

        let missing = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        guard case .storeUnavailable = BTMReader.classifyReadError(missing) else {
            Issue.record("ENOENT should be a store failure, not an FDA denial")
            return
        }
    }

    @Test func resolvesCurrentAccountGeneratedUIDWithoutPrivileges() throws {
        let identifier = try BTMReader.accountIdentifier(for: Int(getuid()))
        #expect(UUID(uuidString: identifier) != nil)
    }
}
