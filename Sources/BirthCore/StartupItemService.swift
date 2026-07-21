import Foundation

/// The facade the UI talks to: one call to load everything, simple calls to act.
public struct StartupItemService: Sendable {
    public struct Snapshot: Sendable {
        public var items: [LaunchItem]
        /// Non-nil when BTM login items could not be read (usually missing Full Disk Access).
        public var loginItemsError: String?

        public init(items: [LaunchItem] = [], loginItemsError: String? = nil) {
            self.items = items
            self.loginItemsError = loginItemsError
        }
    }

    public var scanner: LaunchdScanner
    public var launchctl: LaunchctlClient
    public var btmReader: BTMReader
    public var remover: ItemRemover

    public init(
        scanner: LaunchdScanner = LaunchdScanner(),
        launchctl: LaunchctlClient = LaunchctlClient(),
        btmReader: BTMReader = BTMReader()
    ) {
        self.scanner = scanner
        self.launchctl = launchctl
        self.btmReader = btmReader
        self.remover = ItemRemover(launchctl: launchctl)
    }

    // MARK: - Loading

    public func loadSnapshot() async -> Snapshot {
        async let guiOverridesTask = launchctl.disabledOverrides(domainTarget: "gui/\(launchctl.uid)")
        async let systemOverridesTask = launchctl.disabledOverrides(domainTarget: "system")
        async let guiRuntimeTask = launchctl.guiSessionRuntime()
        async let systemRuntimeTask = launchctl.systemRuntime()

        let scanned = [LaunchItem.Domain.userAgent, .globalAgent, .globalDaemon]
            .flatMap { scanner.scan(domain: $0) }

        let guiOverrides = await guiOverridesTask
        let systemOverrides = await systemOverridesTask
        let guiRuntime = await guiRuntimeTask
        let systemRuntime = await systemRuntimeTask

        var items = scanned.map { item in
            merge(
                item: item,
                overrides: item.domain == .globalDaemon ? systemOverrides : guiOverrides,
                runtime: item.domain == .globalDaemon ? systemRuntime : guiRuntime
            )
        }

        var loginItemsError: String?
        do {
            let btmItems = try await btmReader.loginItems()
            items.append(contentsOf: btmItems.map(LaunchItem.init(btmItem:)))
        } catch {
            loginItemsError = error.localizedDescription
        }

        return Snapshot(items: items, loginItemsError: loginItemsError)
    }

    func merge(item: LaunchItem, overrides: [String: Bool], runtime: [String: JobRuntime]) -> LaunchItem {
        var item = item
        if let isDisabled = overrides[item.label] {
            item.enablement = isDisabled ? .disabled : .enabled
        } else if item.enablement == .unknown {
            // No override recorded and no Disabled key in the plist: launchd's default.
            item.enablement = .enabled
        }
        if let jobRuntime = runtime[item.label] {
            item.isLoaded = true
            item.pid = jobRuntime.pid
        }
        return item
    }

    // MARK: - Actions

    public func setEnabled(_ enabled: Bool, item: LaunchItem) async throws {
        switch item.domain {
        case .userAgent, .globalAgent:
            if enabled {
                try await launchctl.enableInGUISession(label: item.label, plistURL: item.plistURL)
            } else {
                try await launchctl.disableInGUISession(label: item.label)
            }
        case .globalDaemon:
            let command = enabled
                ? launchctl.shellCommandToEnableDaemon(label: item.label, plistPath: item.plistURL?.path)
                : launchctl.shellCommandToDisableDaemon(label: item.label)
            let verb = enabled ? "启用" : "停用"
            let output = try await PrivilegedRunner.runShell(
                command,
                prompt: "Birth 想要\(verb)启动项“\(item.displayName)”。"
            )
            switch LaunchctlClient.parsePrivilegedOutcome(output) {
            case .ok:
                break
            case .persistFailed:
                throw LaunchctlError.commandFailed(
                    command: enabled ? "enable" : "disable",
                    detail: "无法写入持久化的开关状态，未做任何更改。"
                )
            case .stillLoaded:
                throw LaunchctlError.disabledButStillRunning
            }
        case .loginItem:
            throw ItemRemover.RemovalError.notRemovable(ItemRemover.loginItemsManagedMessage)
        }
    }

    public func remove(_ item: LaunchItem) async throws {
        try await remover.remove(item)
    }

    /// Slow (Security framework) — call off the main path and cache per path.
    public func signature(forExecutable path: String) async -> SignatureInfo? {
        await Task.detached(priority: .utility) {
            CodeSignInspector.inspect(path: path)
        }.value
    }
}
