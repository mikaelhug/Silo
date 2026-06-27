import SwiftUI

/// One-time Steam sign-in for the SteamCMD downloader. The password is sent to SteamCMD (which caches
/// a token) and never stored. Shown in onboarding and reachable from the library toolbar.
struct SteamLoginView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var login = env.steamLogin
        NavigationStack {
            Form {
                Section {
                    TextField("Steam username", text: $login.username)
                        .textContentType(.username).autocorrectionDisabled()
                    SecureField("Password", text: $login.password)
                    if login.needsGuardCode {
                        TextField("Steam Guard code", text: $login.guardCode)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text("Silo signs in once via Valve's SteamCMD and caches the session — you won't be "
                         + "asked again. Your password is never stored. Used only to download the Windows "
                         + "files of games you own.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let message = login.statusMessage {
                    Text(message).font(.callout)
                        .foregroundStyle(login.loggedIn ? .green : .secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Sign in to Steam")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if login.isLoggingIn {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Sign In") { Task { await login.login(); if login.loggedIn { dismiss() } } }
                            .disabled(login.username.isEmpty)
                    }
                }
            }
        }
        .frame(width: 440, height: 340)
    }
}
