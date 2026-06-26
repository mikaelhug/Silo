import Foundation

/// Imports Apple's Game Porting Toolkit from the `.dmg` the user downloads from Apple.
///
/// GPTK ships the D3D→Metal translation layer (D3DMetal.framework + d3d10/11/12.dll, dxgi.dll, …),
/// NOT a wine binary — so this populates `gptkLibDirPath` (DLLs injected into game prefixes); the
/// wine binary itself comes from CrossOver or a downloaded wine-crossover build.
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

    public struct Result: Sendable, Equatable {
        public let runtimeName: String
        public let installDir: URL
        /// DLL directory to inject into a game prefix's system32 (`BackendConfig.gptkLibDirPath`).
        public let gptkLibDir: URL
        public let d3dMetalFramework: URL
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
                  fileManager.fileExists(atPath: framework.path) else { return nil }
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
        progress: (@Sendable (Stage) -> Void)? = nil
    ) async throws -> Result {
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
            try fileManager.createDirectory(at: installDir, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destLib.path) { try fileManager.removeItem(at: destLib) }
            try fileManager.copyItem(at: redistLib, to: destLib)

            await detachAll(mounted)
            progress?(.done)
            return Result(
                runtimeName: runtimeName,
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
}
