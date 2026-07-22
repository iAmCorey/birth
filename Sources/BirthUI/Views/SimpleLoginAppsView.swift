import BirthCore
import SwiftUI
import UniformTypeIdentifiers

/// The everyday view: manage the "Open at Login" app list, with the extra
/// transparency (developer identity, related background pieces) that
/// System Settings never shows.
struct SimpleLoginAppsView: View {
    private var state: AppState { .shared }
    @State private var showingAppPicker = false
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var state = state
        Group {
            if let error = state.loginAppsError {
                automationErrorView(error)
            } else if state.loginApps.isEmpty && state.isLoadingLoginApps {
                ProgressView("正在读取登录项…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.loginApps.isEmpty && state.appLikeAgents.isEmpty {
                emptyState
            } else if state.visibleLoginApps.isEmpty && state.visibleAppLikeAgents.isEmpty {
                ContentUnavailableView(
                    "无匹配结果",
                    systemImage: "magnifyingglass",
                    description: Text("没有与“\(state.loginSearchText)”匹配的 App。")
                )
            } else {
                appList
            }
        }
        .navigationTitle("启动应用")
        .navigationSubtitle("共 \(state.visibleLoginApps.count + state.visibleAppLikeAgents.count) 项")
        .searchable(text: $state.loginSearchText, placement: .toolbar, prompt: "名称、开发者或路径")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingAppPicker = true
                } label: {
                    Label("添加 App", systemImage: "plus")
                }
                .help("添加一个登录时自动打开的 App")

                RefreshToolbarButton()
            }
        }
        .fileImporter(
            isPresented: $showingAppPicker,
            allowedContentTypes: [.application]
        ) { result in
            if case .success(let url) = result {
                state.addLoginApp(url: url)
            }
        }
        .fileDialogDefaultDirectory(URL(filePath: "/Applications", directoryHint: .isDirectory))
        // Drag an .app from Finder anywhere onto the view to add it.
        .dropDestination(for: URL.self) { urls, _ in
            let apps = urls.filter { $0.pathExtension == "app" }
            guard !apps.isEmpty else { return false }
            for url in apps {
                state.addLoginApp(url: url)
            }
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
        .overlay {
            if isDropTargeted {
                dropHighlight
            }
        }
        .task { await state.loadLoginApps() }
    }

    private var appList: some View {
        List {
            if !state.visibleLoginApps.isEmpty {
                Section {
                    ForEach(state.visibleLoginApps) { app in
                        LoginAppRow(app: app)
                    }
                } header: {
                    if !state.visibleAppLikeAgents.isEmpty {
                        Text("登录时打开")
                    }
                } footer: {
                    Text("这些 App 会在你登录 Mac 时自动打开。在这里移除也会同步从系统设置中移除——App 本身仍保留在磁盘上，可随时在侧边栏“最近移除”中重新启用。也可以直接把 App 拖进这个窗口来添加。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
            if !state.visibleAppLikeAgents.isEmpty {
                Section {
                    ForEach(state.visibleAppLikeAgents) { item in
                        AgentAppRow(item: item)
                    }
                } header: {
                    Text("其他方式自启")
                } footer: {
                    Text("这些 App 通过自带的后台项（LaunchAgent）在登录时自动打开——通常来自 App 内的“开机启动”设置。关闭开关即停止自启（无需密码）；右键可查看详情或彻底移除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("登录时不会打开任何 App", systemImage: "sunrise")
        } description: {
            Text("在这里添加的 App 会在你登录时自动启动，也可以直接把 App 拖进窗口。")
        } actions: {
            Button("添加 App…") { showingAppPicker = true }
        }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                Label("松开以添加到“登录时打开”", systemImage: "plus.app")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(12)
            .allowsHitTesting(false)
    }

    private func automationErrorView(_ error: LoginItemsClient.LoginItemsError) -> some View {
        let isDenied = if case .automationDenied = error { true } else { false }
        return ContentUnavailableView {
            Label(
                isDenied ? "需要授权才能管理登录项" : "无法读取登录项",
                systemImage: "lock.shield"
            )
        } description: {
            Text(error.localizedDescription + (isDenied ? "\n授权后即可添加和移除；查看列表本身无需任何权限。" : ""))
        } actions: {
            if isDenied {
                Button("打开自动化设置") {
                    state.openAutomationSettings()
                }
            }
            Button("返回列表") {
                state.loginAppsError = nil
                Task { await state.loadLoginApps() }
            }
        }
    }
}

private struct LoginAppRow: View {
    private var state: AppState { .shared }
    let app: LoginApp

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: AppIconCache.icon(forPath: app.path))
                .resizable()
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    developerText
                    if !relatedItems.isEmpty {
                        relatedBadge
                    }
                }
            }

            Spacer()

            MutationButton(title: "移除", isBusy: isBusy) {
                state.removeLoginApp(app)
            }
            .help("不再于登录时打开此 App")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("在访达中显示") {
                state.revealInFinder(URL(filePath: app.path))
            }
            if !relatedItems.isEmpty {
                Button("查看后台项目") {
                    showRelatedInAdvanced()
                }
            }
        }
    }

    private var relatedItems: [LaunchItem] {
        state.relatedBackgroundItems(for: app)
    }

    private var isBusy: Bool {
        state.busyLoginAppPaths.contains(app.path)
    }

    @ViewBuilder
    private var developerText: some View {
        if let signature = state.signature(forAppPath: app.path) {
            HStack(spacing: 3) {
                if !signature.isTrustworthy {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Text(signature.shortDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(app.path)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// Clickable: jumps to the advanced view filtered to this app's
    /// background pieces — the fastest answer to "what else did it install?".
    private var relatedBadge: some View {
        Button {
            showRelatedInAdvanced()
        } label: {
            Text("+\(relatedItems.count) 后台项")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("点击查看：\n" + relatedItems.map(\.displayName).joined(separator: "\n"))
    }

    private func showRelatedInAdvanced() {
        state.searchText = app.name
        state.selection = .all
    }
}

/// A launch agent that opens a real app at login — icon and name come
/// from the .app it launches; the switch is the item's launchd
/// enablement (user-session domains, so no password).
private struct AgentAppRow: View {
    private var state: AppState { .shared }
    let item: LaunchItem

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: AppIconCache.icon(forPath: item.launchedAppBundlePath ?? ""))
                .resizable()
                .frame(width: 36, height: 36)
                .opacity(item.enablement.isEnabled == false ? 0.55 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.launchedAppName ?? item.displayName)
                    .font(.body.weight(.medium))
                HStack(spacing: 3) {
                    if let signature = state.signature(for: item), !signature.isTrustworthy {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            EnablementToggle(item: item)
                .help("关闭后不再于登录时自动打开（无需密码）")
        }
        .padding(.vertical, 4)
        .contextMenu {
            if let bundle = item.launchedAppBundlePath {
                Button("在访达中显示") {
                    state.revealInFinder(URL(filePath: bundle))
                }
            }
            Button("在高级启动项中查看") {
                state.searchText = item.launchedAppName ?? item.displayName
                state.selection = .all
            }
            if item.isUserRemovable {
                Divider()
                Button("移除…", role: .destructive) {
                    state.itemPendingRemoval = item
                }
            }
        }
    }

    private var subtitle: String {
        let mechanism = item.domain == .userAgent ? "用户后台项" : "全局后台项"
        if let signature = state.signature(for: item) {
            return signature.shortDescription + " · " + mechanism
        }
        return mechanism
    }
}

