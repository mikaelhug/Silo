import SwiftUI
import AppKit

struct LogViewerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let game: SteamApp
    @State private var contents = ""

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(contents.isEmpty ? "No log yet." : contents)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("logBottom")
                    }
                    .padding()
                }
                .onChange(of: contents) { _, _ in proxy.scrollTo("logBottom", anchor: .bottom) }
            }
            .navigationTitle("\(game.name) — Log")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([env.logURL(for: game)])
                    }
                }
            }
        }
        .frame(width: 640, height: 420)
        .task {
            // Live tail: re-read the log every second while the viewer is open (cancels on dismiss).
            while !Task.isCancelled {
                contents = await env.readLog(for: game)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
