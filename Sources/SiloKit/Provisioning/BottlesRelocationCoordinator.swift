import Foundation

/// Owns the bottles-location move flow (Settings → General → Bottles): validate the destination
/// filesystem, refuse while anything runs in a bottle, copy off the main actor with determinate
/// progress, persist the choice, and relaunch to adopt it — `AppPaths` is value-injected everywhere,
/// so a fresh launch is the one clean way to re-point every consumer. Exposed as `env.bottles`.
@MainActor
@Observable
public final class BottlesRelocationCoordinator {
    public private(set) var busy = false
    public private(set) var message: String?
    /// Copy progress during a cross-volume move (`0...1`), or nil when indeterminate / not moving.
    public private(set) var progress: Double?
    /// Rejects a destination whose filesystem can't hold a Wine bottle (exFAT/FAT). Injectable for tests.
    var filesystemRejects: @Sendable (URL) -> Bool = { Filesystem.isFATFamily($0) }

    private let paths: AppPaths
    private let updater: Updater
    /// True while any game OR any bottle's Steam client is live — relocation is refused then (we'd be
    /// moving prefixes out from under running wineservers). Wired by `AppEnvironment.init` to its
    /// `anythingRunning` (a late-bound var: the coordinator is a stored property of AppEnvironment, so
    /// it can't capture `self` during init).
    var isBlocked: () -> Bool = { false }

    init(paths: AppPaths, updater: Updater) {
        self.paths = paths
        self.updater = updater
    }

    /// Move all bottles into a `Silo Bottles` folder inside `chosen` (a directory the user picked — e.g. an
    /// external drive), so we never scatter prefixes directly into a shared location. Refuses an exFAT/FAT
    /// destination — a Wine prefix needs POSIX symlinks.
    public func moveBottles(to chosen: URL) async {
        guard !filesystemRejects(chosen) else {
            message = "That location is exFAT/FAT, which can't hold a Wine bottle (no symlink "
                + "support). Reformat the drive as APFS or Mac OS Extended, then try again."
            return
        }
        await relocateBottles(to: chosen.appendingPathComponent("Silo Bottles", isDirectory: true))
    }

    /// Move bottles back to the default location (under Application Support).
    public func resetBottlesLocation() async {
        guard paths.bottlesRelocated else { return }
        await relocateBottles(to: paths.supportDir)
    }

    /// Relocate the bottle dirs to `newRoot`, persist the choice, and relaunch to adopt it everywhere.
    private func relocateBottles(to newRoot: URL) async {
        guard !busy else { return }
        guard !isBlocked() else {
            message = "Quit any running game and Steam before moving bottles."
            return
        }
        // The move reads FROM the current bottles root. If that's a relocated drive that's currently
        // unplugged, every source path is absent — the copy/rename would vacuously "succeed" (nothing to
        // move), then persist the new location and relaunch into an empty dir while the real bottles sit
        // orphaned on the drive. Refuse until the current root is reachable.
        guard paths.bottlesRootReachable else {
            message = "Your bottles drive isn't connected — reconnect it before moving bottles."
            return
        }
        let old = paths.bottlesRoot
        guard newRoot.standardizedFileURL != old.standardizedFileURL else {
            message = "Bottles are already there."
            return
        }
        busy = true
        progress = 0
        message = "Moving bottles… this can take a while for installed games."
        defer { busy = false; progress = nil }

        let names = AppPaths.bottleDirNames
        do {
            // Off the main actor — a cross-volume move is a full copy of (potentially huge) game data.
            // The progress callback hops back to the main actor to update the determinate bar.
            try await Task.detached(priority: .userInitiated) { [weak self] in
                try await BottleRelocator().move(names, from: old, to: newRoot) { fraction in
                    Task { @MainActor in self?.progress = fraction }
                }
            }.value
        } catch {
            message = "Couldn't move bottles: \((error as NSError).localizedDescription)"
            return
        }

        // Persist (nil = back to the default), then adopt via relaunch.
        let isDefault = newRoot.standardizedFileURL == paths.supportDir.standardizedFileURL
        BottlesLocation.write(isDefault ? nil : newRoot, supportDir: paths.supportDir)
        // Use the injectable resolver (not the ambient static `runningAppBundle`) so tests can pin it to nil
        // — otherwise the ambient `Bundle.main` resolves to a bundle under `swift test --no-parallel` and
        // `relaunch`'s `exit(0)` kills the whole test run.
        if let bundle = updater.appBundleToReplace() {
            message = "Bottles moved. Relaunching…"
            await updater.relaunch(bundle)   // launches the new instance + exit(0); never returns
        } else {
            message = "Bottles moved to \(newRoot.path). Restart Silo to use the new location."
        }
    }
}
