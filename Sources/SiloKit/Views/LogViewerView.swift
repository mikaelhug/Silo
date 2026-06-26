import SwiftUI
import AppKit

struct LogViewerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let game: SteamApp
    @State private var contents = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(contents.isEmpty ? "No log yet." : contents)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle("\(game.name) — Log")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem {
                    Button("Reload") { Task { contents = await env.readLog(for: game) } }
                }
                ToolbarItem {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([env.logURL(for: game)])
                    }
                }
            }
        }
        .frame(width: 640, height: 420)
        .task { contents = await env.readLog(for: game) }
    }
}
