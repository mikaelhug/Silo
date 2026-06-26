import SwiftUI
import AppKit

/// A row that displays a path and lets the user pick a file or directory via NSOpenPanel
/// (powerbox grant — avoids TCC denials for non-sandboxed access).
struct PathPickerRow: View {
    let title: String
    @Binding var url: URL?
    var chooseDirectories: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(url?.path ?? "Not set")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Choose…", action: pick)
            if url != nil {
                Button(role: .destructive) { url = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = chooseDirectories
        panel.canChooseFiles = !chooseDirectories
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if panel.runModal() == .OK { url = panel.url }
    }
}
