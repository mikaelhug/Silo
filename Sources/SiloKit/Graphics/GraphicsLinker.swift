import Foundation

/// Injects a backend's translation libraries into a prefix's `system32`.
///
/// For `.gptk` the source is the GPTK/D3DMetal library directory; for `.crossover` it's the DXVK DLL
/// directory. Every file in the source is symlinked (default) or copied into `system32`, replacing
/// any existing entry so re-linking is idempotent.
public struct GraphicsLinker: Sendable {
    public init() {}
    // Computed (not stored): FileManager isn't Sendable, but the shared instance is fine to use.
    private var fileManager: FileManager { .default }

    public enum LinkMode: Sendable, Equatable { case symlink, copy }

    public enum LinkError: Error, Sendable, Equatable {
        case backendNotConfigured(GraphicsBackend)
        case sourceMissing(URL)
    }

    public func link(
        backend: GraphicsBackend,
        into prefix: URL,
        gptkLibDir: URL?,
        dxvkDLLDir: URL?,
        mode: LinkMode = .symlink
    ) throws {
        let source: URL? = switch backend {
        case .gptk: gptkLibDir
        case .crossover: dxvkDLLDir
        }
        guard let source else { throw LinkError.backendNotConfigured(backend) }
        guard fileManager.fileExists(atPath: source.path) else { throw LinkError.sourceMissing(source) }

        let layout = PrefixLayout(prefix: prefix)
        try fileManager.createDirectory(at: layout.system32, withIntermediateDirectories: true)

        let entries = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for entry in entries {
            let dest = layout.system32.appendingPathComponent(entry.lastPathComponent)
            if fileManager.fileExists(atPath: dest.path) || isSymlink(dest) {
                try fileManager.removeItem(at: dest)
            }
            switch mode {
            case .symlink: try fileManager.createSymbolicLink(at: dest, withDestinationURL: entry)
            case .copy: try fileManager.copyItem(at: entry, to: dest)
            }
        }
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
