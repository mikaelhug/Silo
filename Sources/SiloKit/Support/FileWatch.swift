import Foundation

/// A self-contained kqueue file-watcher: fires `onChange` whenever the file is written/extended, and tears
/// down its dispatch source + descriptor on deinit (so it's safe to own from a `@MainActor` type — drop the
/// reference and the watch stops). Purely event-driven — no polling, no timers. The handler runs on a
/// background queue; callers that touch the file read it there and hop to their actor with the result.
final class FileWatch {
    private let source: any DispatchSourceProtocol

    init?(url: URL, onChange: @escaping @Sendable () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: .global())
        src.setEventHandler { onChange() }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    deinit { source.cancel() }
}
