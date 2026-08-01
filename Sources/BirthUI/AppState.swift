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
            case .loginApps: L("sidebar.loginApps")
            case .recentlyRemoved: L("sidebar.recentlyRemoved")
            case .all: L("common.all")
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

    /// The advanced table's runtime-state slices (issue #2) — the UI face
    /// of `LaunchItem.RunState`, which owns the classification itself.
    enum RunStateFilter: CaseIterable {
        case all
        case running
        case loadedIdle
        case notLoaded

        func allows(_ state: LaunchItem.RunState) -> Bool {
            switch (self, state) {
            case (.all, _), (.running, .running),
                 (.loadedIdle, .loadedIdle), (.notLoaded, .notLoaded): true
            default: false
            }
        }

        var displayName: String {
            switch self {
            case .all: L("common.all")
            case .running: L("runState.running")
            case .loadedIdle: L("runState.loadedIdle")
            case .notLoaded: L("runState.notLoaded")
            }
        }
    }

    /// The Settings pane's language override. The choice lives in our own
    /// `birthLanguage` key; AppleLanguages is only the applied EFFECT.
    /// Reading AppleLanguages back is unreliable as a source of truth:
    /// UserDefaults lookups fall through to the global domain, where the
    /// system's language list lives — a system list that happens to start
    /// with a bare "en" would masquerade as a manual override.
    enum AppLanguage: String, CaseIterable {
        case system
        case chinese = "zh-Hans"
        case english = "en"

        static func stored(in defaults: UserDefaults) -> AppLanguage {
            defaults.string(forKey: "birthLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .system
        }
    }

    /// The five sortable columns, each owning its comparator — the single
    /// source for the Table's sortUsing declarations AND the persistence
    /// round-trip. KeyPathComparator itself is not Codable, so the sort
    /// state is stored as "column:f|r" strings and rebuilt through here;
    /// matching back relies on the key paths being THESE instances'
    /// equals, which is why the columns must not build their own.
    enum TableSortColumn: String, CaseIterable {
        case name
        case developer
        case kind
        case runState
        case enablement

        var comparator: KeyPathComparator<LaunchItem> {
            switch self {
            case .name: KeyPathComparator(\.displayName, comparator: .localizedStandard)
            case .developer: KeyPathComparator(\.developerSortName, comparator: .localizedStandard)
            case .kind: KeyPathComparator(\.kindSortKey)
            case .runState: KeyPathComparator(\.runState.sortRank)
            case .enablement: KeyPathComparator(\.enablement.sortRank)
            }
        }
    }

    /// The filter menu's second dimension: enablement. `unknown`
    /// enablement matches neither specific slice — same honesty rule as
    /// RunState.unknown.
    enum EnablementFilter: CaseIterable {
        case all
        case enabled
        case disabled

        func allows(_ enablement: LaunchItem.EnablementState) -> Bool {
            switch self {
            case .all: true
            case .enabled: enablement.isEnabled == true
            case .disabled: enablement.isEnabled == false
            }
        }

        var displayName: String {
            switch self {
            case .all: L("common.all")
            case .enabled: L("enablement.enabled")
            case .disabled: L("enablement.disabled")
            }
        }
    }

    var items: [LaunchItem] = []
    var loginItemsError: BTMReader.BTMError?
    var isLoading = false
    var hasLoadedOnce = false
    /// Drives the "missing Full Disk Access" dialog after a manual refresh.
    var showFullDiskAccessPrompt = false

    var selection: SidebarSection {
        didSet { defaults.set(selection.storageValue, forKey: "sidebarSelection") }
    }
    var searchText = ""
    var showAppleItems = false
    /// Session-scoped like the search text — deliberately not persisted,
    /// so a forgotten filter can't make next week's list look shrunken.
    var runStateFilter: RunStateFilter = .all
    var enablementFilter: EnablementFilter = .all
    /// Either filter dimension narrowing the table — drives the filled
    /// funnel icon and the "filtered, not empty" empty state.
    var anyTableFilterActive: Bool {
        runStateFilter != .all || enablementFilter != .all
    }
    /// Column sort chosen by clicking table headers; empty = the scan's
    /// natural order (domain-grouped). Persisted, Finder-style: unlike a
    /// forgotten filter, a remembered sort hides nothing — it only orders.
    var tableSortOrder: [KeyPathComparator<LaunchItem>] = [] {
        didSet {
            let encoded = tableSortOrder.compactMap { comparator -> String? in
                guard let column = TableSortColumn.allCases.first(where: {
                    $0.comparator.keyPath == comparator.keyPath
                }) else { return nil }
                return "\(column.rawValue):\(comparator.order == .reverse ? "r" : "f")"
            }
            defaults.set(encoded, forKey: "tableSortOrder")
        }
    }
    /// Language override: the choice is persisted under our own key and
    /// mirrored into AppleLanguages, which the system resolves at NEXT
    /// launch — hence the relaunch notice.
    var appLanguage: AppLanguage {
        didSet {
            switch appLanguage {
            case .system:
                defaults.removeObject(forKey: "birthLanguage")
                defaults.removeObject(forKey: "AppleLanguages")
            case .chinese, .english:
                defaults.set(appLanguage.rawValue, forKey: "birthLanguage")
                defaults.set([appLanguage.rawValue], forKey: "AppleLanguages")
            }
        }
    }
    /// Snapshot at launch: the pane shows the relaunch notice only while
    /// the selection differs from what this process was started with —
    /// switching back hides it again.
    @ObservationIgnored private let languageAtLaunch: AppLanguage
    var needsRelaunchForLanguage: Bool {
        appLanguage != languageAtLaunch
    }

    /// What 跟随系统 resolves to RIGHT NOW, using the OS's own language
    /// matcher against the system-wide (global-domain) preference list.
    /// Neither Locale nor plain UserDefaults can answer this: the
    /// process's locale is frozen at launch, and a plain lookup falls
    /// through to whatever per-app override is being edited. Hand-rolled
    /// prefix matching would diverge from the app's real resolution
    /// (zh-Hant, fr, ja...) — unmatched systems land on Chinese, the
    /// package's defaultLocalization.
    var resolvedSystemLanguage: AppLanguage {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let preferences = global?["AppleLanguages"] as? [String] ?? []
        let available = AppLanguage.allCases.compactMap { $0 == .system ? nil : $0.rawValue }
        // The dev region rides at the END of the preference list: the API
        // alone answers "en" for a fr/ja system (bare-array fallback), but
        // at launch CFBundle falls back to CFBundleDevelopmentRegion
        // (zh-Hans) — appending it reproduces the launch behavior, while
        // any genuine match (zh-Hant systems carry en-TW) still wins first.
        let best = Bundle.preferredLocalizations(
            from: available, forPreferences: preferences + [AppLanguage.chinese.rawValue]
        ).first
        return best.flatMap(AppLanguage.init(rawValue:)) ?? .chinese
    }

    /// Spawn a fresh instance (which reads the new AppleLanguages) and
    /// quit this one — terminating only in the spawn's completion, so
    /// quitting can never outrun the launch request (a timer here would
    /// occasionally exit without a successor on a loaded machine). The
    /// brief two-instance overlap is harmless. Outside a packaged .app
    /// (swift run) there is no bundle to respawn — just quit.
    func relaunchApp() {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else {
            NSApp.terminate(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                // Quit ONLY behind a live successor. A failed spawn (app
                // moved/deleted, Launch Services error) must keep this
                // instance alive — quitting would look like a crash.
                if app != nil {
                    NSApp.terminate(nil)
                } else {
                    let reason = error?.localizedDescription
                    AppState.shared.lastErrorMessage = reason.map {
                        L("settings.relaunchFailed") + "\n" + $0
                    } ?? L("settings.relaunchFailed")
                }
            }
        }
    }

    var selectedItemID: LaunchItem.ID? {
        // Selection still drives the pane both ways (click a row → details,
        // click blank space → pane closes), matching the old reflex.
        didSet { inspectorPresented = selectedItemID != nil }
    }
    /// Detail-pane visibility. Decoupled from the selection because a full
    /// table leaves no blank space to click: with visibility *derived* from
    /// the selection, the pane could never be dismissed. The toolbar toggle
    /// writes this directly; the selection keeps nudging it via didSet.
    var inspectorPresented = false
    /// The selection as of the latest left-mouse-down, snapshotted by an
    /// event monitor BEFORE the table processes the click. Comparing
    /// against a *pre-click* snapshot is what makes "repeat click" honest:
    /// pairing a didSet flag with its tap broke whenever a selection
    /// change arrived without a tap to consume it (the gesture-free 启用
    /// column, keyboard selection) — the stale flag then swallowed the
    /// next genuine repeat click.
    @ObservationIgnored private var selectionAtMouseDown: LaunchItem.ID?

    /// Mouse-down half of the repeat-click detector. The production caller
    /// is the event monitor AppDelegate installs at launch (NOT here in
    /// init, so test instances don't each register an app-global input
    /// monitor); tests replay a down-then-tap click by calling it directly.
    func noteMouseDown() {
        selectionAtMouseDown = selectedItemID
    }

    /// Row-level tap (mouse-up), layered over the table's own mouse-down
    /// selection: a repeat click on the already-selected row toggles the
    /// detail pane — 点一次打开，再点一次收起.
    func rowTapped(_ id: LaunchItem.ID) {
        if selectedItemID != id {
            // The gesture won over the table's selection — do both halves.
            selectedItemID = id
        } else if selectionAtMouseDown == id {
            // Already selected when the mouse went down: a repeat click.
            inspectorPresented.toggle()
        }
        // Otherwise this very click performed the selection; the pane just
        // opened via didSet and must stay open.
    }

    /// Executable path -> signature, filled in asynchronously after each refresh.
    var signatures: [String: SignatureInfo] = [:]
    /// Bumped whenever the signature cache is deliberately invalidated
    /// (user-initiated refresh). In-flight signature rounds capture the
    /// value at start and stop writing once it moves on — without this, a
    /// stale round racing the fresh one could re-plant a pre-swap identity
    /// into the cleared cache and the fresh items, where the write-back's
    /// `== nil` guard would then pin it against the current round's
    /// correction. Identity data feeds the Apple filter and masquerade
    /// warning, so a stale win is a security-classification error.
    @ObservationIgnored private var signatureGeneration = 0
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
        let language = AppLanguage.stored(in: defaults)
        appLanguage = language
        languageAtLaunch = language
        let stored = defaults.string(forKey: "sidebarSelection")
        selection = stored.flatMap(SidebarSection.init(storageValue:)) ?? .loginApps
        // In-init assignment skips didSet, so restoring doesn't re-write.
        if let storedSort = defaults.stringArray(forKey: "tableSortOrder") {
            tableSortOrder = storedSort.compactMap { entry in
                let parts = entry.split(separator: ":")
                guard parts.count == 2,
                      let column = TableSortColumn(rawValue: String(parts[0]))
                else { return nil }
                var comparator = column.comparator
                comparator.order = parts[1] == "r" ? .reverse : .forward
                return comparator
            }
        }
        if let data = defaults.data(forKey: "recentlyRemovedLoginApps"),
           let apps = try? JSONDecoder().decode([LoginApp].self, from: data) {
            recentlyRemovedLoginApps = apps
        }
        recomputeRestorableRemoved()
        // Coming back from System Settings after granting Full Disk Access
        // should just work. Only a real permission failure auto-retries;
        // format/store failures cannot be fixed in Privacy settings.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      case .fullDiskAccessRequired? = self.loginItemsError,
                      BTMReader.hasFullDiskAccess()
                else { return }
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
        // Query-invariant work stays out of the per-item closure: this
        // recomputes on every signature-stream tick, so the PID query is
        // parsed once per pass, not once per row. Trim rule matches
        // matches(query:haystacks:).
        let pidQuery = Int(searchText.trimmingCharacters(in: .whitespaces))
        return items.filter { item in
            inSelectedSection(item)
                && (showAppleItems || !isAppleItem(item))
                && runStateFilter.allows(item.runState)
                && enablementFilter.allows(item.enablement)
                && matchesSearch(item, pidQuery: pidQuery)
        }
        .sorted(using: tableSortOrder)
    }

    private func inSelectedSection(_ item: LaunchItem) -> Bool {
        switch selection {
        case .loginApps, .recentlyRemoved: false
        case .all: true
        case .domain(let domain): item.domain == domain
        }
    }

    /// True when the current category is empty ONLY because the 第三方
    /// scope hides its items — the empty state must say so instead of
    /// pretending nothing is registered. Callers rule out search and the
    /// run-state filter first; any surviving item here is necessarily
    /// Apple-signed, or it would still be visible.
    var scopeHidesAllItems: Bool {
        !showAppleItems && items.contains { inSelectedSection($0) }
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

    /// The one resolver for an item's signature. Two stores back it:
    /// `item.signature` is a write-through copy of `signatures[path]`,
    /// hydrated when a snapshot lands (refresh) and as results stream in
    /// (loadSignatures) — it exists so sort keys (`developerSortName`)
    /// work through plain key paths. The dictionary stays authoritative:
    /// it outlives refreshes as a cache and also serves LoginApp paths,
    /// which never appear in `items`. Do not drop either side.
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

    private func matchesSearch(_ item: LaunchItem, pidQuery: Int?) -> Bool {
        // A numeric query also matches the PID — "which item spawned
        // process 1234?". Exact match only: substring would make "12"
        // sweep in every PID that happens to contain 12.
        if let pidQuery, item.pid == pidQuery {
            return true
        }
        return matches(query: searchText, haystacks: [
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
            // Bumping the generation makes any in-flight round drop its
            // remaining (pre-swap) results instead of re-planting them.
            signatures.removeAll()
            signatureGeneration += 1
        }
        // The two pipelines are independent I/O (launchctl + dir scans vs
        // SFL + codesign) — overlap them so refresh costs max, not sum.
        let service = self.service
        async let snapshotTask = service.loadSnapshot()
        await loadLoginApps()
        let snapshot = await snapshotTask
        // Fresh data lands immediately; only the spinner is held back.
        items = snapshot.items
        // Hydrate the fresh items from the signature cache RIGHT HERE, at
        // the landing point. A non-user refresh keeps the cache, so the
        // streaming pass below skips every cached path — without this,
        // item.signature stays nil after the first toggle-refresh and the
        // 开发者 sort key silently goes blank while the cells (which fall
        // back to the dictionary) keep looking correct.
        hydrateSignaturesFromCache()
        loginItemsError = snapshot.loginItemsError
        // A sub-perceptual spin reads as "the button did nothing" — hold
        // the spinner briefly so a deliberate click gets visible work.
        if userInitiated {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.4 {
                try? await Task.sleep(for: .seconds(0.4 - elapsed))
            }
        }
        // Only a genuine FDA denial gets the privacy alert. An unknown BTM
        // format or transient store error has its own in-place guidance.
        if userInitiated,
           loginItemsError?.requiresFullDiskAccess == true,
           selectionCoversLoginItems {
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

    /// Write cached signatures through to the items — the landing-point
    /// half of the invariant documented on signature(for:). The streaming
    /// half in loadSignatures covers results that arrive after landing.
    func hydrateSignaturesFromCache() {
        for index in items.indices {
            if items[index].signature == nil,
               let path = items[index].executablePath,
               let cached = signatures[path] {
                items[index].signature = cached
            }
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
        let generation = signatureGeneration

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
                guard generation == signatureGeneration else {
                    // The cache was invalidated mid-round: the remaining
                    // results describe binaries as they were before the
                    // swap. Drop them; the fresh round re-verifies.
                    group.cancelAll()
                    break
                }
                if let signature {
                    signatures[path] = signature
                    // Write through to the items so sort keys (开发者
                    // column) see the streamed identity; display keeps
                    // reading signature(for:) either way.
                    for index in items.indices
                    where items[index].executablePath == path && items[index].signature == nil {
                        items[index].signature = signature
                    }
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

    /// A privacy-safe support payload: archive structure and decoder stage,
    /// never item names, application paths, or raw database contents.
    var loginItemsDiagnosticReport: String? {
        guard let error = loginItemsError else { return nil }
        let detail = Self.redactedDiagnosticDetail(error.diagnosticDetail)
        return """
        Birth \(BirthInfo.displayVersion)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        BTM: \(detail)
        """
    }

    /// Diagnostic errors may originate in Foundation and contain the BTM
    /// filename (which embeds the account UUID) or an absolute path. Keep the
    /// useful decoder stage/class context while removing stable identifiers
    /// before a report reaches the clipboard or a public issue.
    private static func redactedDiagnosticDetail(_ detail: String) -> String {
        let replacements = [
            (
                #"(?i)\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b"#,
                "<redacted-uuid>"
            ),
            (
                #"(?i)(?:file://)?/(?:Applications|Users|Library|System|private|var|tmp|Volumes|opt|usr)(?:/[^\n\"'“”|:]+)+"#,
                "<redacted-path>"
            ),
        ]
        return replacements.reduce(detail) { result, replacement in
            result.replacingOccurrences(
                of: replacement.0,
                with: replacement.1,
                options: .regularExpression
            )
        }
    }

    @discardableResult
    func copyLoginItemsDiagnostic() -> Bool {
        guard let report = loginItemsDiagnosticReport else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(report, forType: .string)
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
        case .userAgent: L("domain.userAgent")
        case .globalAgent: L("domain.globalAgent")
        case .globalDaemon: L("domain.daemon")
        case .loginItem: L("domain.loginItem")
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
        case .loginItem: L("domain.loginItemLocation")
        }
    }
}

extension SignatureInfo {
    var shortDescription: String {
        switch kind {
        case .apple: "Apple"
        case .appStore: developerName.map { L("signature.appStore", $0) } ?? "App Store"
        case .developerID: developerName ?? teamID ?? L("signature.developerID")
        case .adhoc: L("signature.adhoc")
        case .untrusted: L("signature.untrusted")
        case .unsigned: L("signature.unsigned")
        case .invalid: L("signature.invalid")
        }
    }

    var isTrustworthy: Bool {
        switch kind {
        case .apple, .appStore, .developerID: true
        case .adhoc, .untrusted, .unsigned, .invalid: false
        }
    }
}
