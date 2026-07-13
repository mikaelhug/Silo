import SwiftUI

/// First-run guided setup shown in the Library when Silo isn't configured yet.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let runtime = env.runtime
        let gptk = env.gptkManager
        let backend = env.backendSettings
        let steam = env.steamBottleVM

        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Image(systemName: "wineglass").font(.system(size: 46)).foregroundStyle(.tint)
                    Text("Welcome to Silo").font(.largeTitle.bold())
                    Text("Two quick steps to get playing.").foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    StepRow(
                        number: 1, title: "Import Game Porting Toolkit",
                        subtitle: "Apple's GPTK4 .dmg",
                        done: env.gptkReady, busy: gptk.isImporting,
                        actionLabel: "Choose .dmg",
                        action: { if let dmg = chooseDiskImage() { Task { await env.gptkManager.importGPTK(from: dmg) } } })

                    StepRow(
                        number: 2, title: "Set up",
                        subtitle: "Download and configure the Steam client",
                        done: env.steamReady, busy: env.setupBusy, locked: !env.gptkReady,
                        actionLabel: "Set up",
                        action: { Task { await env.runFullSetup() } })
                }
                .frame(maxWidth: 540)

                if env.setupBusy {
                    // A blue indeterminate progress bar — with the active phase's status under it — instead of
                    // the changing per-step text. NB: use a value-less `ProgressView()`; `ProgressView(value:
                    // nil)` renders a STATIC (non-animating) linear bar.
                    VStack(spacing: 10) {
                        ProgressView()                          // indeterminate → animates left-to-right
                            .progressViewStyle(.linear)
                            .tint(.blue)
                        // The active phase's status (esp. "Accept the license for …") so a license/installer
                        // window that pops up has context — it was previously hidden behind the bare bar.
                        if let phase = setupPhaseText() {
                            Text(phase).font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: 540)
                } else {
                    // Idle: surface the final/error status (setup done, or a Wine/GPTK failure).
                    let message = steam.status.isEmpty
                        ? (runtime.statusMessage ?? env.dxmtRuntime.statusMessage
                            ?? gptk.statusMessage ?? backend.statusMessage) : steam.status
                    VStack(spacing: 6) {
                        if let message {
                            Text(message).font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        // DXMT is optional (most games use GPTK), but if the required steps finished WITHOUT
                        // it (a failed/absent download), say so once on this completion screen — otherwise
                        // it's discovered only when a 32-bit / GPTK-incompatible game is later refused.
                        if env.setupComplete && !env.dxmtReady {
                            Text("DXMT isn't installed — optional, but needed for 32-bit and some older titles. Add it anytime in Settings → DXMT.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: 540)
                }

                // Only until GPTK is imported — once the user has pointed Silo at the .dmg (step 2 "Done"),
                // the "where to download it" link is just clutter.
                if !env.gptkReady {
                    Link("Get GPTK from Apple (Apple ID required)", destination: Silo.appleGPTKURL)
                        .font(.caption)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    /// The status of whichever setup phase is active, for the line under the progress bar: the bottle's own
    /// status once setUp is running (component prompts + warm-up), else the in-flight runtime download.
    private func setupPhaseText() -> String? {
        if !env.steamBottleVM.status.isEmpty { return env.steamBottleVM.status }
        if env.runtime.isInstalling { return env.runtime.statusMessage }
        if env.dxmtRuntime.isInstalling { return env.dxmtRuntime.statusMessage }
        return nil
    }
}

private struct StepRow: View {
    let number: Int
    let title: String
    let subtitle: String
    let done: Bool
    var busy: Bool = false
    var locked: Bool = false
    let actionLabel: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.2)).frame(width: 30, height: 30)
                if done {
                    Image(systemName: "checkmark").foregroundStyle(.white).font(.system(size: 13, weight: .bold))
                } else {
                    Text("\(number)").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if done {
                Text("Done").font(.caption).foregroundStyle(.green)
            } else if busy {
                ProgressView().controlSize(.small)
            } else {
                Button(actionLabel, action: action).disabled(locked)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .opacity(locked ? 0.55 : 1)
    }
}
