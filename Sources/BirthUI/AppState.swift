import AppKit
import BirthCore
import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    /// The app's single state object. Views reference it directly instead of
    /// via @Environment: SwiftUI hosts rendered outside the main hierarchy
    /// (inspector panes, menus, toolbar items, accessibility-driven view
    /// instantiation) do not reliably inherit injected environment objects,
    /// and a missed boundary is a guaranteed crash. @Observable tracking
    /// works through direct references, so nothing is lost.
    static let shared = AppState()

    enum SidebarSection: Hashable {
        /// The "Open at Login" app manager — the everyday section.
        case loginApps
        /// Apps removed from Open at Login, one click from coming back.
        case recentlyRemoved
        /// The power-user table: everything, or one launchd/BTM domain.
        case all
        case domain(LaunchItem.Domain)

        var storageValue: String {
            switch self {
            case .loginApps: "loginApps"
            case .recentlyRemoved: "recentlyRemoved"
            case .all: "all"
            case .domain(let domain): "domain.\(domain.rawValue)"
            }
        }

        init?(storageValue: String) {
            switch storageValue {
            case "loginApps": self = .loginApps
            case "recentlyRemoved": self = .recentlyRemoved
            case "all": self = .all
            default:
                guard storageValue.hasPrefix("domain."),
                      let domain = LaunchItem.Domain(rawValue: String(storageValue.dropFirst("domain.".count)))
                else { return nil }
                self = .domain(domain)
            }
        }

        var isAdvanced: Bool {
            switch self {
            case .loginApps, .recentlyRemoved: false
            case .all, .domain: true
            }
        }

        /// Single source for the sidebar row, the window title, and any
        /// menu entry that names a section.
        var displayTitle: String {
            switch self {
            case .loginApps: "启动应用"
            case .recentlyRemoved: "最近移除"
            case .all: "全部"
            case .domain(let domain): domain.displayName
            }
        }

        var systemImage: String {
            switch self {
            case .loginApps: "macwindow"
            case .recentlyRemoved: "clock.arrow.circlepath"
            case .all: "square.grid.2x2"
            case .domain(let domain): domain.systemImage
            }
        }
    }

    var items: [LaunchItem] = []
    var loginItemsError: String?
    var isLoading = false
    var hasLoadedOnce = false
    /// Drives the "missing Full Disk Access" dialog after a manual refresh.
    var showFullDiskAccessPrompt = false

    var selection: SidebarSection {
        didSet { defaults.set(selection.storageValue, forKey: "sidebarSelection") }
    }
    var searchText = ""
    var showAppleItems = false
    var selectedItemID: LaunchItem.ID?

    /// Executable path -> signature, filled in asynchronously after each refresh.
    var signatures: [String: SignatureInfo] = [:]
    /// Items with an in-flight enable/disable/remove call.
    var busyItemIDs: Set<LaunchItem.ID> = []
    var lastErrorMessage: String?
    var itemPendingRemoval: LaunchItem?

    // Simple view: the "Open at Login" list.
    var loginApps: [LoginApp] = []
    var loginAppsError: LoginItemsClient.LoginItemsError?
    var isLoadingLoginApps = false
    /// Search scoped to the 启动应用 section — independent of the advanced
    /// table's query so switching sections doesn't cross-filter.
    var loginSearchText = ""
    /// Paths with an in-flight add/remove: System Events takes seconds,
    /// and a second click mid-flight would duplicate the mutation.
    var busyLoginAppPaths: Set<String> = []
    /// Apps removed from Open at Login in this app, newest first — the
    /// "re-enable" safety net. Persisted so regret can arrive next week.
    var recentlyRemovedLoginApps: [LoginApp] = [] {
        didSet {
            let data = try? JSONEncoder().encode(recentlyRemovedLoginApps)
            defaults.set(data, forKey: "recentlyRemovedLoginApps")
            recomputeRestorableRemoved()
        }
    }
    /// Rows for 最近移除: the record minus apps back in the live list or
    /// gone from disk. Stored, not computed — the per-app disk stat runs
    /// when a source changes, never during a render.
    private(set) var restorableRemovedLoginApps: [LoginApp] = []
    private static let recentlyRemovedLimit = 10
    /// App path -> bundle identifier, cached for related-item matching.
    private var bundleIdentifiers: [String: String] = [:]

    let service = StartupItemService()
    let loginItemsClient = LoginItemsClient()
    /// Injected so tests run against a scratch suite, never the user's real
    /// preferences.
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: "sidebarSelection")
        selection = stored.flatMap(SidebarSection.init(storageValue:)) ?? .loginApps
        if let data = defaults.data(forKey: "recentlyRemovedLoginApps"),
           let apps = try? JSONDecoder().decode([LoginApp].self, from: data) {
            recentlyRemovedLoginApps = apps
        }
        recomputeRestorableRemoved()
        // Coming back from System Settings after granting Full Disk Access
        // should just work — whichever door led there (refresh dialog,
        // sidebar card, or the 登录项 guidance page). Refresh only when the
        // slice failed earlier AND the cheap filesystem probe now passes;
        // while access stays missing, activation costs one probe, not a
        // full rescan.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.loginItemsError != nil, BTMReader.hasFullDiskAccess() else { return }
                Task { await self.refresh() }
            }
        }
    }

    /// Testing seam. Production code must keep using `.shared` — see its
    /// doc comment for why environment injection is off the table.
    convenience init(forTesting defaults: UserDefaults) {
        self.init(defaults: defaults)
    }

    // MARK: - Derived collections

    var visibleItems: [LaunchItem] {
        items.filter { item in
            switch selection {
            case .loginApps, .recentlyRemoved: false
            case .all: true
            case .domain(let domain): item.domain == domain
            }
        }
        .filter { showAppleItems || !isAppleItem($0) }
        .filter { matchesSearch($0) }
    }

    var selectedItem: LaunchItem? {
        items.first { $0.id == selectedItemID }
    }

    /// True when the current sidebar selection would display BTM login
    /// items — the only slice Full Disk Access unlocks.
    private var selectionCoversLoginItems: Bool {
        switch selection {
        case .all, .domain(.loginItem): true
        default: false
        }
    }

    func count(for section: SidebarSection) -> Int {
        switch section {
        case .loginApps: loginApps.count + appLikeAgents.count
        case .recentlyRemoved: restorableRemovedLoginApps.count
        case .all: items.filter { showAppleItems || !isAppleItem($0) }.count
        case .domain(let domain):
            items.filter { $0.domain == domain && (showAppleItems || !isAppleItem($0)) }.count
        }
    }

    func signature(for item: LaunchItem) -> SignatureInfo? {
        if let signature = item.signature { return signature }
        guard let path = item.executablePath else { return nil }
        return signatures[path]
    }

    private func isAppleItem(_ item: LaunchItem) -> Bool {
        // The verified signature outranks the label: a com.apple.* label is
        // attacker-writable and MUST NOT hide an item once its signature
        // disproves the claim. Until the signature arrives, the label
        // stands in provisionally — that keeps hundreds of genuine system
        // items from flashing into the third-party view during the
        // streamed signature pass.
        if let signature = signature(for: item) {
            return signature.kind == .apple
        }
        return item.claimsAppleLabel
    }

    /// The label claims Apple, the verified signature disproves it — shown
    /// as a red warning in the table and the detail pane.
    func isMasquerading(_ item: LaunchItem) -> Bool {
        item.isMasquerading(signature: signature(for: item))
    }

    private func matchesSearch(_ item: LaunchItem) -> Bool {
        matches(query: searchText, haystacks: [
            item.displayName,
            item.label,
            item.executablePath ?? "",
            signature(for: item)?.developerName ?? "",
        ])
    }

    /// One definition of "matches": trim, empty-query-passes,
    /// case-insensitive — shared by both search fields.
    private func matches(query: String, haystacks: [String]) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return haystacks.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    // MARK: - Loading

    /// Refresh means everything: the launchd/BTM snapshot AND the login-app
    /// list — both sections' buttons trigger the same load, so neither
    /// side's data (or sidebar badge) can go stale behind the other.
    func refresh(userInitiated: Bool = false) async {
        isLoading = true
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        let started = Date()
        if userInitiated {
            // A deliberate refresh promises current truth: a path-keyed
            // signature result must not outlive a binary swapped in place.
            signatures.removeAll()
        }
        // The two pipelines are independent I/O (launchctl + dir scans vs
        // SFL + codesign) — overlap them so refresh costs max, not sum.
        let service = self.service
        async let snapshotTask = service.loadSnapshot()
        await loadLoginApps()
        let snapshot = await snapshotTask
        // Fresh data lands immediately; only the spinner is held back.
        items = snapshot.items
        loginItemsError = snapshot.loginItemsError
        // A sub-perceptual spin reads as "the button did nothing" — hold
        // the spinner briefly so a deliberate click gets visible work.
        if userInitiated {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.4 {
                try? await Task.sleep(for: .seconds(0.4 - elapsed))
            }
        }
        // A deliberate refresh that comes back partial deserves a say-so —
        // every time, but only where the gap is visible: 全部 and 登录项
        // include the missing slice; the other domains refreshed complete,
        // so prompting there would be noise about somebody else's view.
        if userInitiated, loginItemsError != nil, selectionCoversLoginItems {
            showFullDiskAccessPrompt = true
        }
        // Off the critical path: the list appears immediately and the
        // Developer column fills in as results stream back.
        Task { await loadMissingSignatures() }

        // Headless smoke hook: BIRTH_AUTOTEST=inspector drives the
        // click-a-row-opens-inspector path that manual testing missed once.
        if ProcessInfo.processInfo.environment["BIRTH_AUTOTEST"] == "inspector",
           selectedItemID == nil {
            selection = .all
            selectedItemID = visibleItems.first?.id
        }
    }

    private func loadMissingSignatures() async {
        await loadSignatures(
            forPaths: items.compactMap { item in
                item.signature == nil ? item.executablePath : nil
            }
        )
    }

    private func loadSignatures(forPaths candidates: [String]) async {
        let paths = Array(Set(candidates.filter { signatures[$0] == nil }))
        guard !paths.isEmpty else { return }

        // Cap concurrency: each lookup blocks a thread inside the Security
        // framework, and an unbounded fan-out starves the cooperative pool.
        await withTaskGroup(of: (String, SignatureInfo?).self) { group in
            var iterator = paths.makeIterator()
            func addNext() {
                guard let path = iterator.next() else { return }
                group.addTask { [service] in
                    (path, await service.signature(forExecutable: path))
                }
            }
            for _ in 0..<4 { addNext() }
            for await (path, signature) in group {
                if let signature {
                    signatures[path] = signature
                }
                addNext()
            }
        }
    }

    // MARK: - Login apps (simple view)

    func loadLoginApps() async {
        // Coalesce: refresh() and the section .task both call this on
        // launch; a second concurrent run would double the SFL read and
        // the codesign pass.
        guard !isLoadingLoginApps else { return }
        isLoadingLoginApps = true
        defer { isLoadingLoginApps = false }
        do {
            let apps = try await loginItemsClient.list()
            loginApps = apps
            loginAppsError = nil
            recomputeRestorableRemoved()
            for app in apps where bundleIdentifiers[app.path] == nil {
                bundleIdentifiers[app.path] = Bundle(url: URL(filePath: app.path))?.bundleIdentifier ?? ""
            }
            await loadSignatures(forPaths: apps.map(\.path))
        } catch let error as LoginItemsClient.LoginItemsError {
            loginAppsError = error
        } catch {
            loginAppsError = .scriptFailed(error.localizedDescription)
        }
    }

    /// Shared scaffold for every System Events mutation: reentry guard,
    /// busy marker, reload, error routing. Callers supply the mutation
    /// and its record bookkeeping.
    private func performLoginAppMutation(
        path: String,
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !busyLoginAppPaths.contains(path) else { return }
        busyLoginAppPaths.insert(path)
        Task {
            defer { busyLoginAppPaths.remove(path) }
            do {
                try await operation()
                await loadLoginApps()
            } catch {
                presentLoginAppMutationError(error)
            }
        }
    }

    func addLoginApp(url: URL) {
        let path = url.path
        performLoginAppMutation(path: path) { [self] in
            try await loginItemsClient.add(appURL: url)
            recentlyRemovedLoginApps.removeAll { $0.path == path }
        }
    }

    func removeLoginApp(_ app: LoginApp) {
        performLoginAppMutation(path: app.path) { [self] in
            try await loginItemsClient.remove(appPath: app.path)
            var removed = recentlyRemovedLoginApps.filter { $0.path != app.path }
            removed.insert(app, at: 0)
            recentlyRemovedLoginApps = Array(removed.prefix(Self.recentlyRemovedLimit))
        }
    }

    /// Puts a previously removed app back into Open at Login.
    func reenableLoginApp(_ app: LoginApp) {
        addLoginApp(url: URL(filePath: app.path))
    }

    func forgetRemovedLoginApp(_ app: LoginApp) {
        recentlyRemovedLoginApps.removeAll { $0.path == app.path }
    }

    private func recomputeRestorableRemoved() {
        let livePaths = Set(loginApps.map(\.path))
        restorableRemovedLoginApps = recentlyRemovedLoginApps.filter { app in
            !livePaths.contains(app.path) && FileManager.default.fileExists(atPath: app.path)
        }
        // An emptied record removes the sidebar row — don't strand the user
        // on a page with no entry point. Running here (not in a didSet)
        // covers every emptying path: restore, forget, clear, the app
        // returning to the live list, or its deletion from disk.
        if selection == .recentlyRemoved, restorableRemovedLoginApps.isEmpty {
            selection = .loginApps
        }
    }

    var visibleLoginApps: [LoginApp] {
        loginApps.filter { matchesLoginSearch($0) }
    }

    /// Launch agents that open a real app at login (闪电说-style DIY
    /// 开机启动) — surfaced in 启动应用 so "why does X auto-open" has a
    /// one-page answer regardless of which mechanism the app picked.
    var appLikeAgents: [LaunchItem] {
        items.filter { $0.launchedAppBundlePath != nil }
            .sorted { ($0.launchedAppName ?? $0.displayName) < ($1.launchedAppName ?? $1.displayName) }
    }

    var visibleAppLikeAgents: [LaunchItem] {
        appLikeAgents.filter { item in
            matches(query: loginSearchText, haystacks: [
                item.launchedAppName ?? "",
                item.displayName,
                item.executablePath ?? "",
                signature(for: item)?.developerName ?? "",
            ])
        }
    }

    func clearRemovedLoginAppRecords() {
        recentlyRemovedLoginApps = []
    }

    private func matchesLoginSearch(_ app: LoginApp) -> Bool {
        matches(query: loginSearchText, haystacks: [
            app.name,
            app.path,
            signatures[app.path]?.developerName ?? "",
        ])
    }

    /// Reading the list needs no permission (LSSharedFileList), so the
    /// Automation consent now surfaces on the first add/remove. A denial
    /// gets the full-screen guidance view (with the settings shortcut);
    /// every other failure is a plain alert.
    private func presentLoginAppMutationError(_ error: Error) {
        if case LoginItemsClient.LoginItemsError.automationDenied = error {
            loginAppsError = .automationDenied
        } else {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Launchd jobs and BTM helpers that belong to this login app —
    /// the "what else did it install" transparency the simple view adds.
    func relatedBackgroundItems(for app: LoginApp) -> [LaunchItem] {
        let bundleID = bundleIdentifiers[app.path].flatMap { $0.isEmpty ? nil : $0 }
        let appPrefix = app.path.hasSuffix("/") ? app.path : app.path + "/"
        return items.filter { item in
            if item.executablePath?.hasPrefix(appPrefix) == true { return true }
            if let bundleID, item.label.hasPrefix(bundleID), item.domain != .loginItem { return true }
            return false
        }
    }

    func signature(forAppPath path: String) -> SignatureInfo? {
        signatures[path]
    }

    // MARK: - Actions

    func setEnabled(_ enabled: Bool, item: LaunchItem) {
        guard !busyItemIDs.contains(item.id) else { return }
        busyItemIDs.insert(item.id)
        Task {
            defer { busyItemIDs.remove(item.id) }
            do {
                try await service.setEnabled(enabled, item: item)
            } catch {
                lastErrorMessage = error.localizedDescription
            }
            // Refresh on failure too: a partial mutation (persisted but
            // still running, or vice versa) must show its real state.
            await refresh()
        }
    }

    func confirmRemoval() {
        guard let item = itemPendingRemoval else { return }
        itemPendingRemoval = nil
        busyItemIDs.insert(item.id)
        Task {
            defer { busyItemIDs.remove(item.id) }
            do {
                try await service.remove(item)
                if selectedItemID == item.id { selectedItemID = nil }
            } catch {
                lastErrorMessage = error.localizedDescription
                if case ItemRemover.RemovalError.removedButStillRunning = error,
                   selectedItemID == item.id {
                    // The plist is gone either way — drop the selection.
                    selectedItemID = nil
                }
            }
            // Refresh on failure too — see setEnabled.
            await refresh()
        }
    }

    // MARK: - Navigation helpers

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - App-like launch agents

extension LaunchItem {
    /// The outermost .app bundle when this item is a launch agent whose
    /// job is "open a real application at login" — the 闪电说 case: apps
    /// that implement their own 开机启动 by dropping a RunAtLoad agent
    /// pointing at their main binary. nil for daemons, disabled-at-boot
    /// jobs, embedded helpers (Contents/Library/...), updaters living in
    /// Application Support, and non-main binaries (Resources/Frameworks) —
    /// those keep their home in the advanced view.
    var launchedAppBundlePath: String? {
        guard domain == .userAgent || domain == .globalAgent,
              runAtLoad || keepAlive,
              let path = executablePath,
              let dotApp = path.range(of: ".app/")
        else { return nil }
        let bundle = String(path[..<dotApp.lowerBound]) + ".app"
        // The executable must be directly in the bundle's Contents/MacOS —
        // this single check also rejects every embedded-bundle shape
        // (Contents/Library/LoginItems/X.app/...) and Resources/Frameworks
        // binaries, because their prefix differs.
        let mainBinaryDir = bundle + "/Contents/MacOS/"
        guard path.hasPrefix(mainBinaryDir),
              !path.dropFirst(mainBinaryDir.count).contains("/")
        else { return nil }
        // A user-facing app lives in /Applications (or ~/Applications);
        // agents pointing into Application Support are infrastructure.
        guard bundle.hasPrefix("/Applications/")
            || bundle.hasPrefix(NSHomeDirectory() + "/Applications/")
        else { return nil }
        return bundle
    }

    var launchedAppName: String? {
        launchedAppBundlePath.map { URL(filePath: $0).deletingPathExtension().lastPathComponent }
    }
}

// MARK: - Display helpers

extension LaunchItem.Domain {
    var displayName: String {
        switch self {
        case .userAgent: "用户后台项"
        case .globalAgent: "全局后台项"
        case .globalDaemon: "守护进程"
        case .loginItem: "登录项"
        }
    }

    var systemImage: String {
        switch self {
        case .userAgent: "person"
        case .globalAgent: "person.2"
        case .globalDaemon: "gearshape.2"
        case .loginItem: "power"
        }
    }

    var locationDescription: String {
        switch self {
        case .userAgent: "~/Library/LaunchAgents"
        case .globalAgent: "/Library/LaunchAgents"
        case .globalDaemon: "/Library/LaunchDaemons"
        case .loginItem: "系统设置 > 通用 > 登录项与扩展"
        }
    }
}

extension SignatureInfo {
    var shortDescription: String {
        switch kind {
        case .apple: "Apple"
        case .appStore: developerName.map { "\($0)（App Store）" } ?? "App Store"
        case .developerID: developerName ?? teamID ?? "已识别开发者"
        case .adhoc: "临时签名（ad-hoc）"
        case .untrusted: "不受信任的证书"
        case .unsigned: "未签名"
        case .invalid: "签名无效"
        }
    }

    var isTrustworthy: Bool {
        switch kind {
        case .apple, .appStore, .developerID: true
        case .adhoc, .untrusted, .unsigned, .invalid: false
        }
    }
}
