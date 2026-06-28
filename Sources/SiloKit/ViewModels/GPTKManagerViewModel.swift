import Foundation

@MainActor
@Observable
public final class GPTKManagerViewModel {
    public private(set) var installs: [GPTKInstall] = []
    public var defaultName: String?
    public var statusMessage: String?
    public private(set) var isImporting = false

    private let importer: GPTKImporter

    /// Called when the default GPTK changes so the backend config can adopt its lib dir.
    public var onDefaultChanged: ((GPTKInstall) -> Void)?

    public init(importer: GPTKImporter, defaultName: String? = nil) {
        self.importer = importer
        self.defaultName = defaultName
    }

    public func refresh() {
        installs = importer.installed()
        // Drop a stale default if its install was removed out from under us.
        if let name = defaultName, !installs.contains(where: { $0.name == name }) {
            defaultName = nil
        }
    }

    public func importGPTK(from dmgURL: URL) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        statusMessage = "Importing \(dmgURL.lastPathComponent)…"
        do {
            let result = try await importer.importGPTK(fromDMG: dmgURL)
            refresh()
            // Adopt the newly-imported version as default if none is set yet.
            if defaultName == nil, let new = installs.first(where: { $0.name == result.name }) {
                setDefault(new)
            }
            statusMessage = "Imported \(result.name)."
        } catch {
            statusMessage = "Import failed: \((error as NSError).localizedDescription)"
        }
    }

    public func remove(_ install: GPTKInstall) async {
        do {
            try importer.remove(name: install.name)
            if defaultName == install.name { defaultName = nil }
            refresh()
            statusMessage = "Removed \(install.displayName)."
        } catch {
            statusMessage = "Remove failed: \((error as NSError).localizedDescription)"
        }
    }

    public func setDefault(_ install: GPTKInstall) {
        defaultName = install.name
        onDefaultChanged?(install)
        statusMessage = "Default GPTK: \(install.displayName)."
    }

    public func isDefault(_ install: GPTKInstall) -> Bool { defaultName == install.name }
}
