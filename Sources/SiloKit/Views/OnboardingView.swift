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
                    Text("Three quick steps to get playing.").foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    StepRow(
                        number: 1, title: "Install Wine",
                        subtitle: "~250 MB download.",
                        done: env.wineReady, busy: runtime.isInstalling,
                        actionLabel: "Install",
                        action: { Task { await env.runtime.installLatest() } })

                    StepRow(
                        number: 2, title: "Import Game Porting Toolkit",
                        subtitle: "Apple's GPTK .dmg.",
                        done: env.gptkReady, busy: gptk.isImporting,
                        actionLabel: "Choose .dmg",
                        action: { if let dmg = chooseDiskImage() { Task { await env.gptkManager.importGPTK(from: dmg) } } })

                    StepRow(
                        number: 3, title: "Set up the Steam bottle",
                        subtitle: "Sign in once.",
                        done: env.gptkSteamReady, busy: steam.busy, locked: !env.wineReady,
                        actionLabel: "Set up",
                        action: { Task { await env.steamBottleVM.setUp() } })
                }
                .frame(maxWidth: 540)

                DXMTOnboardingSection()
                    .frame(maxWidth: 540)

                let message = steam.status.isEmpty
                    ? (runtime.statusMessage ?? env.dxmtRuntime.statusMessage
                        ?? gptk.statusMessage ?? backend.statusMessage) : steam.status
                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 540)
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
                    number: 1, title: "Install the DXMT runtime",
                    subtitle: "~7 MB download.",
                    done: env.dxmtReady, busy: env.dxmtRuntime.isInstalling, locked: !env.wineReady,
                    actionLabel: "Install",
                    action: { Task { await env.dxmtRuntime.installLatest() } })
                StepRow(
                    number: 2, title: "Set up the DXMT Steam bottle",
                    subtitle: "Sign in once.",
                    done: env.dxmtSteamReady, busy: env.dxmtBottleVM.busy, locked: !env.wineReady,
                    actionLabel: "Set up",
                    action: { Task { await env.dxmtBottleVM.setUp() } })
            }
            .padding(.top, 10)
        } label: {
            Text("Older games (DXMT) — optional").font(.headline)
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
