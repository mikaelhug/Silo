import Foundation

/// The shared "Steam bottle": one Wine prefix that hosts a logged-in **Windows Steam client** plus the
/// games that run co-resident with it. This is the post-revert model for Steamworks/DRM games —
/// Steamworks IPC is prefix-scoped, so the game and its Steam client must share a prefix.
///
/// Flow: `provision` (wineboot) → `installSteam` (silent SteamSetup.exe) → `launchSteam` → the user signs
/// in once (Steam caches it) → launch games in the same prefix. All process execution goes through the
/// `ProcessRunning` seam, so the orchestration unit-tests with no Wine/Steam present; the runtime
/// behaviour is validated on a real Mac.
public struct SteamBottle: Sendable {
    private let runner: ProcessRunning
    private let session: URLSession
    private let paths: AppPaths
    // Computed (not stored): FileManager isn't Sendable, but the shared instance is fine to use.
    private var fileManager: FileManager { .default }

    public init(runner: ProcessRunning, session: URLSession = .shared, paths: AppPaths) {
        self.runner = runner
        self.session = session
        self.paths = paths
    }

    // The bottle's paths.
    private var prefixDir: URL { paths.steamBottle }
    private var clientDir: URL { paths.steamBottleClientDir }
    private var exe: URL { paths.steamBottleExe }
    private var cefDir: URL { paths.steamBottleCEFDir }
    private var log: URL { paths.steamBottleLog }

    public enum BottleError: Error, Sendable, Equatable {
        case wineNotConfigured
        case winebootFailed(Int32)
        case installerDownloadFailed(Int)
        case steamInstallFailed(Int32)
    }

    /// The bottle's Wine prefix.
    public var prefix: URL { prefixDir }

    /// Steam is installed in the bottle once `steam.exe` exists.
    public var isSteamInstalled: Bool { fileManager.fileExists(atPath: exe.path) }

    /// Whether this bottle's root volume is currently mounted — a relocated external drive can be ejected.
    /// Guards setup from creating a PHANTOM bottle on the boot disk at the now-missing `/Volumes/...` path.
    public var isRootReachable: Bool { paths.bottlesRootReachable }

    /// The FULL client is downloaded: `steamui.dll` AND a CEF `steamwebhelper.exe` (the login UI) both
    /// present. A fresh bootstrapper has neither; the first-run self-update brings both. NB: Steam extracts
    /// these files WHILE the update is still downloading, so their presence alone is NOT "the update is
    /// done" — the warm-up ALSO waits for `updateState().committed` before shutting Steam down, or the
    /// incomplete update rolls back.
    var isClientFullyDownloaded: Bool {
        Self.hasWarmedClient(paths: paths, fileManager: fileManager)
    }

    /// Whether the bottle has a WARMED Steam client on disk — steamui.dll AND a CEF steamwebhelper.exe —
    /// not just the ~2 MB bootstrapper (`steam.exe`). Pure path checks (no process/instance state), so the
    /// library can probe it OFF-MAIN without constructing a `SteamBottle`. A failed/interrupted first-run
    /// warm-up leaves only the bootstrapper, which must NOT read as "installed/ready" (else onboarding shows
    /// the step "Done" over a non-functional bottle).
    static func hasWarmedClient(paths: AppPaths, fileManager: FileManager = .default) -> Bool {
        let client = paths.steamBottleClientDir
        guard fileManager.fileExists(atPath: client.appendingPathComponent("steamui.dll").path) else { return false }
        let cef = paths.steamBottleCEFDir
        let dirs = (try? fileManager.contentsOfDirectory(at: cef, includingPropertiesForKeys: nil)) ?? []
        return dirs.contains { fileManager.fileExists(atPath: $0.appendingPathComponent("steamwebhelper.exe").path) }
    }

    /// Steam's updater state parsed from its log in ONE read: the latest download progress (for a real %)
    /// and whether the update has COMMITTED. Steam logs `Update complete` only after downloading,
    /// extracting, and committing the NTFS transaction (verified in a real run) — that's the definitive
    /// "the client is installed" signal the warm-up waits for before shutting Steam down; interrupting any
    /// EARLIER rolls the half-applied update all the way back. Reads the WHOLE log (not a tail): Wine spams
    /// thousands of `msync_init Failed` lines that would push the progress lines out of any fixed window.
    /// Truncate the bottle's Steam log. The warm-up calls this before its first launch so `updateState()`'s
    /// `committed` reflects only THIS run — the log lives outside the client dir and persists across setups,
    /// so a stale `Update complete` from a prior run would otherwise fire the warm-up's completion instantly.
    func resetLog() {
        try? Data().write(to: log)
    }

    func updateState() -> (progress: (done: Int, total: Int)?, committed: Bool) {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return (nil, false) }
        let committed = text.contains("Update complete")
        for line in text.split(separator: "\n").reversed() where line.contains("Downloading update (") {
            guard let open = line.range(of: "("),
                  let ofR = line.range(of: " of ", range: open.upperBound..<line.endIndex),
                  let kbR = line.range(of: " KB", range: ofR.upperBound..<line.endIndex) else { continue }
            let done = Int(line[open.upperBound..<ofR.lowerBound].filter(\.isNumber))
            let total = Int(line[ofR.upperBound..<kbR.lowerBound].filter(\.isNumber))
            if let done, let total, total > 0 { return ((done, total), committed) }
        }
        return (nil, committed)
    }

    // MARK: - Provision + install

    /// Boot the bottle prefix (idempotent). Delegates to the shared `WinePrefixProvisioner`, re-mapping its
    /// errors to `BottleError` so callers keep one error domain.
    public func provision(wine: URL?) async throws {
        do {
            try await WinePrefixProvisioner(runner: runner).provision(prefix: prefixDir, wine: wine)
        } catch WinePrefixProvisioner.ProvisionError.wineNotConfigured {
            throw BottleError.wineNotConfigured
        } catch WinePrefixProvisioner.ProvisionError.winebootFailed(let code) {
            throw BottleError.winebootFailed(code)
        }
    }

    /// Provision the bottle and run a SILENT Windows Steam install into it (idempotent — no-op if Steam is
    /// already present). A convenience wrapper over `downloadSteamInstaller` + `runSteamInstaller` for the
    /// silent path (the CLI + tests); the interactive onboarding flow drives those two directly (user-guided)
    /// with provision as its own separate step.
    public func installSteam(wine: URL?) async throws {
        guard let wine else { throw BottleError.wineNotConfigured }
        if isSteamInstalled { return }
        try await provision(wine: wine)
        try await runSteamInstaller(wine: wine, userGuided: false)
    }

    /// Run the (already-provisioned) Steam installer, downloading it first if needed. `userGuided: false`
    /// runs it silently (`/S`); `true` runs the interactive GUI (no `/S`) and BLOCKS until the user finishes
    /// the window (`ProcessRunning.run` waits for exit). Idempotent via `isSteamInstalled`. Drops the cached
    /// installer on success (kept on failure so a retry resumes without re-download).
    func runSteamInstaller(wine: URL?, userGuided: Bool) async throws {
        guard let wine else { throw BottleError.wineNotConfigured }
        if isSteamInstalled { return }
        let installer = try await downloadSteamInstaller()
        let args = userGuided ? [installer.path] : [installer.path, "/S"]
        let result = try await runner.run(
            executable: wine, arguments: args,
            environment: Silo.msyncWineEnvironment(prefix: prefixDir, wine: wine),
            currentDirectory: prefixDir)
        guard result.succeeded else { throw BottleError.steamInstallFailed(result.exitCode) }
        try? fileManager.removeItem(at: installer)
    }

    /// Whether the bottle already has Microsoft core fonts (checks a marker font). Wine installs none, so a
    /// fresh bottle is missing them.
    var hasCoreFonts: Bool {
        fileManager.fileExists(atPath:
            prefixDir.appendingPathComponent("drive_c/windows/Fonts/Arial.TTF").path)
    }

    /// Install Microsoft's core web fonts into the bottle (idempotent). Wine ships no TrueType MS fonts, so
    /// Steam's UI + many games render text with wrong/blank glyphs; this closes that gap. Each font ships as
    /// a self-extracting IExpress installer wrapping the Microsoft EULA. Installed in the FIXED order of
    /// `Silo.coreFonts` so "the first font" is deterministic: the FIRST font (Andale Mono) runs its installer
    /// **user-guided** (no flags) so the user sees + accepts the "core fonts for the Web" EULA once (blocks
    /// until closed); the rest extract silently (`/T /C /Q`) and are copied into `windows/Fonts`. Best-effort
    /// per font: a failed download/extract is skipped, never aborting setup.
    func installCoreFonts(wine: URL?) async throws {
        guard let wine else { throw BottleError.wineNotConfigured }
        let driveC = prefixDir.appendingPathComponent("drive_c")
        let fontsDir = driveC.appendingPathComponent("windows/Fonts")
        if hasCoreFonts { return }
        try fileManager.createDirectory(at: fontsDir, withIntermediateDirectories: true)

        // Download all installers CONCURRENTLY (independent ~500 KB files); each falls back to the winetricks
        // GitHub mirror when SourceForge's flaky redirector fails.
        let session = self.session
        let downloaded: [String: URL] = await withTaskGroup(of: (font: String, exe: URL)?.self) { group in
            for font in Silo.coreFonts {
                let exe = driveC.appendingPathComponent("\(font).exe")
                group.addTask {
                    let fm = FileManager.default
                    for base in [Silo.coreFontsBaseURL, Silo.coreFontsFallbackBaseURL] {
                        let url = base.appendingPathComponent("\(font).exe")
                        guard (try? DownloadGuard.requireHTTPS(url)) != nil,
                              let (tempFile, response) = try? await session.download(from: url),
                              let http = response as? HTTPURLResponse,
                              (200..<300).contains(http.statusCode) else { continue }
                        try? fm.removeItem(at: exe)
                        guard (try? fm.moveItem(at: tempFile, to: exe)) != nil else { continue }
                        return (font: font, exe: exe)
                    }
                    return nil
                }
            }
            var result: [String: URL] = [:]
            for await item in group { if let item { result[item.font] = item.exe } }
            return result
        }

        // Install sequentially in fixed order. The msync env attaches each run to the bottle's ONE wineserver
        // (Silo.enforceMsync), so this can safely share the prefix with a running Steam.
        let extractDir = driveC.appendingPathComponent("silo-fonts")
        defer { try? fileManager.removeItem(at: extractDir) }
        for (index, font) in Silo.coreFonts.enumerated() {
            guard let exe = downloaded[font] else { continue }
            if index == 0 {
                // User-guided: the installer shows its EULA and installs the font itself on accept (blocks).
                _ = try? await runner.run(
                    executable: wine, arguments: ["C:\\\(font).exe"],
                    environment: Silo.msyncWineEnvironment(prefix: prefixDir, wine: wine),
                    currentDirectory: prefixDir)
            } else {
                // IExpress extract-only (`/T:<dir> /C /Q`): drops the .ttf into the target with no GUI.
                try? fileManager.removeItem(at: extractDir)
                try? fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)
                _ = try? await runner.run(
                    executable: wine, arguments: ["C:\\\(font).exe", "/T:C:\\silo-fonts", "/C", "/Q"],
                    environment: Silo.msyncWineEnvironment(prefix: prefixDir, wine: wine),
                    currentDirectory: prefixDir)
                let extracted = (try? fileManager.contentsOfDirectory(
                    at: extractDir, includingPropertiesForKeys: nil)) ?? []
                for file in extracted where file.pathExtension.lowercased() == "ttf" {
                    let dest = fontsDir.appendingPathComponent(file.lastPathComponent)
                    try? fileManager.removeItem(at: dest)
                    try? fileManager.copyItem(at: file, to: dest)
                }
            }
            try? fileManager.removeItem(at: exe)
        }
    }

    // MARK: - CrossOver-parity components (Asian fonts, d3dcompiler_47, MSVC redist)

    /// Silo-owned marker dir (sibling of `drive_c`, ignored by Wine) recording which components are
    /// installed. Used where a filesystem check is unreliable — Wine's `wineboot` drops a builtin/fakedll
    /// `msvcp140.dll` stub, so the real MSVC redist can't be detected by the DLL's presence — and where
    /// resumability matters (the ~360 MB Source Han Sans packs).
    private var markerDir: URL { prefixDir.appendingPathComponent(".silo-installed", isDirectory: true) }

    /// A DLL is the REAL Microsoft one (not a tiny Wine fakedll stub) if it's at least `minBytes`. `wineboot`
    /// pre-populates system32/syswow64 with placeholder DLLs for every builtin (incl. d3dcompiler_47), so a
    /// plain existence check would wrongly report the component installed and skip the real install.
    private func isRealDLL(_ path: URL, minBytes: Int) -> Bool {
        guard let size = (try? fileManager.attributesOfItem(atPath: path.path)[.size]) as? Int else { return false }
        return size >= minBytes
    }

    /// Whether all four Adobe Source Han Sans language packs are installed (per-pack markers present).
    var hasSourceHanSans: Bool {
        Silo.sourceHanSansPacks.allSatisfy {
            fileManager.fileExists(atPath: markerDir.appendingPathComponent($0).path)
        }
    }

    /// Install the four Adobe Source Han Sans language packs (J/K/SC/TC) into the bottle (idempotent, no
    /// wine, no EULA — OFL). Downloads the pending packs' ZIPs, extracts each with bsdtar, and copies every
    /// `.otf` into `windows/Fonts` (Wine auto-registers dropped fonts). Best-effort per pack; a per-pack
    /// marker makes the ~360 MB set resumable.
    func installSourceHanSans() async throws {
        if hasSourceHanSans { return }
        let driveC = prefixDir.appendingPathComponent("drive_c")
        let fontsDir = driveC.appendingPathComponent("windows/Fonts")
        try fileManager.createDirectory(at: fontsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: markerDir, withIntermediateDirectories: true)

        let pending = Silo.sourceHanSansPacks.filter {
            !fileManager.fileExists(atPath: markerDir.appendingPathComponent($0).path)
        }
        // Download the pending packs concurrently (each ~90 MB, independent).
        let session = self.session
        let downloaded: [String: URL] = await withTaskGroup(of: (pack: String, zip: URL)?.self) { group in
            for pack in pending {
                let zip = driveC.appendingPathComponent("\(pack).zip")
                group.addTask {
                    let fm = FileManager.default
                    let url = Silo.sourceHanSansBaseURL.appendingPathComponent("\(pack).zip")
                    guard (try? DownloadGuard.requireHTTPS(url)) != nil,
                          let (tempFile, response) = try? await session.download(from: url),
                          let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else { return nil }
                    try? fm.removeItem(at: zip)
                    guard (try? fm.moveItem(at: tempFile, to: zip)) != nil else { return nil }
                    return (pack: pack, zip: zip)
                }
            }
            var result: [String: URL] = [:]
            for await item in group { if let item { result[item.pack] = item.zip } }
            return result
        }

        // Extract + copy sequentially, in the fixed pack order, marking each on success.
        let extractDir = driveC.appendingPathComponent("silo-shs")
        defer { try? fileManager.removeItem(at: extractDir) }
        for pack in pending {
            guard let zip = downloaded[pack] else { continue }
            try? fileManager.removeItem(at: extractDir)
            try? fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)
            let result = try? await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xf", zip.path, "-C", extractDir.path],
                environment: [:], currentDirectory: nil)
            try? fileManager.removeItem(at: zip)
            guard result?.succeeded == true else { continue }
            // Copy every .otf (searched recursively) into Fonts.
            for rel in (try? fileManager.subpathsOfDirectory(atPath: extractDir.path)) ?? []
            where rel.lowercased().hasSuffix(".otf") {
                let src = extractDir.appendingPathComponent(rel)
                let dest = fontsDir.appendingPathComponent((rel as NSString).lastPathComponent)
                try? fileManager.removeItem(at: dest)
                try? fileManager.copyItem(at: src, to: dest)
            }
            fileManager.createFile(atPath: markerDir.appendingPathComponent(pack).path, contents: Data())
        }
    }

    /// Whether the REAL native `d3dcompiler_47.dll` is present in BOTH `system32` (64-bit) and `syswow64`
    /// (32-bit). Size-gated: a fresh prefix has Wine's ~KB fakedll stub there; the real Microsoft DLL is
    /// multi-MB — so a plain existence check would wrongly skip the install.
    var hasD3DCompiler47: Bool {
        let driveC = prefixDir.appendingPathComponent("drive_c")
        return isRealDLL(driveC.appendingPathComponent("windows/system32/d3dcompiler_47.dll"), minBytes: 500_000)
            && isRealDLL(driveC.appendingPathComponent("windows/syswow64/d3dcompiler_47.dll"), minBytes: 500_000)
    }

    /// Install the native `d3dcompiler_47.dll` (HLSL shader compiler) for both ABIs (idempotent, no EULA).
    /// Extracts the DLL from Microsoft's own Windows-SDK cabinet files via Wine's builtin `expand` (no
    /// cabextract dependency): 64-bit → `system32`, 32-bit → `syswow64`. No DLL override is set — matching
    /// CrossOver's Steam bottle (the native file is present, no override). Best-effort per ABI.
    func installD3DCompiler47(wine: URL?) async throws {
        guard let wine else { throw BottleError.wineNotConfigured }
        if hasD3DCompiler47 { return }
        let driveC = prefixDir.appendingPathComponent("drive_c")
        try? fileManager.createDirectory(at: driveC, withIntermediateDirectories: true)
        // (url, member, unix dest dir, windows dest dir)
        let targets: [(url: URL, member: String, unixDir: String, winDir: String)] = [
            (Silo.d3dCompiler47X64CabURL, Silo.d3dCompiler47X64Member, "windows/system32", "windows\\system32"),
            (Silo.d3dCompiler47X86CabURL, Silo.d3dCompiler47X86Member, "windows/syswow64", "windows\\syswow64"),
        ]
        for (url, member, unixDir, winDir) in targets {
            let cab = driveC.appendingPathComponent("\(member).cab")
            guard (try? DownloadGuard.requireHTTPS(url)) != nil,
                  let (tempFile, response) = try? await session.download(from: url),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
            try? fileManager.removeItem(at: cab)
            guard (try? fileManager.moveItem(at: tempFile, to: cab)) != nil else { continue }
            let destDir = driveC.appendingPathComponent(unixDir)
            try? fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
            // `wine expand <cab> -F:<member> C:\windows\<dir>` extracts the single member (named `member`)
            // into the dir; then rename it to the canonical `d3dcompiler_47.dll`.
            _ = try? await runner.run(
                executable: wine, arguments: ["expand", "C:\\\(member).cab", "-F:\(member)", "C:\\\(winDir)"],
                environment: Silo.msyncWineEnvironment(prefix: prefixDir, wine: wine),
                currentDirectory: prefixDir)
            let extracted = destDir.appendingPathComponent(member)
            let finalDLL = destDir.appendingPathComponent("d3dcompiler_47.dll")
            try? fileManager.removeItem(at: finalDLL)
            try? fileManager.moveItem(at: extracted, to: finalDLL)
            try? fileManager.removeItem(at: cab)
        }
        // No DLL override — matching CrossOver's Steam bottle, which keeps the native d3dcompiler_47.dll in
        // system32/syswow64 but sets no override (relies on the file + Wine's load order, same as Silo's Wine).
    }

    /// Marker file recording a completed MSVC-redist install for `x86` (else x64).
    private func vcRedistMarker(x86: Bool) -> URL {
        markerDir.appendingPathComponent("vcredist-\(x86 ? "x86" : "x64")")
    }

    /// Whether the MSVC redistributable for `x86` (else x64) is installed — tracked by a **Silo marker**
    /// written after a successful install. NOT keyed on `msvcp140.dll` presence: Wine ships a builtin/fakedll
    /// `msvcp140.dll`, so a fresh prefix looks "installed" and the real user-guided redist would never run
    /// (the on-device symptom that motivated this).
    func isVCRedistInstalled(x86: Bool) -> Bool {
        fileManager.fileExists(atPath: vcRedistMarker(x86: x86).path)
    }

    /// Install the Microsoft Visual C++ 2015–2022 Redistributable (`x86` else x64) into the bottle,
    /// **user-guided** (idempotent). Downloads the official `aka.ms` bootstrapper and runs it with NO
    /// `/quiet` flag, so it shows its license (the user accepts) and installs — `ProcessRunning.run` BLOCKS
    /// until the window closes. Marks it done only on a success exit code (0 = ok, 3010 = ok + reboot,
    /// 1638 = a newer version already present); a user cancel (1602) or error leaves it UNMARKED so the next
    /// setup re-prompts. Best-effort otherwise.
    func installVCRedist(x86: Bool, wine: URL?) async throws {
        guard let wine else { throw BottleError.wineNotConfigured }
        if isVCRedistInstalled(x86: x86) { return }
        let url = x86 ? Silo.vcRedistX86URL : Silo.vcRedistX64URL
        let driveC = prefixDir.appendingPathComponent("drive_c")
        try? fileManager.createDirectory(at: driveC, withIntermediateDirectories: true)
        let installer = driveC.appendingPathComponent("vc_redist.\(x86 ? "x86" : "x64").exe")
        guard (try? DownloadGuard.requireHTTPS(url)) != nil,
              let (tempFile, response) = try? await session.download(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
        try? fileManager.removeItem(at: installer)
        guard (try? fileManager.moveItem(at: tempFile, to: installer)) != nil else { return }
        // User-guided: no `/install /quiet /norestart` → the bootstrapper shows the license + Install button.
        let result = try? await runner.run(
            executable: wine, arguments: [installer.path],
            environment: Silo.msyncWineEnvironment(prefix: prefixDir, wine: wine),
            currentDirectory: prefixDir)
        try? fileManager.removeItem(at: installer)
        if let code = result?.exitCode, [0, 3010, 1638].contains(code) {
            try? fileManager.createDirectory(at: markerDir, withIntermediateDirectories: true)
            fileManager.createFile(atPath: vcRedistMarker(x86: x86).path, contents: Data())
        }
    }

    // MARK: - CrossOver-parity Wine defaults (DllOverrides)

    /// Silo marker recording that CrossOver's default DLL overrides were applied to the bottle.
    private var wineDefaultsMarker: URL { markerDir.appendingPathComponent("wine-defaults") }

    /// Whether CrossOver's default `DllOverrides` set has been applied to the bottle.
    var hasWineDefaults: Bool { fileManager.fileExists(atPath: wineDefaultsMarker.path) }

    /// Apply CrossOver's default `HKCU\Software\Wine\DllOverrides` set to the bottle (idempotent, best-effort)
    /// so its Libraries configuration matches a CrossOver bottle and games behave the same. Emits a single
    /// `.reg` file and imports it with ONE `wine regedit /S` call (far cheaper than ~58 `reg add`s). Marks
    /// success so it's a no-op on re-run.
    func applyWineDefaults(wine: URL?) async {
        guard let wine, !hasWineDefaults else { return }
        let driveC = prefixDir.appendingPathComponent("drive_c")
        try? fileManager.createDirectory(at: driveC, withIntermediateDirectories: true)
        // REGEDIT4 (ANSI) — the override names/modes contain no backslashes, so no escaping is needed.
        var reg = "REGEDIT4\r\n\r\n[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\r\n"
        for (name, mode) in Silo.crossOverDllOverrides {
            reg += "\"\(name)\"=\"\(mode)\"\r\n"
        }
        let regFile = driveC.appendingPathComponent("silo-overrides.reg")
        guard (try? reg.write(to: regFile, atomically: true, encoding: .utf8)) != nil else { return }
        let result = try? await runner.run(
            executable: wine, arguments: ["regedit", "/S", "C:\\silo-overrides.reg"],
            environment: Silo.msyncWineEnvironment(prefix: prefixDir, wine: wine),
            currentDirectory: prefixDir)
        try? fileManager.removeItem(at: regFile)
        guard result?.succeeded == true else { return }
        try? fileManager.createDirectory(at: markerDir, withIntermediateDirectories: true)
        fileManager.createFile(atPath: wineDefaultsMarker.path, contents: Data())
    }

    // MARK: - Ordered component provisioning

    /// Whether a component is already satisfied (installed, or a no-op like msync) — so `provisionComponents`
    /// can skip it (resumable/idempotent setup).
    func isSatisfied(_ component: BottleComponent) -> Bool {
        switch component {
        case .coreFonts:     hasCoreFonts
        case .sourceHanSans: hasSourceHanSans
        case .d3dcompiler47: hasD3DCompiler47
        case .vcRedistX86:   isVCRedistInstalled(x86: true)
        case .vcRedistX64:   isVCRedistInstalled(x86: false)
        case .msync:         true                    // launch-time env var (WINEMSYNC=1) — always satisfied
        case .steamClient:   isSteamInstalled
        }
    }

    private func install(_ component: BottleComponent, wine: URL) async throws {
        switch component {
        case .coreFonts:     try await installCoreFonts(wine: wine)
        case .sourceHanSans: try await installSourceHanSans()
        case .d3dcompiler47: try await installD3DCompiler47(wine: wine)
        case .vcRedistX86:   try await installVCRedist(x86: true, wine: wine)
        case .vcRedistX64:   try await installVCRedist(x86: false, wine: wine)
        case .msync:         break                   // env-only; nothing to install
        case .steamClient:   try await runSteamInstaller(wine: wine, userGuided: true)
        }
    }

    /// Install the CrossOver-parity component set into the (already-booted) bottle, in `BottleComponent`'s
    /// fixed declared order: Core Fonts → Source Han Sans → d3dcompiler_47 → MSVC x86 → MSVC x64 → msync →
    /// Steam. Satisfied components are skipped (resumable). `onPhase` fires before each component installs
    /// (so the UI can narrate the user-guided steps). Best-effort per component — a failed font/redist is
    /// skipped — EXCEPT the terminal `.steamClient`, whose failure is fatal (mirrors `installSteam`).
    func provisionComponents(
        wine: URL, onPhase: @escaping @MainActor @Sendable (BottleComponent) -> Void
    ) async throws {
        for component in BottleComponent.allCases {
            if isSatisfied(component) { continue }
            await onPhase(component)
            do {
                try await install(component, wine: wine)
            } catch {
                if component == .steamClient { throw error }
            }
        }
    }

    // MARK: - steamwebhelper wrapper

    /// Forget any cached Steam login in the bottle so the next launch shows a FRESH login. Removes
    /// `loginusers.vdf` (the auto-login account list) and Steam Guard machine tokens (`ssfn*`). Necessary
    /// because a stale/seeded login auto-retries and fails ("Received logon failure response") forever,
    /// masking a clean login. Idempotent; safe if Steam isn't installed.
    public func resetLogin() throws {
        let client = clientDir
        let loginUsers = client.appendingPathComponent("config/loginusers.vdf")
        if fileManager.fileExists(atPath: loginUsers.path) { try fileManager.removeItem(at: loginUsers) }
        let entries = (try? fileManager.contentsOfDirectory(at: client, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix("ssfn") {
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Replace the bottle's `steamwebhelper.exe` with Silo's CEF wrapper so the UI paints. Idempotent and
    /// safe to call before every launch: handles a fresh install, a Steam update that restored the stock
    /// binary, AND a wrapper-VERSION change (e.g. new CEF flags) without corrupting the preserved original.
    /// No-op if the wine runtime doesn't ship the wrapper (older build) or Steam isn't installed yet.
    public func installWebHelperWrapper(wine: URL) throws {
        let wrapper = WineRuntimeLayout(wineBinary: wine).wrapperExe
        guard fileManager.fileExists(atPath: wrapper.path) else { return }
        // Wrap EVERY CEF dir's webhelper, not just one: a Steam update can add a new dir (e.g. cef.win64)
        // alongside the old (cef.win7x64) and switch to it, stranding a single-dir wrapper in the unused
        // one while Steam runs the unwrapped binary → black window.
        for helper in webHelpers() {
            if fileManager.contentsEqual(atPath: helper.path, andPath: wrapper.path) { continue }   // already wrapped
            let dir = helper.deletingLastPathComponent()
            let real = dir.appendingPathComponent("steamwebhelper_orig.exe")
            // Stage the wrapper copy FIRST, then swap it in with renames only — so a copy failure (the one
            // step doing real byte I/O) disturbs nothing, and we can never strand the CEF dir with the real
            // webhelper preserved as `…_orig.exe` but no `steamwebhelper.exe` in place (→ black login, no
            // self-heal, since `webHelpers()` then skips the dir).
            let staged = dir.appendingPathComponent("steamwebhelper_wrap.tmp")
            if fileManager.fileExists(atPath: staged.path) { try fileManager.removeItem(at: staged) }
            try fileManager.copyItem(at: wrapper, to: staged)
            do {
                if fileManager.fileExists(atPath: real.path) {
                    // Real webhelper already preserved; `helper` is a STALE wrapper — replace just it, so we
                    // never move a wrapper over the genuine `…_orig.exe`.
                    try fileManager.removeItem(at: helper)
                } else {
                    // `helper` is the real webhelper (fresh install or a Steam update): preserve it once.
                    try fileManager.moveItem(at: helper, to: real)
                }
                try fileManager.moveItem(at: staged, to: helper)   // atomic publish (same-dir rename)
            } catch {
                try? fileManager.removeItem(at: staged)
                throw error
            }
        }
    }

    /// Every `steamwebhelper.exe` across the bottle's CEF dirs. The leaf name is Steam-version-dependent
    /// (`cef.win64`, `cef.win7x64`, …) and a Steam UPDATE can add a new dir alongside the old one, so we
    /// wrap them ALL — otherwise the wrapper can sit in an orphaned dir while Steam runs the unwrapped one.
    func webHelpers() -> [URL] {
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: cefDir, includingPropertiesForKeys: nil) else { return [] }
        return dirs
            .map { $0.appendingPathComponent("steamwebhelper.exe") }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    // MARK: - Launch

    /// `steam.exe` flags that route its CEF UI onto software rendering so it paints under Wine (without
    /// them it's a black window). This is the **verified** Vineport set (MelonForAll/vineport, working on
    /// Apple-Silicon macOS 2026): `-cef-in-process-gpu` folds the GPU into the browser process (NOT
    /// `--single-process`, which also breaks Chromium's network service → login Transport Error), the
    /// `-cef-disable-*` flags force software GL, and `-noverifyfiles -norepairfiles` skip Steam's slow
    /// self-repair. The real software-GL switch (`--use-gl=swiftshader`) is injected via the wrapper +
    /// `STEAM_CEF_COMMAND_LINE` (see `steamEnvironment`), since no steam.exe flag carries it.
    public static let cefRenderArgs = [
        "-cef-disable-gpu", "-cef-disable-gpu-compositing", "-cef-in-process-gpu",
        "-cef-disable-sandbox", "-no-cef-sandbox", "-noverifyfiles", "-norepairfiles",
    ]

    /// Wine virtual-desktop geometry for the Steam client. On CrossOver's `winemac.drv`, the virtual-desktop
    /// ROOT window presents reliably, whereas a rootless CEF surface (SwiftShader-rendered but composited as
    /// a layered/child window) does NOT paint — it stays black even though rendering succeeds. So Steam is
    /// launched inside `explorer /desktop=` to get a presentable window. (Vineport runs rootless because
    /// Gcenx's winemac.drv handles it; CrossOver's doesn't.) Games still launch rootless under GPTK.
    public static let desktopGeometry = "1440x900"

    /// Launch the bottle's Steam client detached, inside a Wine virtual desktop (so CEF presents on
    /// CrossOver — see `desktopGeometry`), with the verified software-GL CEF flags + env.
    @discardableResult
    public func launchSteam(wine: URL?) async throws -> Int32 {
        guard let wine else { throw BottleError.wineNotConfigured }
        let args = ["explorer", "/desktop=Silo,\(Self.desktopGeometry)", exe.path]
            + Self.cefRenderArgs
        return try await runner.spawnDetached(
            executable: wine, arguments: args,
            environment: steamEnvironment(wine: wine),
            currentDirectory: clientDir, logURL: log)
    }

    /// Launch Steam for a one-time first-run self-update, ROOTLESS (no `explorer /desktop`) so no window is
    /// presented in the user's face during setup. TWO deliberate flag choices (both verified on-device):
    /// - **No `-silent`**: it starts Steam minimized and skips the interactive first-run bootstrap, so the
    ///   client never downloads (the bootstrapper just idles).
    /// - **No `-noverifyfiles`/`-norepairfiles`**: on a fresh bootstrapper those skip the verification that
    ///   detects the missing client and triggers the download — Steam then tries to load the not-yet-present
    ///   UI and pops the "failed to load steamui.dll" FATAL dialog before quitting. Dropping them lets Steam
    ///   verify → download → repair → install in ONE clean launch, no dialog.
    /// The download needs no window; Steam still registers its `ActiveProcess` pid regardless.
    @discardableResult
    func launchForUpdate(wine: URL?) async throws -> Int32 {
        guard let wine else { throw BottleError.wineNotConfigured }
        let args = [exe.path] + Self.cefRenderArgs.filter { $0 != "-noverifyfiles" && $0 != "-norepairfiles" }
        return try await runner.spawnDetached(
            executable: wine, arguments: args,
            environment: steamEnvironment(wine: wine),
            currentDirectory: clientDir, logURL: log)
    }

    /// Force-kill every Steam process in this bottle (`wine taskkill /F` on steamwebhelper.exe + steam.exe).
    /// Used to stop the warm-up's brought-up client: it re-execs a client Silo didn't spawn and its
    /// webhelpers hold `cef.win64/steamwebhelper.exe` open, so a graceful `-shutdown` can't reliably free
    /// the files for the wrap (verified — `-shutdown` left 7 processes alive). taskkill by image name kills
    /// them all. Runs with the bottle's msync env so it attaches to the same wineserver.
    func forceQuit(wine: URL?) async {
        guard let wine else { return }
        for image in Self.steamProcessImages {
            _ = try? await runner.run(
                executable: wine, arguments: ["taskkill", "/F", "/IM", image],
                environment: steamEnvironment(wine: wine), currentDirectory: clientDir)
        }
    }

    /// The Steam process images `forceQuit` kills by name. steamwebhelper first — it's the CEF tree a plain
    /// loader-SIGTERM leaves alive; `steam.exe` is the client (and any re-exec'd copy the updater spawned).
    static let steamProcessImages = ["steamwebhelper.exe", "steam.exe"]

    /// Synchronous, fire-and-forget force-quit for the **app-quit** path — `taskkill /F /IM` each Steam
    /// image via `spawnDetachedForget`, so the kills survive Silo's own `exit(0)` and take down the whole
    /// Steam tree even though `stop()`'s loader SIGTERM can't (Steam is multi-process and re-execs itself).
    /// Mirrors `forceQuit` but never awaits; caller gates on having actually started a client so this never
    /// touches an untouched prefix.
    func forceQuitSync(wine: URL?) {
        guard let wine else { return }
        for image in Self.steamProcessImages {
            runner.spawnDetachedForget(
                executable: wine, arguments: ["taskkill", "/F", "/IM", image],
                environment: steamEnvironment(wine: wine), currentDirectory: clientDir, logURL: log)
        }
    }

    /// Ask the running bottle Steam to quit gracefully (`steam.exe -shutdown` — lets it flush its config).
    /// Runs to completion (the transient forwarder exits quickly); the caller then waits for the client
    /// process itself to die before proceeding.
    func shutdownSteam(wine: URL?) async throws {
        guard let wine else { throw BottleError.wineNotConfigured }
        _ = try await runner.run(
            executable: wine, arguments: [exe.path, "-shutdown"],
            environment: steamEnvironment(wine: wine), currentDirectory: clientDir)
    }

    /// Hand a `steam://…` URL to the (already-running) bottle Steam. A plain `steam.exe <url>` — no CEF
    /// flags — so Steam's single-instance forwarder routes the URL to the running client and the transient
    /// process exits, rather than standing up a second client.
    @discardableResult
    public func sendURL(_ url: String, wine: URL?) async throws -> Int32 {
        guard let wine else { throw BottleError.wineNotConfigured }
        return try await runner.spawnDetached(
            executable: wine, arguments: [exe.path, url],
            environment: steamEnvironment(wine: wine),
            currentDirectory: clientDir, logURL: log)
    }

    // MARK: - Helpers

    /// Environment for launching the Steam client — trimmed to what's actually load-bearing (verified
    /// on-device 2026-06-28). `STEAM_CEF_COMMAND_LINE` forces steamwebhelper's Chromium onto its bundled
    /// **SwiftShader software GL** (`--use-gl=swiftshader` — confirmed active in the GPU log; the route that
    /// actually paints under Wine, vs Metal/winemac.drv presentation) with `--in-process-gpu` (NOT
    /// `--single-process`, which breaks Chromium's network service). The load-bearing flag injection is the
    /// steamwebhelper wrapper (`installWebHelperWrapper`); this env is the partner that carries SwiftShader.
    /// `WINEMSYNC=1` matches the per-game launch env so Steam + co-hosted games share one wineserver (the
    /// co-residency Steamworks relies on). The winebus/SDL crash is fixed by removing libSDL2 (build
    /// `--without-sdl` + `stripBundledSDL`), NOT a DLL override; CEF presentation is the virtual desktop.
    private func steamEnvironment(wine: URL) -> [String: String] {
        var env = Silo.msyncWineEnvironment(prefix: prefixDir, wine: wine)
        // Force steamwebhelper's Chromium onto bundled SwiftShader software GL — the route that actually
        // paints under Wine (the GPU/Metal path black-screens; an experimental GPU path was tried and
        // removed as it never rendered).
        env["STEAM_CEF_COMMAND_LINE"] =
            "--no-sandbox --in-process-gpu --disable-gpu --disable-gpu-compositing "
            + "--use-gl=swiftshader --disable-software-rasterizer"
        env["STEAM_DISABLE_GPU_PROCESS"] = "1"
        return env
    }

    /// Download the Steam installer into the bottle (idempotent — returns the cached `SteamSetup.exe`). The
    /// onboarding flow calls this as its own early "download only" step so a network failure surfaces before
    /// the prefix is booted.
    func downloadSteamInstaller() async throws -> URL {
        let dest = prefixDir.appendingPathComponent("SteamSetup.exe")
        if fileManager.fileExists(atPath: dest.path) { return dest }
        // The onboarding flow downloads BEFORE `provision` (wineboot) creates the prefix, so ensure it exists.
        try fileManager.createDirectory(at: prefixDir, withIntermediateDirectories: true)
        try DownloadGuard.requireHTTPS(Silo.steamInstallerURL)   // https-only download
        let (tempFile, response) = try await session.download(from: Silo.steamInstallerURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BottleError.installerDownloadFailed(http.statusCode)
        }
        try fileManager.moveItem(at: tempFile, to: dest)
        return dest
    }
}
