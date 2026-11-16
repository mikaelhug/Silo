# Silo 0.5.2

- **Steam opens again after Steam updates itself.** Steam's Nov 12 client update installed a new web helper (the process that draws Steam's window), and Silo mistook it for its own wrapper, deleted it, and kept the old one, so Steam's window never appeared. Silo now keeps Steam's updated web helper. A bottle this already broke is repaired automatically on the next Steam launch, which can take a minute longer than usual.

Thanks for [reporting it](https://github.com/mikaelhug/Silo/issues/10)!

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your `.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).
