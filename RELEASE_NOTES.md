# Silo 0.4.4

Fixes for problems found in 0.4.3. **If you used the DXVK tab in 0.4.3, this release repairs your settings automatically on first launch.**

## DXVK settings fixes

- **The DXVK tab listed your Wine builds and could adopt one as the "DXVK runtime".** Wine ships its own `d3d9.dll` and `d3d11.dll` in exactly the layout Silo used to identify DXVK, so every Wine install matched. Silo now requires DXVK's own Vulkan driver to be present, which Wine trees never have. A wrong setting left over from 0.4.3 is cleared automatically.
- **The DXVK runtime is now published and installable.** Settings → DXVK → Install latest DXVK works; it ships DXVK 1.10.3 with its own Vulkan driver.

## Setup and reliability

- **Runtime downloads no longer break as the release list grows.** Silo looked at only the newest 15 releases, so as new versions were published the Wine runtime would eventually drop out of view and setup would fail with "No Wine build published yet." even though it was there. Silo now searches further back.
- **Deleting a runtime outside Silo no longer leaves setup thinking it's installed.** Previously the setup step still showed "Done" while every launch failed against a path that no longer existed.
- **Interrupted downloads no longer appear as installed runtimes.** A partially-extracted runtime left behind by a crash could be listed and selected as the default.
- **Error messages are readable.** Failures during first-run setup — a rate-limited GitHub, a failed checksum, a full disk, an unrecognised GPTK disk image — showed an internal Cocoa string instead of an explanation.

---

Silo downloads its own Wine (built from CrossOver's FOSS source in CI) and imports Apple's GPTK from your `.dmg`. Runs on macOS 15+ on Apple Silicon. Gatekeeper: the build is ad-hoc signed, so right-click → **Open** on first launch (or `xattr -dr com.apple.quarantine Silo.app`).
