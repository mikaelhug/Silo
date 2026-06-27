import Foundation

/// One-time Steam sign-in for SteamCMD. Username/password/Steam-Guard are passed to SteamCMD, which
/// caches a refresh token; afterwards only the username is needed. The password is never persisted.
@MainActor
@Observable
public final class SteamLoginViewModel {
    public var username: String = ""
    public var password: String = ""
    public var guardCode: String = ""
    public private(set) var isLoggingIn = false
    public private(set) var loggedIn = false
    public private(set) var needsGuardCode = false
    public var statusMessage: String?

    private let steamCMD: SteamCMDClient
    /// Called with the username on success so the app can persist it + load the library.
    public var onLoggedIn: ((String) -> Void)?

    public init(steamCMD: SteamCMDClient, username: String? = nil) {
        self.steamCMD = steamCMD
        if let username { self.username = username; self.loggedIn = true }
    }

    public func login() async {
        let user = username.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, !isLoggingIn else { return }
        isLoggingIn = true; defer { isLoggingIn = false }
        statusMessage = "Signing in…"
        do {
            let output = try await steamCMD.capture(SteamCMD.loginArguments(
                username: user,
                password: password.isEmpty ? nil : password,
                guardCode: guardCode.isEmpty ? nil : guardCode))
            classify(output, user: user)
        } catch {
            statusMessage = (error as NSError).localizedDescription
        }
    }

    /// Interpret SteamCMD's login output (no machine-readable status, so match its messages).
    func classify(_ output: String, user: String) {
        let lower = output.lowercased()
        if lower.contains("logged in ok") || lower.contains("waiting for user info...ok") {
            loggedIn = true
            needsGuardCode = false
            password = ""; guardCode = ""
            statusMessage = "Signed in as \(user)."
            onLoggedIn?(user)
        } else if lower.contains("steam guard") || lower.contains("two-factor") || lower.contains("twofactor") {
            needsGuardCode = true
            statusMessage = "Enter the Steam Guard code sent to your device."
        } else if lower.contains("invalid password") || lower.contains("rate limit") {
            statusMessage = "Sign-in failed: invalid password or too many attempts."
        } else {
            statusMessage = "Sign-in failed. Double-check your credentials and Steam Guard code."
        }
    }
}
