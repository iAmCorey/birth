import BirthCore
import SwiftUI

struct ItemTableView: View {
    private var state: AppState { .shared }
    var body: some View {
        @Bindable var state = state
        Group {
            if state.isLoading && !state.hasLoadedOnce {
                ProgressView("正在扫描启动项…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showsFullDiskAccessGuidance {
                fullDiskAccessGuidance
            } else if state.visibleItems.isEmpty {
                ContentUnavailableView(
                    state.searchText.isEmpty ? "没有启动项" : "无匹配结果",
                    systemImage: state.searchText.isEmpty ? "moon.zzz" : "magnifyingglass",
                    description: state.searchText.isEmpty
                        ? Text("此分类下没有注册任何启动项。")
                        : Text("没有与“\(state.searchText)”匹配的项目。")
                )
            } else {
                table
            }
        }
    }

    /// The 登录项 domain is the only slice that needs Full Disk Access.
    /// When it's selected and unreadable, replace the empty table with a
    /// one-time-setup walkthrough instead of a shrug.
    private var showsFullDiskAccessGuidance: Bool {
        state.selection == .domain(.loginItem)
            && state.loginItemsError != nil
            && state.visibleItems.isEmpty
    }

    private var fullDiskAccessGuidance: some View {
        ContentUnavailableView {
            Label("需要一次性授权", systemImage: "lock.shield")
        } description: {
            Text(
                """
                登录项数据由 macOS 的后台任务管理数据库提供，读取它需要“完全磁盘访问权限”。
                在系统设置中勾选 Birth——只需授权一次，之后每次刷新都会静默读取，不会再弹任何窗口。
                如果列表里 Birth 已经是开启状态，请先关闭再重新开启一次（重新安装后授权需要刷新）。
                """
            )
        } actions: {
            Button("打开隐私设置") {
                state.openFullDiskAccessSettings()
            }
            Button("已授权，刷新") {
                Task { await state.refresh() }
            }
        }
    }

    private var table: some View {
        @Bindable var state = state
        return Table(state.visibleItems, selection: $state.selectedItemID) {
            TableColumn("名称") { item in
                NameCell(item: item)
            }
            .width(min: 220, ideal: 300)

            TableColumn("开发者") { item in
                DeveloperCell(item: item)
            }
            .width(min: 140, ideal: 190)

            TableColumn("类型") { item in
                Text(kindText(for: item))
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)

            TableColumn("状态") { item in
                StatusCell(item: item)
            }
            .width(min: 70, ideal: 80)

            TableColumn("启用") { item in
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
            Button("在访达中显示") { state.revealInFinder(plistURL) }
        }
        if let path = item.executablePath {
            Button("显示可执行文件") { state.revealInFinder(URL(filePath: path)) }
        }
        if item.isUserRemovable {
            Divider()
            Button("移除…", role: .destructive) { state.itemPendingRemoval = item }
        } else {
            Button("打开系统设置…") { state.openLoginItemsSettings() }
        }
    }

    private func kindText(for item: LaunchItem) -> String {
        if item.domain == .loginItem {
            return item.btmTypeDescription.map(Self.localizedBTMType) ?? "登录项"
        }
        return item.domain.displayName
    }

    /// Maps `sfltool dumpbtm` type strings to Chinese; unknown values pass
    /// through capitalized so new BTM types still show something sensible.
    private static func localizedBTMType(_ raw: String) -> String {
        switch raw.lowercased() {
        case "app": "App"
        case "login item": "登录项"
        case "agent": "代理"
        case "daemon": "守护进程"
        case "background app refresh": "后台刷新"
        default: raw.capitalized
        }
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
                Text("伪装系统项")
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            .help("标识符声称属于 Apple（com.apple.*），但签名验证不符——这是恶意软件常用的伪装手法。实际签名：\(state.signature(for: item)?.shortDescription ?? "未知")")
        } else if let signature = state.signature(for: item) {
            HStack(spacing: 4) {
                if !signature.isTrustworthy {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("此可执行文件没有可识别的开发者签名")
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
        if let pid = item.pid {
            Label("PID \(pid, format: .number.grouping(.never))", systemImage: "circle.fill")
                .foregroundStyle(.green)
                .labelStyle(StatusLabelStyle())
                .help("正在运行（进程号 \(pid)）")
        } else if item.isLoaded {
            Label("已加载", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
                .labelStyle(StatusLabelStyle())
                .help("已加载到 launchd，当前未运行")
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
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
                .help("由 macOS 管理——请在系统设置 > 通用 > 登录项与扩展中更改")
        } else {
            EnablementToggle(item: item)
        }
    }
}
