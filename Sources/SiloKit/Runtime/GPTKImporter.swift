import Foundation

/// Imports Apple's Game Porting Toolkit from the `.dmg` the user downloads from Apple.
///
/// GPTK ships the D3D→Metal translation layer (D3DMetal.framework + d3d10/11/12.dll, dxgi.dll, …),
/// NOT a wine binary — so this populates `gptkLibDirPath`; the modules are later overlaid into the
/// wine runtime's `lib/wine` tree by `GraphicsLinker.overlayGPTK`. The wine binary itself comes from
/// CrossOver or a downloaded wine-crossover build.
///
/// GPTK 4.x nests the runtime in an inner "Evaluation environment…dmg"; older versions put `redist`
/// at the top level. Both are handled. `hdiutil` runs through the `ProcessRunning` seam.
public struct GPTKImporter: Sendable {
    private let runner: ProcessRunning
    private let paths: AppPaths

    public init(runner: ProcessRunning, paths: AppPaths) {
        self.runner = runner
        self.paths = paths
    }

    public enum Stage: Sendable, Equatable { case mountingOuter, mountingInner, copying, done }

    public enum ImportError: Error, Sendable, Equatable {
        case attachFailed(String)
        case nestedDMGNotFound
        case redistNotFound
    }

    /// Derive a versioned runtime name from the DMG filename
    /// (`Game_Porting_Toolkit_4.0_beta_1.dmg` → `GPTK-4.0_beta_1`).
    public static func runtimeName(forDMG dmg: URL) -> String {
        let base = dmg.deletingPathExtension().lastPathComponent
        let prefix = "Game_Porting_Toolkit_"
        if base.hasPrefix(prefix) { return "GPTK-\(base.dropFirst(prefix.count))" }
        return base
    }

    /// GPTK versions already extracted under the Runtimes dir (dirs with the D3DMetal lib layout).
    public func installed() -> [GPTKInstall] {
        let fileManager = FileManager.default
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: paths.runtimesDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return dirs.compactMap { dir in
            let libDir = dir.appendingPathComponent("lib/wine/x86_64-windows", isDirectory: true)
            let framework = dir.appendingPathComponent("lib/external/D3DMetal.framework", isDirectory: true)
            guard fileManager.fileExists(atPath: libDir.path),
                  fileManager.fileExists(atPath: framework.path),
                  // A real GPTK install is an overlay tree with NO wine binary. The wine runtime now ALSO
                  // carries lib/external/D3DMetal.framework (GraphicsLinker.overlayGPTK copies it in), so it
                  // would otherwise match here — distinguish the two by the presence of a wine binary.
                  !fileManager.fileExists(atPath: dir.appendingPathComponent("bin/wine64").path),
                  !fileManager.fileExists(atPath: dir.appendingPathComponent("bin/wine").path)
            else { return nil }
            return GPTKInstall(name: dir.lastPathComponent, installDir: dir,
                               gptkLibDir: libDir, d3dMetalFramework: framework)
        }.sorted { $0.name < $1.name }
    }

    public func remove(name: String) throws {
        let dir = paths.runtimesDir.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    @discardableResult
    public func importGPTK(
        fromDMG dmg: URL,
        name: String? = nil,
        progress: (@Sendable (Stage) -> Void)? = nil,
        onWarning: (@Sendable (String) -> Void)? = nil
    ) async throws -> GPTKInstall {
        let runtimeName = name ?? Self.runtimeName(forDMG: dmg)
        let fileManager = FileManager.default
        var mounted: [URL] = []
        do {
            progress?(.mountingOuter)
            let outer = try await attach(dmg)
            mounted.append(outer)

            // GPTK 4.x: redist lives inside a nested "Evaluation environment" dmg. Older: at top level.
            var evalMount = outer
            if !fileManager.fileExists(atPath: outer.appendingPathComponent("redist/lib").path) {
                let nested = try findNestedDMG(in: outer)
                progress?(.mountingInner)
                evalMount = try await attach(nested)
                mounted.append(evalMount)
            }

            let redistLib = evalMount.appendingPathComponent("redist/lib", isDirectory: true)
            guard fileManager.fileExists(atPath: redistLib.path) else { throw ImportError.redistNotFound }

            progress?(.copying)
            let installDir = paths.runtimesDir.appendingPathComponent(runtimeName, isDirectory: true)
            let destLib = installDir.appendingPathComponent("lib", isDirectory: true)

            // Copy + de-quarantine into a sibling STAGING dir first, then atomically swap it into the
            // final installDir only once everything succeeded. Otherwise a failure mid-copy could leave
            // a partial, de-quarantined tree that later passes `installed()` (a half-broken GPTK).
            try fileManager.createDirectory(at: paths.runtimesDir, withIntermediateDirectories: true)
            let staging = paths.runtimesDir
                .appendingPathComponent(".gptk-import-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: staging) }   // cleaned up on any failure or after move
            let stagingLib = staging.appendingPathComponent("lib", isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try fileManager.copyItem(at: redistLib, to: stagingLib)

            // Strip quarantine so the libs load (Apple's D3DMetal signature is preserved — we never
            // re-sign). A failure is non-fatal but worth a warning — Gatekeeper may refuse the libs later.
            let hardening = await deQuarantine(staging, using: runner)
            if let issue = hardening.issue(for: installDir) { onWarning?(issue) }

            // Atomic publish: replace any prior install only now that the staging tree is complete.
            if fileManager.fileExists(atPath: installDir.path) { try fileManager.removeItem(at: installDir) }
            try fileManager.moveItem(at: staging, to: installDir)

            await detachAll(mounted)
            progress?(.done)
            return GPTKInstall(
                name: runtimeName,
                installDir: installDir,
                gptkLibDir: destLib.appendingPathComponent("wine/x86_64-windows", isDirectory: true),
                d3dMetalFramework: destLib.appendingPathComponent("external/D3DMetal.framework", isDirectory: true))
        } catch {
            await detachAll(mounted)
            throw error
        }
    }

    // MARK: - hdiutil

    private func attach(_ dmg: URL) async throws -> URL {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["attach", "-nobrowse", "-readonly", "-plist", dmg.path],
            environment: [:], currentDirectory: nil)
        guard result.succeeded else { throw ImportError.attachFailed(result.stderrString) }
        guard let mount = Self.mountPoint(fromPlist: result.standardOutput) else {
            // Attached (hdiutil succeeded) but we couldn't parse a mount point — best-effort detach the raw
            // dev node so the image isn't leaked (the caller never receives a mount URL it could record and
            // detach in its cleanup path).
            if let dev = Self.devEntry(fromPlist: result.standardOutput) {
                _ = try? await runner.run(
                    executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                    arguments: ["detach", "-force", dev], environment: [:], currentDirectory: nil)
            }
            throw ImportError.attachFailed("no mount point in hdiutil output")
        }
        return mount
    }

    private func detachAll(_ mounts: [URL]) async {
        for mount in mounts.reversed() {
            _ = try? await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["detach", "-force", mount.path],
                environment: [:], currentDirectory: nil)
        }
    }

    private func findNestedDMG(in dir: URL) throws -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        let dmgs = entries.filter { $0.pathExtension.lowercased() == "dmg" }
        if let eval = dmgs.first(where: { $0.lastPathComponent.localizedCaseInsensitiveContains("Evaluation") }) {
            return eval
        }
        if let any = dmgs.first { return any }
        throw ImportError.nestedDMGNotFound
    }

    /// Parse the mount point out of `hdiutil attach -plist` output. Static for direct testing.
    static func mountPoint(fromPlist data: Data) -> URL? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]] else { return nil }
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
                return URL(fileURLWithPath: mountPoint)
            }
        }
        return nil
    }

    /// The first `dev-entry` (e.g. `/dev/disk4`) in `hdiutil attach -plist` output — the detach handle used
    /// to clean up an attach whose mount point couldn't be parsed. Static for direct testing.
    static func devEntry(fromPlist data: Data) -> String? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]] else { return nil }
        for entity in entities {
            if let dev = entity["dev-entry"] as? String, !dev.isEmpty { return dev }
        }
        return nil
    }
}
