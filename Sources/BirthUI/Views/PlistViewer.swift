import SwiftUI

/// Read-only plist source viewer. Binary plists are converted to XML for display.
struct PlistViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var content: String = ""
    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.lastPathComponent)
                    .font(.headline)
                Spacer()
                Button(justCopied ? "已拷贝" : "拷贝") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    justCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        justCopied = false
                    }
                }
                .disabled(justCopied)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView([.vertical, .horizontal]) {
                Text(content)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onExitCommand { dismiss() }
        .task { content = loadContent() }
    }

    private func loadContent() -> String {
        guard let data = try? Data(contentsOf: url) else {
            return "无法读取 \(url.path)"
        }
        // Convert binary plists to XML so they're human-readable.
        if let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let xml = try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0) {
            return String(decoding: xml, as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
