import Foundation

/// Removes launchd items safely: back up the plist, stop the job, trash the file.
public struct ItemRemover: Sendable {
    /// Shared verbatim by every "login items are macOS-managed" refusal so
    /// the wording (and the System Settings path in it) can't drift.
    public static let loginItemsManagedMessage =
        "登录项由 macOS 管理，请前往系统设置 > 通用 > 登录项与扩展进行更改。"

    public enum RemovalError: Error, LocalizedError {
        case notRemovable(String)
        /// The plist is gone (removal persisted), but the loaded job kept
        /// running — surfaced so "removed" never silently means "still
        /// running". It stops for good at next logout/reboot.
        case removedButStillRunning

        public var errorDescription: String? {
            switch self {
            case .notRemovable(let reason): reason
            case .removedButStillRunning:
                "已移除，但该任务的进程仍在运行；注销或重启后将彻底停止。"
            }
        }
    }

    public var launchctl: LaunchctlClient

    public init(launchctl: LaunchctlClient = LaunchctlClient()) {
        self.launchctl = launchctl
    }

    public static var backupDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Birth/Backups", isDirectory: true)
    }

    /// Copy the plist into Birth's backup folder before any destructive step.
    @discardableResult
    public func backup(_ item: LaunchItem) throws -> URL? {
        guard let plistURL = item.plistURL else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stampedDir = Self.backupDirectory
            .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: stampedDir, withIntermediateDirectories: true)
        let destination = stampedDir.appendingPathComponent(plistURL.lastPathComponent)
        try FileManager.default.copyItem(at: plistURL, to: destination)
        return destination
    }

    /// Stop the job and move its plist to the Trash.
    /// User agents need no privileges; global items prompt for an admin password.
    public func remove(_ item: LaunchItem) async throws {
        guard let plistURL = item.plistURL else {
            throw RemovalError.notRemovable(
                "此项目由 macOS 管理，请前往系统设置 > 通用 > 登录项与扩展进行更改。"
            )
        }
        try backup(item)

        switch item.domain {
        case .userAgent:
            // disable+bootout is best-effort here (the plist itself is about
            // to go, which already prevents future loads) — but the outcome
            // must be honest, so verify instead of assuming.
            try? await launchctl.disableInGUISession(label: item.label)
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: plistURL, resultingItemURL: &trashedURL)
            if await launchctl.isLoadedInGUISession(label: item.label) {
                throw RemovalError.removedButStillRunning
            }

        case .globalAgent, .globalDaemon:
            let target = item.domain == .globalDaemon ? "system" : "gui/\(launchctl.uid)"
            let trashPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".Trash", isDirectory: true)
                .appendingPathComponent(uniqueTrashName(for: plistURL))
                .path
            // One privileged shell run. `do shell script` only reports the
            // last exit status, so each step's outcome travels via stdout
            // markers: stop and disable are best-effort, the move is the
            // must-succeed step, and the end state is verified with
            // `launchctl print` rather than inferred.
            let jobTarget = "\(shellQuote(target))/\(shellQuote(item.label))"
            let command = [
                "launchctl bootout \(jobTarget) >/dev/null 2>&1",
                "launchctl disable \(jobTarget) >/dev/null 2>&1",
                "mv \(shellQuote(plistURL.path)) \(shellQuote(trashPath)) || { echo BIRTH_MV_FAILED; exit 0; }",
                "launchctl print \(jobTarget) >/dev/null 2>&1 && echo BIRTH_STILL_LOADED || echo BIRTH_OK",
            ].joined(separator: "; ")
            let output = try await PrivilegedRunner.runShell(
                command,
                prompt: "Birth 想要移除启动项“\(item.displayName)”。"
            )
            if output.contains("BIRTH_MV_FAILED") {
                throw RemovalError.notRemovable("无法将 plist 文件移到废纸篓（权限或磁盘错误），未做任何更改。")
            }
            if output.contains("BIRTH_STILL_LOADED") {
                throw RemovalError.removedButStillRunning
            }

        case .loginItem:
            throw RemovalError.notRemovable(Self.loginItemsManagedMessage)
        }
    }

    private func uniqueTrashName(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let stamp = Int(Date().timeIntervalSince1970)
        return "\(base)-\(stamp).\(ext)"
    }
}
