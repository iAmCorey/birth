import Foundation
import Testing
@testable import BirthCore

@Suite("Full Disk Access probe")
struct FDAProbeTests {
    /// A path that exists nowhere must yield no verdict — this is exactly
    /// the macOS 27 situation where the old probe read a relocated TCC.db
    /// as "denied" and blocked login items behind a phantom grant (issue #1).
    @Test func missingPathIsInconclusive() {
        let ghost = "/nonexistent-birth-fda-probe/definitely-not-here"
        #expect(BTMReader.probeOpen(ghost) == .inconclusive)
        #expect(BTMReader.probeListing(ghost) == .inconclusive)
    }

    /// Plain readable targets report granted.
    @Test func readableTargetsReportGranted() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("birth-fda-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("probe.txt")
        try Data("birth".utf8).write(to: file)

        #expect(BTMReader.probeOpen(file.path) == .granted)
        #expect(BTMReader.probeListing(dir.path) == .granted)
    }

    /// Sentinel, in the spirit of `sharedFileListReadStillWorks`: the BTM
    /// store directory the chain anchors on has lived at this path since
    /// macOS 13 and must give a real verdict — granted or denied — on any
    /// supported system. `.inconclusive` means the OS moved or re-moded it,
    /// and the probe chain needs a new anchor before users notice.
    @Test func btmStoreDirectoryStillAnswers() {
        #expect(BTMReader.probeListing(BTMReader.btmStoreDirectory) != .inconclusive)
    }
}
