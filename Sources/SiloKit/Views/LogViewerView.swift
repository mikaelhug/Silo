import SwiftUI
import AppKit

/// Identifies a log to open in its own window (`openWindow(id: LogTarget.windowID, value:)`).
struct LogTarget: Identifiable, Hashable, Codable {
    /// The `WindowGroup` / `openWindow` id (must match `SiloApp`'s log window group).
    static let windowID = "silo-log"
    var id: URL { url }
    let title: String
    let url: URL
}

/// Live, trailing viewer for any log file (a per-game launch log or the Steam-bottle log). Opens as a
/// standalone window (not a modal sheet) so it stays up while you drive the main app.
/// Updates **reactively** when the file is written (a kqueue file-watcher, no polling); autoscrolls to
/// the bottom unless the user pauses it.
struct LogViewerView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let url: URL
    @State private var tailer = LogTailer()
    @State private var autoscroll = true

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(tailer.contents.isEmpty ? "No log yet." : tailer.contents)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("logBottom")
                    }
                    .padding()
                }
                .onChange(of: tailer.contents) { _, _ in
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
        // Resizable (not a fixed frame) so the monospaced log reflows to the window width.
        .frame(minWidth: 380, idealWidth: 560, minHeight: 260, idealHeight: 380)
        .onChange(of: url, initial: true) { _, newURL in tailer.start(url: newURL) }
        .onDisappear { tailer.stop() }
    }
}

/// A log file's tail (256 KB cap — logs can get large).
private let logTailBytes = 256 * 1024

/// Watches a log file and republishes its tail whenever it's written — kqueue-based, no polling.
@MainActor
@Observable
final class LogTailer {
    private(set) var contents = ""
    private var watch: FileWatch?
    private var pendingTail: String?
    private var flushScheduled = false
    /// Invalidates in-flight `start` work: bumped by every `start`/`stop`, checked before a stale
    /// creation/read may arm a watch the caller already superseded.
    private var generation = 0

    /// Begin watching `url`. The file creation + initial tail read run OFF the main actor (the log can
    /// live on a slow or external volume); the watch arms once the first tail is published.
    func start(url: URL) {
        stop()
        generation &+= 1
        let expected = generation
        contents = ""
        Task.detached(priority: .userInitiated) { [weak self] in
            // Ensure the file exists so it can be watched — logs are created at launch, but the user may
            // open the viewer for a game that hasn't run yet.
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let tail = url.tailString(maxBytes: logTailBytes)
            await MainActor.run { [weak self] in
                guard let self, self.generation == expected else { return }   // superseded start/stop won
                self.contents = tail
                self.watch = FileWatch(url: url) {
                    let tail = url.tailString(maxBytes: logTailBytes)   // read off the main actor
                    Task { @MainActor [weak self] in self?.enqueue(tail) }
                }
            }
        }
    }

    /// Coalesce write bursts without a timer: a noisy launch can fire many kqueue events at once, but
    /// re-rendering the 256 KB monospaced log Text on every one would stall the main actor. Hold the latest
    /// tail and flush once on the next main-actor turn — every event that lands before the flush runs folds
    /// into a single publish. Purely event-driven; no sleep, no polling.
    private func enqueue(_ text: String) {
        pendingTail = text
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            if let tail = self.pendingTail, tail != self.contents { self.contents = tail }
            self.pendingTail = nil
        }
    }

    /// Whether the watch is armed (the async `start` completed) — observable seam for tests.
    var isWatching: Bool { watch != nil }

    /// Stops watching (also happens automatically when this tailer is deallocated, via `FileWatch`).
    func stop() { generation &+= 1; watch = nil; pendingTail = nil }
}
