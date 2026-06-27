import SwiftUI
import AppKit

/// Identifies a log to open in its own window (`openWindow(id: "silo-log", value:)`).
struct LogTarget: Identifiable, Hashable, Codable {
    var id: URL { url }
    let title: String
    let url: URL
}

/// Live, trailing viewer for any log file (per-game launch log or the master Steam log). Opens as a
/// standalone window (not a modal sheet) so it stays up while you drive the main app.
/// Re-reads the file's tail once a second; autoscrolls to the bottom unless the user pauses it.
struct LogViewerView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let url: URL
    @State private var contents = ""
    @State private var autoscroll = true

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
                .onChange(of: contents) { _, _ in
                    if autoscroll { proxy.scrollTo("logBottom", anchor: .bottom) }
                }
                .onChange(of: autoscroll) { _, on in
                    if on { proxy.scrollTo("logBottom", anchor: .bottom) }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem { Toggle("Autoscroll", isOn: $autoscroll) }
                ToolbarItem {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
        .frame(width: 680, height: 460)
        .task(id: url) {
            // Live tail while open (cancels on dismiss / url change).
            while !Task.isCancelled {
                contents = Self.tail(of: url)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Read the last `maxBytes` of the file so a huge log doesn't blow memory. "" if missing.
    static func tail(of url: URL, maxBytes: Int = 256 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
