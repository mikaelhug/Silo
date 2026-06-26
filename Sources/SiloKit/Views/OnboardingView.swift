import SwiftUI

/// First-run guided setup shown in the Library when Silo isn't configured yet.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let runtime = env.runtime
        let gptk = env.gptkManager
        let backend = env.backendSettings

        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Image(systemName: "wineglass").font(.system(size: 46)).foregroundStyle(.tint)
                    Text("Welcome to Silo").font(.largeTitle.bold())
                    Text("Three quick steps to play your Windows Steam games.")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    StepRow(
                        number: 1, title: "Install Wine",
                        subtitle: "Downloads a prebuilt Wine build (~250 MB).",
                        done: env.wineReady, busy: runtime.isInstalling,
                        actionLabel: "Install Wine",
                        action: { Task { await env.runtime.installLatest() } })

                    StepRow(
                        number: 2, title: "Import Game Porting Toolkit",
                        subtitle: "Choose Apple's GPTK .dmg (the D3DMetal graphics layer).",
                        done: env.gptkReady, busy: gptk.isImporting,
                        actionLabel: "Choose .dmg…",
                        action: { if let dmg = chooseDiskImage() { Task { await env.gptkManager.importGPTK(from: dmg) } } })

                    StepRow(
                        number: 3, title: "Install Steam",
                        subtitle: "Creates the Master Steam bottle and installs Steam.",
                        done: env.steamReady, busy: backend.isInstallingBottle, locked: !env.wineReady,
                        actionLabel: "Install Steam",
                        action: { Task { await env.backendSettings.installSteamBottle() } })
                }
                .frame(maxWidth: 540)

                if let message = runtime.statusMessage ?? gptk.statusMessage ?? backend.statusMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 540)
                }

                Link("Download GPTK from Apple (requires Apple ID)", destination: Silo.appleGPTKURL)
                    .font(.caption)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
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
