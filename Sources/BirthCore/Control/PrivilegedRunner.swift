import Foundation

/// Runs a shell command with administrator privileges via osascript.
/// macOS shows its standard admin-password dialog; we never see the password.
public enum PrivilegedRunner {
    public enum PrivilegedError: Error, LocalizedError {
        case cancelled
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .cancelled: "管理员授权已取消。"
            case .failed(let detail): detail
            }
        }
    }

    /// Returns the script's stdout: `do shell script` only surfaces the
    /// LAST command's exit status, so multi-step privileged fragments
    /// report per-step outcomes through stdout markers instead.
    @discardableResult
    public static func runShell(_ command: String, prompt: String) async throws -> String {
        let script = """
        do shell script "\(appleScriptQuote(command))" with prompt "\(appleScriptQuote(prompt))" with administrator privileges
        """
        // Long timeout: this call legitimately blocks while the user types
        // their password into the admin prompt.
        let result = try await ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 300)
        guard !result.succeeded else { return result.stdout }
        if result.stderr.contains("-128") || result.stderr.localizedCaseInsensitiveContains("canceled")
            || result.stderr.localizedCaseInsensitiveContains("cancelled") {
            throw PrivilegedError.cancelled
        }
        throw PrivilegedError.failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Escape a string for embedding in an AppleScript string literal.
    static func appleScriptQuote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
