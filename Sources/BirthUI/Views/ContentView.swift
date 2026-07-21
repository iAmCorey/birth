import BirthCore
import SwiftUI

/// One unified sidebar layout: "启动应用" (the everyday Open-at-Login
/// manager) on top, "高级启动项" (the full launchd/BTM table) below.
struct ContentView: View {
    private var state: AppState { .shared }
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var state = state
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            Group {
                switch state.selection {
                case .loginApps:
                    SimpleLoginAppsView()
                        .transition(.opacity)
                case .recentlyRemoved:
                    RecentlyRemovedView()
                        .transition(.opacity)
                case .all, .domain:
                    AdvancedItemsView()
                        .transition(.opacity)
                }
            }
            // Animate only when crossing between the two sidebar groups —
            // switching within a group should not blink the content.
            .animation(.easeInOut(duration: 0.15), value: isAdvancedSelection)
        }
        .task { await state.refresh() }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { state.lastErrorMessage != nil },
                set: { if !$0 { state.lastErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(state.lastErrorMessage ?? "")
        }
        // Root-level: removal can now start from 启动应用 (agent rows) as
        // well as the advanced table, so the dialog must outlive both.
        .confirmationDialog(
            "移除“\(state.itemPendingRemoval?.displayName ?? "")”？",
            isPresented: Binding(
                get: { state.itemPendingRemoval != nil },
                set: { if !$0 { state.itemPendingRemoval = nil } }
            )
        ) {
            Button("移到废纸篓", role: .destructive) {
                state.confirmRemoval()
            }
        } message: {
            Text("该任务会先停止运行，其 plist 文件将移到废纸篓。Birth 会在 ~/Library/Application Support/Birth/Backups 中保留一份备份。")
        }
    }

    private var isAdvancedSelection: Bool {
        state.selection.isAdvanced
    }
}

/// The power-user table: every launchd job and BTM record on the system,
/// with its own search field, toolbar, inspector, and removal dialog.
struct AdvancedItemsView: View {
    private var state: AppState { .shared }

    var body: some View {
        @Bindable var state = state
        ItemTableView()
            .navigationTitle(state.selection.displayTitle)
            .navigationSubtitle("共 \(state.visibleItems.count) 项")
            .searchable(text: $state.searchText, placement: .toolbar, prompt: "名称、开发者或路径")
            .toolbar {
                ToolbarItemGroup {
                    Picker("范围", selection: $state.showAppleItems) {
                        Text("第三方").tag(false)
                        Text("全部").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .help("“第三方”只显示非 Apple 的启动项；“全部”包含 macOS 自带的系统服务")

                    RefreshToolbarButton()
                }
            }
            .alert("缺少“完全磁盘访问权限”", isPresented: $state.showFullDiskAccessPrompt) {
                Button("打开隐私设置") {
                    state.openFullDiskAccessSettings()
                }
                Button("暂不", role: .cancel) {}
            } message: {
                Text("其余分类均已正常刷新，只有“登录项”分类需要该权限才能读取。授权一次即可——之后每次刷新都会静默包含登录项，不再出现本提示。授权后切回 Birth 会自动刷新。")
            }
            .inspector(isPresented: inspectorShown) {
                if let item = state.selectedItem {
                    ItemDetailView(item: item)
                        .inspectorColumnWidth(min: 300, ideal: 340)
                }
            }
    }

    private var inspectorShown: Binding<Bool> {
        Binding(
            get: { state.selectedItemID != nil },
            set: { if !$0 { state.selectedItemID = nil } }
        )
    }
}
