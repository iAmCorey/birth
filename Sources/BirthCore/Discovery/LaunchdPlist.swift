import Foundation

/// The launchd job definition fields Birth cares about, parsed from a job plist.
public struct LaunchdPlist: Hashable, Sendable {
    public var label: String?
    public var program: String?
    public var programArguments: [String]?
    public var disabled: Bool?
    public var runAtLoad: Bool
    public var keepAlive: Bool
    public var startInterval: Int?
    public var hasCalendarInterval: Bool

    public var executablePath: String? {
        program ?? programArguments?.first
    }

    public var scheduleDescription: String? {
        if let startInterval {
            return "every \(startInterval)s"
        }
        if hasCalendarInterval {
            return "calendar schedule"
        }
        return nil
    }

    public enum ParseError: Error {
        case notADictionary
    }

    public static func parse(data: Data) throws -> LaunchdPlist {
        let raw = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = raw as? [String: Any] else {
            throw ParseError.notADictionary
        }

        // KeepAlive may be a Bool or a dictionary of conditions; a dictionary
        // means "keep alive under these conditions" which we surface as true.
        let keepAlive: Bool
        switch dict["KeepAlive"] {
        case let flag as Bool: keepAlive = flag
        case is [String: Any]: keepAlive = true
        default: keepAlive = false
        }

        return LaunchdPlist(
            label: dict["Label"] as? String,
            program: dict["Program"] as? String,
            programArguments: dict["ProgramArguments"] as? [String],
            disabled: dict["Disabled"] as? Bool,
            runAtLoad: dict["RunAtLoad"] as? Bool ?? false,
            keepAlive: keepAlive,
            startInterval: dict["StartInterval"] as? Int,
            hasCalendarInterval: dict["StartCalendarInterval"] != nil
        )
    }
}
