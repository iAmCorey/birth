import BirthCore
import SwiftUI

struct SidebarView: View {
    private var state: AppState { .shared }
    var body: some View {
        @Bindable var state = state
        List(selection: $state.selection) {
            Section {
                row(.loginApps)
                if state.count(for: .recentlyRemoved) > 0 {
                    row(.recentlyRemoved)
                }
            }
            Section("高级启动项") {
                row(.all)
                ForEach(LaunchItem.Domain.allCases, id: \.self) { domain in
                    row(.domain(domain))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if state.loginItemsError != nil {
                FullDiskAccessHint()
                    .padding(10)
            }
        }
    }

    private func row(_ section: AppState.SidebarSection) -> some View {
        Label {
            Text(section.displayTitle)
                .badge(state.count(for: section))
        } icon: {
            Image(systemName: section.systemImage)
        }
        .tag(section)
    }
}

/// Always-on breadcrumb for the one permission-gated slice: reachable
/// even when the user never visits 登录项 or clicks refresh. Kept by
/// product decision — the in-place guidance covers active discovery,
/// this covers passive.
private struct FullDiskAccessHint: View {
    private var state: AppState { .shared }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("登录项不可用", systemImage: "lock.shield")
                .font(.callout.weight(.semibold))
            Text("授权一次“完全磁盘访问权限”，之后刷新即可静默读取登录项。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("打开隐私设置") {
                state.openFullDiskAccessSettings()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
