import BirthCore
import SwiftUI

struct ItemDetailView: View {
    private var state: AppState { .shared }
    let item: LaunchItem
    @State private var showingPlist = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                details
                Divider()
                actions
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showingPlist) {
            if let plistURL = item.plistURL {
                PlistViewer(url: plistURL)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.displayName)
                .font(.title3.weight(.semibold))
            Text(item.label)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.isMasquerading(item) {
                Label("标识符伪装成 Apple 系统项（com.apple.*），但签名验证不符。这是恶意软件常用的持久化伪装手法，建议核查其来源。", systemImage: "exclamationmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            row("类型") {
                Text(item.domain.displayName)
            }
            row("位置") {
                Text(item.domain.locationDescription)
                    .foregroundStyle(.secondary)
            }
            row("状态") {
                stateText
            }
            if let signature = state.signature(for: item) {
                row("开发者") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(signature.shortDescription)
                        if let team = signature.teamID {
                            Text("团队 ID \(team)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let path = item.executablePath {
                row("可执行文件") {
                    pathText(path)
                }
            }
            if let plistURL = item.plistURL {
                row("属性列表") {
                    pathText(plistURL.path)
                }
            }
            if let schedule = item.schedule {
                row("运行计划") { Text(schedule) }
            }
            if item.runAtLoad || item.keepAlive {
                row("行为") {
                    Text(behaviorText)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stateText: some View {
        let enabled = item.enablement.isEnabled
        let base = switch item.enablement {
        case .enabled: "已启用"
        case .disabled: "已停用"
        case .managedBySystem(let isOn): isOn ? "已启用（由 macOS 管理）" : "已停用（由 macOS 管理）"
        case .unknown: "未知"
        }
        let runtime = item.pid.map { " · 运行中（PID \($0)）" } ?? (item.isLoaded ? " · 已加载" : "")
        return Text(base + runtime)
            .foregroundStyle(enabled == false ? Color.secondary : Color.primary)
    }

    private var behaviorText: String {
        var parts: [String] = []
        if item.runAtLoad { parts.append("加载时立即启动") }
        if item.keepAlive { parts.append("退出后自动重启") }
        return parts.joined(separator: "，")
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.isUserRemovable {
                if item.plistURL != nil {
                    Button {
                        showingPlist = true
                    } label: {
                        Label("查看属性列表", systemImage: "doc.text.magnifyingglass")
                    }
                }
                Button(role: .destructive) {
                    state.itemPendingRemoval = item
                } label: {
                    Label("移除…", systemImage: "trash")
                }
            } else {
                Button {
                    state.openLoginItemsSettings()
                } label: {
                    Label("打开系统设置…", systemImage: "gear")
                }
                Text("登录项只能由 macOS 本身开启或关闭。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pathText(_ path: String) -> some View {
        Button {
            state.revealInFinder(URL(filePath: path))
        } label: {
            Text(path)
                .font(.caption.monospaced())
                .multilineTextAlignment(.leading)
                .foregroundStyle(.link)
        }
        .buttonStyle(.plain)
        .help("在访达中显示")
    }
}
