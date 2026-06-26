# Silo

A native macOS launcher overlay for Windows Steam games on Apple Silicon, built on Wine + Apple's
Game Porting Toolkit (GPTK / D3DMetal).

**Single Downloader, Multi-Runtime:** install Steam once in a simple Master Wine bottle to download
games; Silo launches each game in its own isolated Wine prefix with one click.

- Native SwiftUI, async/await, no main-thread blocking.
- Self-contained: downloads its own Wine/GPTK runtime (no Homebrew), self-updates from GitHub Releases.
- Per-game isolation: separate `WINEPREFIX`, graphics backend (GPTK primary, CrossOver fallback),
  and environment flags.

> Status: in active development. See `STATUS.md` for current progress and `CLAUDE.md` for architecture.

## Build (developers)

```sh
swift build          # compile
swift test           # run the test suite (passes with no Wine/GPTK installed)
Scripts/run.sh       # assemble dist/Silo.app and launch it
```

Requires the Swift 6 toolchain (Command Line Tools are sufficient — no Xcode needed).

## License / legal

Silo does not bundle or download Wine, GPTK, or any Steam-API emulator. Wine/GPTK runtimes are
fetched from a user-visible, configurable third-party release. The optional Steam-API emulator stub
is **user-provided** and intended only for games you own; you are responsible for compliance with
Steam's Subscriber Agreement and applicable law.
