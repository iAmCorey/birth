import BirthCore
import SwiftUI

/// The 最近移除 section's own page: everything removed from 启动应用,
/// one click from coming back. Reachable from the sidebar whenever the
/// record is non-empty.
struct RecentlyRemovedView: View {
    private var state: AppState { .shared }
    @State private var confirmingClear = false

    var body: some View {
        Group {
            if state.restorableRemovedLoginApps.isEmpty {
                ContentUnavailableView {
                    Label("没有最近移除的 App", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("从“启动应用”移除的 App 会记录在这里，可以一键重新启用。")
                }
            } else {
                List {
                    Section {
                        ForEach(state.restorableRemovedLoginApps) { app in
                            RemovedLoginAppRow(app: app)
                        }
                    } footer: {
                        Text("记录只保存在本机，最多保留 10 条。重新启用或从磁盘删除 App 后会自动消失。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("最近移除")
        .navigationSubtitle("共 \(state.restorableRemovedLoginApps.count) 项")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("清空记录") {
                    confirmingClear = true
                }
                .disabled(state.restorableRemovedLoginApps.isEmpty)
            }
        }
        .confirmationDialog(
            "清空最近移除记录？",
            isPresented: $confirmingClear
        ) {
            Button("清空", role: .destructive) {
                state.clearRemovedLoginAppRecords()
            }
        } message: {
            Text("仅清除这份记录，不会影响任何 App 或登录设置。")
        }
        // The restorable filter needs the live list to hide re-added apps.
        .task { await state.loadLoginApps() }
    }
}

/// A row in 最近移除: dimmed, with one obvious way back.
struct RemovedLoginAppRow: View {
    private var state: AppState { .shared }
    let app: LoginApp

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: AppIconCache.icon(forPath: app.path))
                .resizable()
                .frame(width: 28, height: 28)
                .opacity(0.55)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .foregroundStyle(.secondary)
                Text("已从“启动应用”移除")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            MutationButton(title: "重新启用", isBusy: state.busyLoginAppPaths.contains(app.path)) {
                state.reenableLoginApp(app)
            }
            .help("重新在登录时打开此 App")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("在访达中显示") {
                state.revealInFinder(URL(filePath: app.path))
            }
            Button("从记录中清除") {
                state.forgetRemovedLoginApp(app)
            }
        }
    }
}
