import Foundation

// MARK: - User-facing error text
//
// Every one of these is a plain Swift enum, so before this the UI rendered
// `(error as NSError).localizedDescription` — i.e. "The operation couldn't be completed.
// (SiloKit.RuntimeManager.RuntimeError error 4.)" — for precisely the failures a first run hits most:
// a rate-limited GitHub, a missing checksum, a full disk, a bad .dmg. `LocalizedError` gives each one a
// sentence a user can act on, and keeps the diagnostic detail (exit code / HTTP status) the cases carry.

extension RuntimeManager.RuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .badResponse(let code) where code == 403:
            "GitHub rate-limited this Mac (HTTP 403). Wait a few minutes and try again."
        case .badResponse(let code):
            "GitHub returned HTTP \(code) while listing releases."
        case .downloadFailed(let code):
            "The download failed (HTTP \(code)) — check your connection and try again."
        case .extractionFailed(let code):
            "Couldn't unpack the download (tar exit \(code)). You may be out of disk space."
        case .checksumMismatch:
            "The download didn't match its published checksum, so it was discarded. Try again."
        case .checksumUnavailable:
            "The download has no published checksum, so it wasn't installed."
        case .unsafeRuntimeName(let name):
            "\"\(name)\" isn't a usable runtime name."
        }
    }
}

extension GPTKImporter.ImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .attachFailed(let detail):
            "Couldn't open the disk image: \(detail)"
        case .nestedDMGNotFound:
            "That doesn't look like Apple's Game Porting Toolkit disk image — no inner .dmg was found."
        case .redistNotFound:
            "That disk image doesn't contain the Game Porting Toolkit's redistributable libraries."
        case .unsafeRuntimeName(let name):
            "\"\(name)\" isn't a usable runtime name."
        }
    }
}

extension SteamBottle.BottleError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .wineNotConfigured:
            "No Wine runtime is set up yet."
        case .winebootFailed(let code):
            "Couldn't create the Windows bottle (wineboot exit \(code)). Check the Wine runtime in Settings."
        case .installerDownloadFailed(let code):
            "Couldn't download the Steam installer (HTTP \(code)) — check your connection."
        case .steamInstallFailed(let code):
            "The Steam installer didn't finish (exit \(code))."
        case .componentCancelled(let component):
            "You cancelled the \(component.title) installer."
        }
    }
}
