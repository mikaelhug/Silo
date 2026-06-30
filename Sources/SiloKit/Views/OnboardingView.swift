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
                        number: 3, title: "Set up the Steam bottle",
                        subtitle: "Installs a Windows Steam client into a shared prefix; launch it and sign "
                            + "in once to install + run your games.",
                        done: env.steamReady, busy: steam.busy, locked: !env.wineReady,
                        actionLabel: "Set up…",
                        action: { Task { await env.steamBottleVM.setUp() } })
                }
                .frame(maxWidth: 540)

                DXMTOnboardingSection()
                    .frame(maxWidth: 540)

                let message = steam.status.isEmpty
                    ? (runtime.statusMessage ?? gptk.statusMessage ?? backend.statusMessage) : steam.status
                if let message {
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

/// Optional second-backend setup (collapsed by default): import the DXMT runtime + set up the DXMT Steam
/// bottle. DXMT is the fallback for older DirectX 10/11 titles GPTK can't run; its own bottle = its own
/// Steam login (machine tokens are per-prefix, so you sign into each bottle once).
private struct DXMTOnboardingSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 12) {
                StepRow(
                    number: 1, title: "Import the DXMT runtime",
                    subtitle: "Choose the DXMT module folder (x86_64-windows) built from the CrossOver source.",
                    done: env.dxmtReady, locked: !env.wineReady,
                    actionLabel: "Choose folder…",
                    action: {
                        if let dir = chooseDirectory(message: "Choose the DXMT x86_64-windows module folder.") {
                            Task { await env.importDXMTRuntime(from: dir) }
                        }
                    })
                StepRow(
                    number: 2, title: "Set up the DXMT Steam bottle",
                    subtitle: "Installs a second Windows Steam client; sign in to install your older games here.",
                    done: env.dxmtSteamReady, busy: env.dxmtBottleVM.busy, locked: !env.wineReady,
                    actionLabel: "Set up…",
                    action: { Task { await env.dxmtBottleVM.setUp() } })
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Older games (DXMT) — optional").font(.headline)
                Text("A fallback backend for DirectX 10/11 titles GPTK can't run (e.g. Overcooked 2).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
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
