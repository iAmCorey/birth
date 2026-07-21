import Foundation

/// Runtime state of a loaded launchd job.
public struct JobRuntime: Hashable, Sendable {
    /// nil means loaded but not currently running.
    public var pid: Int?

    public init(pid: Int? = nil) {
        self.pid = pid
    }
}

/// Wraps `launchctl` queries and actions. Parsing lives in pure static
/// functions so it can be tested against captured output.
public struct LaunchctlClient: Sendable {
    public var uid: uid_t

    public init(uid: uid_t = getuid()) {
        self.uid = uid
    }

    public func domainTarget(for domain: LaunchItem.Domain) -> String? {
        switch domain {
        // Global agents load into each user's GUI session, so their
        // enable/disable overrides live in the gui domain too.
        case .userAgent, .globalAgent: "gui/\(uid)"
        case .globalDaemon: "system"
        case .loginItem: nil
        }
    }

    // MARK: - Queries

    /// Explicit enable/disable overrides recorded for a domain.
    /// Services not listed here follow their plist's `Disabled` key (default enabled).
    public func disabledOverrides(domainTarget: String) async -> [String: Bool] {
        guard let result = try? await ProcessRunner.run("/bin/launchctl", ["print-disabled", domainTarget]),
              result.succeeded
        else { return [:] }
        return Self.parsePrintDisabled(result.stdout)
    }

    /// Jobs loaded in the current user's session (user + global agents).
    public func guiSessionRuntime() async -> [String: JobRuntime] {
        guard let result = try? await ProcessRunner.run("/bin/launchctl", ["list"]),
              result.succeeded
        else { return [:] }
        return Self.parseList(result.stdout)
    }

    /// Jobs loaded in the system domain (daemons). Readable without root.
    public func systemRuntime() async -> [String: JobRuntime] {
        guard let result = try? await ProcessRunner.run("/bin/launchctl", ["print", "system"]),
              result.succeeded
        else { return [:] }
        return Self.parsePrintServices(result.stdout)
    }

    // MARK: - Actions (unprivileged, gui domain)

    /// Persistently disable and immediately stop a job in the user's session.
    public func disableInGUISession(label: String) async throws {
        let target = "gui/\(uid)"
        let disable = try await ProcessRunner.run("/bin/launchctl", ["disable", "\(target)/\(label)"])
        guard disable.succeeded else {
            throw LaunchctlError.commandFailed(command: "disable", detail: disable.stderr)
        }
        // bootout fails when the job isn't loaded — that's fine, the goal is "not running".
        _ = try? await ProcessRunner.run("/bin/launchctl", ["bootout", "\(target)/\(label)"])
    }

    /// Persistently enable and immediately load a job in the user's session.
    public func enableInGUISession(label: String, plistURL: URL?) async throws {
        let target = "gui/\(uid)"
        let enable = try await ProcessRunner.run("/bin/launchctl", ["enable", "\(target)/\(label)"])
        guard enable.succeeded else {
            throw LaunchctlError.commandFailed(command: "enable", detail: enable.stderr)
        }
        if let plistURL {
            // bootstrap fails when already loaded — also fine.
            _ = try? await ProcessRunner.run("/bin/launchctl", ["bootstrap", target, plistURL.path])
        }
    }

    // MARK: - Shell fragments for privileged execution

    /// `do shell script` only reports the last command's exit status, so a
    /// `a; b; c` fragment can half-fail invisibly. These fragments instead
    /// echo one marker describing the real outcome: the persistent step
    /// (enable/disable) is the must-succeed part; bootstrap/bootout are
    /// idempotent best-effort; the end state is verified with
    /// `launchctl print`, not inferred from exit codes.
    public enum PrivilegedOutcome: Equatable, Sendable {
        case ok
        /// The persistent enable/disable override could not be written.
        case persistFailed
        /// Everything persisted, but the job is still loaded (a stop that
        /// didn't stick) — done, with a caveat worth telling the user.
        case stillLoaded
    }

    public static func parsePrivilegedOutcome(_ stdout: String) -> PrivilegedOutcome {
        if stdout.contains("BIRTH_PERSIST_FAILED") { return .persistFailed }
        if stdout.contains("BIRTH_STILL_LOADED") { return .stillLoaded }
        return .ok
    }

    public func shellCommandToDisableDaemon(label: String) -> String {
        let target = "system/\(shellQuote(label))"
        return "launchctl disable \(target) || { echo BIRTH_PERSIST_FAILED; exit 0; }; "
            + "launchctl bootout \(target) >/dev/null 2>&1; "
            + "launchctl print \(target) >/dev/null 2>&1 && echo BIRTH_STILL_LOADED || echo BIRTH_OK"
    }

    public func shellCommandToEnableDaemon(label: String, plistPath: String?) -> String {
        let target = "system/\(shellQuote(label))"
        var command = "launchctl enable \(target) || { echo BIRTH_PERSIST_FAILED; exit 0; }; "
        if let plistPath {
            // Bootstrap failure is tolerable (already loaded, or it will
            // load next boot now that it's enabled) — the refresh after
            // this shows the real runtime state either way.
            command += "launchctl bootstrap system \(shellQuote(plistPath)) >/dev/null 2>&1; "
        }
        command += "echo BIRTH_OK"
        return command
    }

    /// Post-mutation verification: is the job present in the GUI session?
    public func isLoadedInGUISession(label: String) async -> Bool {
        let result = try? await ProcessRunner.run("/bin/launchctl", ["print", "gui/\(uid)/\(label)"])
        return result?.succeeded == true
    }

    // MARK: - Parsers

    /// Parses `launchctl print-disabled <domain>` output.
    /// Lines look like `"com.foo.bar" => disabled` (older systems: `=> true`,
    /// where true means disabled). Returns label -> isDisabled.
    public static func parsePrintDisabled(_ text: String) -> [String: Bool] {
        var overrides: [String: Bool] = [:]
        for line in text.split(separator: "\n") {
            guard let arrowRange = line.range(of: "=>") else { continue }
            var label = line[..<arrowRange.lowerBound].trimmingCharacters(in: .whitespaces)
            label = label.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = line[arrowRange.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            switch value {
            case "disabled", "true": overrides[label] = true
            case "enabled", "false": overrides[label] = false
            default: continue
            }
        }
        return overrides
    }

    /// Parses `launchctl list` output: `PID\tStatus\tLabel` with `-` for not running.
    public static func parseList(_ text: String) -> [String: JobRuntime] {
        var jobs: [String: JobRuntime] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { continue }
            let label = columns[2].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            jobs[label] = JobRuntime(pid: Int(columns[0].trimmingCharacters(in: .whitespaces)))
        }
        return jobs
    }

    /// Parses the `services = {` block of `launchctl print <domain>` output.
    /// Rows look like `\t\t     766      - \tcom.apple.runningboardd`
    /// (pid, last exit status, label) where pid 0 means not running.
    public static func parsePrintServices(_ text: String) -> [String: JobRuntime] {
        var jobs: [String: JobRuntime] = [:]
        var inServicesBlock = false
        for line in text.split(separator: "\n") {
            if !inServicesBlock {
                if line.trimmingCharacters(in: .whitespaces) == "services = {" {
                    inServicesBlock = true
                }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "}" { break }
            let fields = trimmed.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, let rawPID = Int(fields[0]) else { continue }
            let label = fields[2...].joined(separator: " ")
            jobs[label] = JobRuntime(pid: rawPID == 0 ? nil : rawPID)
        }
        return jobs
    }
}

public enum LaunchctlError: Error, LocalizedError {
    case commandFailed(command: String, detail: String)
    /// The persistent off switch was written, but the running instance
    /// survived the bootout — done, with a caveat the user must hear.
    case disabledButStillRunning

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let detail):
            "launchctl \(command) 执行失败：\(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .disabledButStillRunning:
            "已停用，但该任务的进程仍在运行；注销或重启后将彻底停止。"
        }
    }
}

/// Quote a string for safe interpolation into a POSIX shell command.
public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
