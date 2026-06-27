import Foundation

/// Injects a backend's translation libraries into a prefix's `system32`.
///
/// For `.gptk` the source is the GPTK/D3DMetal library directory; for `.crossover` it's the DXVK DLL
/// directory. Only the **graphics translation DLLs** (`d3d*`, `dxgi*`) are linked — the GPTK source is
/// actually a wine PE-DLL tree, and the games run in the SHARED Steam bottle, so linking everything would
/// clobber the bottle's own (Steam-capable) wine DLLs. Each linked DLL replaces any existing entry so
/// re-linking is idempotent.
public struct GraphicsLinker: Sendable {
    public init() {}
    // Computed (not stored): FileManager isn't Sendable, but the shared instance is fine to use.
    private var fileManager: FileManager { .default }

    /// The DLLs we inject: GPTK's and DXVK's are all `d3d*`/`dxgi*` (D3DMetal.dll included via the `d3d`
    /// prefix). Anything else in the source dir is left alone so the shared bottle isn't disturbed.
    static func isGraphicsDLL(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasSuffix(".dll") && (n.hasPrefix("d3d") || n.hasPrefix("dxgi"))
    }

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
        for entry in entries where Self.isGraphicsDLL(entry.lastPathComponent) {
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
