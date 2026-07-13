import Foundation

/// Which phase of a component's provisioning the UI should narrate.
public enum ComponentPhase: Sendable { case downloading, installing }

/// Owns the background artifact downloads for ONE setup run.
///
/// The moment "Set up" is pressed, this kicks off every downloadable component's artifacts concurrently into a
/// fresh temp dir — so the slow ones (Source Han Sans, ~360 MB) overlap wineboot + the earlier install steps
/// instead of stalling their own step. `provisionComponents` awaits only the component it's about to install,
/// and narrates "Downloading …" for one whose download is still in flight when its step arrives.
///
/// No persistent cache: the temp dir is wiped at the start of every run (so a stale installer can never be
/// reused) and removed on `cleanup()`. Pinned artifacts (core fonts, d3dcompiler cabs) are SHA-256-verified
/// before use; a mismatch or all-mirror failure yields nil and that artifact is simply skipped (best-effort).
public final class SetupDownloads: Sendable {
    private let tempDir: URL
    /// Downloaded file per artifact id, filled as each download finishes (id → local file).
    private let files = LockedBox<[String: URL]>([:])
    /// Components whose whole download group has finished (so `isReady` can skip the "Downloading …" status).
    private let done = LockedBox<Set<BottleComponent>>([])
    /// One task per downloadable component — each downloads all its artifacts concurrently, then marks done.
    private let tasks: [BottleComponent: Task<Void, Never>]

    /// - Parameter skip: components already installed (from a prior run) — don't re-download them.
    public init(session: URLSession, tempDir: URL,
                coreFontDigests: [String: String], d3dCabDigests: [String: String],
                skip: Set<BottleComponent> = []) {
        self.tempDir = tempDir
        try? FileManager.default.removeItem(at: tempDir)              // fresh every run — never a stale installer
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let files = self.files, done = self.done
        // Each id → (candidate URLs, pinned SHA-256 or nil). Started in install order so the early steps'
        // artifacts win the network first, but all run concurrently (the big SHS set gets its head start too).
        func group(_ component: BottleComponent, _ items: [(id: String, urls: [URL], sha: String?)]) -> Task<Void, Never> {
            Task {
                await withTaskGroup(of: Void.self) { g in
                    for item in items {
                        g.addTask {
                            if let file = await SetupDownloads.download(item.urls, sha: item.sha, into: tempDir, session: session) {
                                files.mutate { $0[item.id] = file }
                            }
                        }
                    }
                }
                done.mutate { _ = $0.insert(component) }
            }
        }

        var t: [BottleComponent: Task<Void, Never>] = [:]
        if !skip.contains(.coreFonts) {
            t[.coreFonts] = group(.coreFonts, Silo.coreFonts.map { font in
                (id: font,
                 urls: [Silo.coreFontsBaseURL.appendingPathComponent("\(font).exe"),
                        Silo.coreFontsFallbackBaseURL.appendingPathComponent("\(font).exe")],
                 sha: coreFontDigests[font])
            })
        }
        if !skip.contains(.sourceHanSans) {
            t[.sourceHanSans] = group(.sourceHanSans, Silo.sourceHanSansPacks.map { pack in
                (id: pack, urls: [Silo.sourceHanSansBaseURL.appendingPathComponent("\(pack).zip")], sha: nil)
            })
        }
        if !skip.contains(.d3dcompiler47) {
            t[.d3dcompiler47] = group(.d3dcompiler47, [
                (id: Silo.d3dCompiler47X64Member, urls: [Silo.d3dCompiler47X64CabURL], sha: d3dCabDigests[Silo.d3dCompiler47X64Member]),
                (id: Silo.d3dCompiler47X86Member, urls: [Silo.d3dCompiler47X86CabURL], sha: d3dCabDigests[Silo.d3dCompiler47X86Member]),
            ])
        }
        if !skip.contains(.vcRedistX86) {
            t[.vcRedistX86] = group(.vcRedistX86, [(id: "vc-x86", urls: [Silo.vcRedistX86URL], sha: nil)])
        }
        if !skip.contains(.vcRedistX64) {
            t[.vcRedistX64] = group(.vcRedistX64, [(id: "vc-x64", urls: [Silo.vcRedistX64URL], sha: nil)])
        }
        tasks = t
    }

    /// Whether a component's whole download group has already finished (so the caller can skip "Downloading …").
    public func isReady(_ component: BottleComponent) -> Bool {
        tasks[component] == nil || done.value.contains(component)
    }

    /// Await a component's download group (returns immediately once it's finished).
    public func awaitComponent(_ component: BottleComponent) async { await tasks[component]?.value }

    // Typed accessors the install methods consume — each awaits its group, then returns whatever downloaded.
    public func coreFontFiles() async -> [String: URL] { await filesFor(.coreFonts, Silo.coreFonts) }
    public func sourceHanSansFiles() async -> [String: URL] { await filesFor(.sourceHanSans, Silo.sourceHanSansPacks) }
    public func d3dCabFiles() async -> [String: URL] {
        await filesFor(.d3dcompiler47, [Silo.d3dCompiler47X64Member, Silo.d3dCompiler47X86Member])
    }
    public func vcRedistFile(x86: Bool) async -> URL? {
        await awaitComponent(x86 ? .vcRedistX86 : .vcRedistX64)
        return files.value[x86 ? "vc-x86" : "vc-x64"]
    }

    /// Remove the temp download dir (nothing is kept between runs).
    public func cleanup() { try? FileManager.default.removeItem(at: tempDir) }

    private func filesFor(_ component: BottleComponent, _ ids: [String]) async -> [String: URL] {
        await awaitComponent(component)
        let snapshot = files.value
        return Dictionary(uniqueKeysWithValues: ids.compactMap { id in snapshot[id].map { (id, $0) } })
    }

    /// Download the first candidate URL that succeeds into `tempDir`, verify its SHA-256 if pinned, and return
    /// the local file — trying the next candidate (mirror) on failure/mismatch, nil if all fail.
    private static func download(_ urls: [URL], sha: String?, into tempDir: URL, session: URLSession) async -> URL? {
        let fm = FileManager.default
        for url in urls {
            let dest = tempDir.appendingPathComponent(url.lastPathComponent)
            guard (try? DownloadGuard.requireHTTPS(url)) != nil,
                  let (tmp, response) = try? await session.download(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
            try? fm.removeItem(at: dest)
            guard (try? fm.moveItem(at: tmp, to: dest)) != nil else { continue }
            if let sha, (try? FileDigest.sha256(ofFileAt: dest)) != sha {
                try? fm.removeItem(at: dest); continue        // tampered/corrupt → try the next mirror
            }
            return dest
        }
        return nil
    }
}
