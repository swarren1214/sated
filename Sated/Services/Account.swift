import AuthenticationServices
import Foundation
import Observation
import OSLog
import SwiftData

/// Who's signed in, for the sign-in screen and Settings › Account.
///
/// The session itself lives in `HearthAPI` (shared with BigTable and Suffice); this mirrors it
/// on the main actor for SwiftUI and refreshes when it can change: at launch, after signing in
/// or out here, when another Hearth app signs in or out, and when Sated becomes active.
@Observable
final class AccountStore {
    static let shared = AccountStore()

    enum Status: Equatable {
        /// Not checked yet this launch. Nothing is shown for it, so the sign-in screen
        /// doesn't flash before the shared session has been read.
        case unknown
        case signedOut
        case signedIn(name: String?, email: String?)
    }

    private(set) var status: Status = .unknown
    /// "Not now" was chosen on the sign-in screen.
    private(set) var skipped = UserDefaults.standard.bool(forKey: SettingsKey.signInSkipped) {
        didSet { UserDefaults.standard.set(skipped, forKey: SettingsKey.signInSkipped) }
    }

    var isSignedIn: Bool {
        if case .signedIn = status { return true }
        return false
    }

    /// Whether the sign-in screen should be up: signed out, and either sign-in is required
    /// or the person hasn't chosen "Not now".
    var showsSignInScreen: Bool {
        guard !ScreenshotMode.isOn, status == .signedOut else { return false }
        return AppConfig.requiresSignIn || !skipped
    }

    @ObservationIgnored private var revocationObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "com.stephenwarren.sated", category: "account")

    init() {
        // Stopped using Apple ID with Sated (Settings › Apple Account › Sign in with Apple):
        // sign out here too.
        revocationObserver = NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await AccountStore.shared.signOut() }
        }
    }

    /// Reads the current sign-in from `HearthAPI`.
    func refresh() async {
        guard !ScreenshotMode.isOn else {
            status = .signedIn(name: "Steve Warren", email: nil)
            return
        }
        let current = await HearthAPI.shared.signInStatus()
        guard current.isSignedIn else {
            status = .signedOut
            return
        }
        let apple = HearthAccounts.appleID()
        let name = apple?.fullName ?? UserDefaults.standard.string(forKey: SettingsKey.accountName)
        status = .signedIn(name: name, email: current.email ?? apple?.email)
        await checkAppleCredential(apple?.userID)
    }

    /// Trades an Apple credential for a session (shared with the other Hearth apps).
    func signIn(with credential: ASAuthorizationAppleIDCredential, nonce: String?) async throws {
        try await HearthAPI.shared.signInWithApple(
            identityToken: credential.identityToken,
            nonce: nonce,
            appleUserID: credential.user,
            fullName: credential.fullName,
            email: credential.email
        )
        if let name = HearthAPI.formatted(credential.fullName) ?? HearthAPI.sharedAppleName(for: credential.user) {
            UserDefaults.standard.set(name, forKey: SettingsKey.accountName)
        }
        skipped = false
        await refresh()
    }

    /// Signs out here and in the other Hearth apps on this device. The food log isn't touched.
    func signOut() async {
        await HearthAPI.shared.signOut()
        UserDefaults.standard.removeObject(forKey: SettingsKey.accountName)
        // Offer the sign-in screen again.
        skipped = false
        status = .signedOut
    }

    /// Settings › Account › Delete Account: deletes the Hearth account on the server (for every
    /// Hearth app), then erases Sated's own data (`SatedDataEraser`), then signs out of every
    /// Hearth app as Sign Out does. When the server refuses, it throws and nothing changes here.
    func deleteAccount(erasing context: ModelContext) async throws {
        guard isSignedIn, !ScreenshotMode.isOn else { return }
        try await HearthAPI.shared.deleteAccount()
        log.notice("Hearth account deleted; erasing Sated's data and signing out")
        await SatedDataEraser.eraseAll(in: context)
        await signOut()
    }

    /// "Not now" on the sign-in screen.
    func skipSignIn() {
        skipped = true
    }

    /// Signs out if the person stopped using their Apple ID with the app. Network problems
    /// never sign anyone out.
    private func checkAppleCredential(_ appleUserID: String?) async {
        guard let appleUserID else { return }
        let state: ASAuthorizationAppleIDProvider.CredentialState? = await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: appleUserID) { state, error in
                continuation.resume(returning: error == nil ? state : nil)
            }
        }
        if state == .revoked {
            log.notice("Apple ID credential revoked; signing out")
            await signOut()
        }
    }
}

nonisolated extension SettingsKey {
    /// "Not now" on the sign-in screen.
    static let signInSkipped = "account.signInSkipped"
    /// The name Apple gave at sign-in (Apple only sends it the first time).
    static let accountName = "account.name"
}
