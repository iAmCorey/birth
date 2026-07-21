import Foundation
import Testing
@testable import BirthCore

@Suite("LaunchdPlist parsing")
struct LaunchdPlistTests {
    func plistData(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    @Test func parsesProgramArguments() throws {
        let data = try plistData([
            "Label": "com.example.helper",
            "ProgramArguments": ["/usr/local/bin/helper", "--daemon"],
            "RunAtLoad": true,
        ])
        let plist = try LaunchdPlist.parse(data: data)
        #expect(plist.label == "com.example.helper")
        #expect(plist.executablePath == "/usr/local/bin/helper")
        #expect(plist.runAtLoad)
        #expect(!plist.keepAlive)
        #expect(plist.disabled == nil)
    }

    @Test func programKeyWinsOverProgramArguments() throws {
        let data = try plistData([
            "Label": "com.example.b",
            "Program": "/opt/tool",
            "ProgramArguments": ["/ignored", "-x"],
        ])
        let plist = try LaunchdPlist.parse(data: data)
        #expect(plist.executablePath == "/opt/tool")
    }

    @Test func keepAliveDictionaryCountsAsTrue() throws {
        let data = try plistData([
            "Label": "com.example.c",
            "KeepAlive": ["SuccessfulExit": false],
        ])
        let plist = try LaunchdPlist.parse(data: data)
        #expect(plist.keepAlive)
    }

    @Test func readsDisabledAndSchedule() throws {
        let data = try plistData([
            "Label": "com.example.d",
            "Disabled": true,
            "StartInterval": 3600,
        ])
        let plist = try LaunchdPlist.parse(data: data)
        #expect(plist.disabled == true)
        #expect(plist.scheduleDescription == "every 3600s")
    }

    @Test func calendarIntervalProducesSchedule() throws {
        let data = try plistData([
            "Label": "com.example.e",
            "StartCalendarInterval": ["Hour": 9, "Minute": 30],
        ])
        let plist = try LaunchdPlist.parse(data: data)
        #expect(plist.scheduleDescription == "calendar schedule")
    }

    @Test func rejectsNonDictionaryPlist() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["a", "b"], format: .xml, options: 0)
        #expect(throws: LaunchdPlist.ParseError.self) {
            try LaunchdPlist.parse(data: data)
        }
    }
}
