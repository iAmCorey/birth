import BirthCore
import SwiftUI

struct ItemTableView: View {
    private var state: AppState { .shared }
    @State private var copiedDiagnosticReport: String?

    var body: some View {
        @Bindable var state = state
        Group {
            if state.isLoading && !state.hasLoadedOnce {
                ProgressView(L("advanced.scanning"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showsLoginItemsGuidance {
                loginItemsGuidance
            } else if state.visibleItems.isEmpty {
                emptyState
            } else {
                table
            }
        }
    }

    /// Four reasons the table can be empty, four messages — most specific
    /// narrowing first: search, run-state filter, the 第三方 scope, and
    /// only then a genuinely empty category. Nothing that merely *hides*
    /// items may masquerade as "没有启动项".
    @ViewBuilder
    private var emptyState: some View {
        if !state.searchText.isEmpty {
            ContentUnavailableView(
                L("empty.noResults"),
                systemImage: "magnifyingglass",
                description: Text(L("advanced.empty.noMatch", state.searchText))
            )
        } else if state.anyTableFilterActive {
            ContentUnavailableView(
                L("empty.noResults"),
                systemImage: "line.3.horizontal.decrease.circle",
                description: filterEmptyDescription
            )
        } else if state.scopeHidesAllItems {
            ContentUnavailableView(
                L("advanced.empty.scopeTitle"),
                systemImage: "apple.logo",
                description: Text(L("advanced.empty.scopeBody"))
            )
        } else {
            ContentUnavailableView(
                L("advanced.empty.noneTitle"),
                systemImage: "moon.zzz",
                description: Text(L("advanced.empty.noneBody"))
            )
        }
    }

    /// Names the narrowing dimension when exactly one filter is active;
    /// both at once gets the generic line.
    private var filterEmptyDescription: Text {
        switch (state.runStateFilter, state.enablementFilter) {
        case (.all, let enablement):
            Text(L("advanced.empty.noEnablement", enablement.displayName))
        case (let runState, .all):
            Text(L("advanced.empty.noRunState", runState.displayName))
        default:
            Text(L("advanced.empty.filtered"))
        }
    }

    /// When the BTM slice is unreadable, replace the empty table with
    /// error-specific recovery instead of treating every failure as FDA.
    private var showsLoginItemsGuidance: Bool {
        state.selection == .domain(.loginItem)
            && state.loginItemsError != nil
            && state.visibleItems.isEmpty
    }

    @ViewBuilder
    private var loginItemsGuidance: some View {
        switch state.loginItemsError {
        case .fullDiskAccessRequired:
            ContentUnavailableView {
                Label(L("fda.guide.title"), systemImage: "lock.shield")
            } description: {
                Text(L("fda.guide.body"))
            } actions: {
                Button(L("common.openPrivacySettings")) {
                    state.openFullDiskAccessSettings()
                }
                Button(L("fda.guide.refreshed")) {
                    Task { await state.refresh() }
                }
            }
        case .unsupportedFormat:
            ContentUnavailableView {
                Label(L("btm.unsupported.title"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(L("btm.unsupported.body"))
            } actions: {
                retryAndSystemSettingsButtons
                copyDiagnosticsButton
            }
        case .storeUnavailable, .accountUnavailable:
            ContentUnavailableView {
                Label(L("btm.unavailable.title"), systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text(L("btm.unavailable.body"))
            } actions: {
                retryAndSystemSettingsButtons
                copyDiagnosticsButton
            }
        case nil:
            EmptyView()
        }
    }

    private var retryAndSystemSettingsButtons: some View {
        Group {
            Button(L("common.tryAgain")) {
                Task { await state.refresh() }
            }
            Button(L("common.openSystemSettings")) {
                state.openLoginItemsSettings()
            }
        }
    }

    private var copyDiagnosticsButton: some View {
        let currentReport = state.loginItemsDiagnosticReport
        return Button(
            copiedDiagnosticReport == currentReport
                ? L("btm.diagnosticsCopied")
                : L("btm.copyDiagnostics")
        ) {
            if state.copyLoginItemsDiagnostic() {
                copiedDiagnosticReport = currentReport
            }
        }
    }

    private var table: some View {
        @Bindable var state = state
        return Table(state.visibleItems, selection: $state.selectedItemID, sortOrder: $state.tableSortOrder) {
            TableColumn(L("column.name"), sortUsing: AppState.TableSortColumn.name.comparator) { item in
                NameCell(item: item)
                    .repeatTapTogglesInspector(item)
            }
            .width(min: 220, ideal: 300)

            TableColumn(L("column.developer"), sortUsing: AppState.TableSortColumn.developer.comparator) { item in
                DeveloperCell(item: item)
                    .repeatTapTogglesInspector(item)
            }
            .width(min: 140, ideal: 190)

            TableColumn(L("column.kind"), sortUsing: AppState.TableSortColumn.kind.comparator) { item in
                Text(kindText(for: item))
                    .foregroundStyle(.secondary)
                    .repeatTapTogglesInspector(item)
            }
            .width(min: 90, ideal: 110)

            TableColumn(L("column.status"), sortUsing: AppState.TableSortColumn.runState.comparator) { item in
                StatusCell(item: item)
                    .repeatTapTogglesInspector(item)
            }
            .width(min: 70, ideal: 80)

            // Header sort is fine here (the header is not the cell); what
            // stays off is the ROW tap layer below.
            TableColumn(L("column.enabled"), sortUsing: AppState.TableSortColumn.enablement.comparator) { item in
                // The ONE gesture-free column: its switch must not double
                // as a pane toggle. Every other (and any future) column
                // must carry .repeatTapTogglesInspector.
                EnabledCell(item: item)
            }
            .width(56)
            .alignment(.center)
        }
        .contextMenu(forSelectionType: LaunchItem.ID.self) { ids in
            if let id = ids.first, let item = state.items.first(where: { $0.id == id }) {
                contextMenu(for: item)
            }
        }
        .onDeleteCommand {
            // ⌫ on a selected row = the context menu's 移除….
            if let item = state.selectedItem, item.isUserRemovable {
                state.itemPendingRemoval = item
            }
        }
        .onExitCommand {
            // esc deselects, which also closes the inspector.
            state.selectedItemID = nil
        }
    }

    @ViewBuilder
    private func contextMenu(for item: LaunchItem) -> some View {
        if let plistURL = item.plistURL {
            Button(L("common.revealInFinder")) { state.revealInFinder(plistURL) }
        }
        if let path = item.executablePath {
            Button(L("advanced.revealExecutable")) { state.revealInFinder(URL(filePath: path)) }
        }
        if item.isUserRemovable {
            Divider()
            Button(L("common.remove"), role: .destructive) { state.itemPendingRemoval = item }
        } else {
            Button(L("common.openSystemSettings")) { state.openLoginItemsSettings() }
        }
    }

    private func kindText(for item: LaunchItem) -> String {
        if item.domain == .loginItem {
            return item.btmTypeDescription.map(Self.localizedBTMType) ?? L("domain.loginItem")
        }
        return item.domain.displayName
    }

    /// Maps normalized BTM type names to the UI language; unknown values
    /// pass through capitalized so new types still show something sensible.
    private static func localizedBTMType(_ raw: String) -> String {
        switch raw.lowercased() {
        case "app": "App"
        case "login item": L("domain.loginItem")
        case "agent": L("btm.agent")
        case "daemon": L("domain.daemon")
        case "background app refresh": L("btm.backgroundRefresh")
        default: raw.capitalized
        }
    }
}

private extension View {
    /// Full-width tap layer so a repeat click on the selected row toggles
    /// the detail pane. Simultaneous, so the table's own mouse-down
    /// selection keeps working. Every column gets this EXCEPT 启用 — its
    /// switch must not double as a pane toggle.
    func repeatTapTogglesInspector(_ item: LaunchItem) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                AppState.shared.rowTapped(item.id)
            })
    }
}

private struct NameCell: View {
    private var state: AppState { .shared }
    let item: LaunchItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.displayName)
                .lineLimit(1)
            if item.label != item.displayName {
                Text(item.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DeveloperCell: View {
    private var state: AppState { .shared }
    let item: LaunchItem

    var body: some View {
        if state.isMasquerading(item) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(L("badge.masquerade"))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            .help(L("badge.masqueradeHelp", state.signature(for: item)?.shortDescription ?? L("common.unknown")))
        } else if let signature = state.signature(for: item) {
            HStack(spacing: 4) {
                if !signature.isTrustworthy {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(L("badge.untrustedHelp"))
                }
                Text(signature.shortDescription)
                    .lineLimit(1)
                    .foregroundStyle(signature.isTrustworthy ? .primary : .secondary)
            }
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
        }
    }
}

private struct StatusCell: View {
    let item: LaunchItem

    var body: some View {
        switch item.runState {
        case .running(let pid):
            Label(L("status.pid", pid), systemImage: "circle.fill")
                .foregroundStyle(.green)
                .labelStyle(StatusLabelStyle())
                .help(L("status.runningHelp", pid))
        case .loadedIdle:
            Label(L("status.loaded"), systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
                .labelStyle(StatusLabelStyle())
                .help(L("status.loadedHelp"))
        case .notLoaded:
            Text("—")
                .foregroundStyle(.tertiary)
                .help(L("runState.notLoaded"))
        case .unknown:
            Text("—")
                .foregroundStyle(.tertiary)
                .help(L("status.unknownHelp"))
        }
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 7))
            configuration.title.font(.caption)
        }
    }
}

private struct EnabledCell: View {
    private var state: AppState { .shared }
    let item: LaunchItem

    var body: some View {
        if case .managedBySystem = item.enablement {
            Toggle("", isOn: .constant(item.enablement.isEnabled ?? false))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(true)
                .help(L("enablement.managedHelp"))
        } else {
            EnablementToggle(item: item)
        }
    }
}
