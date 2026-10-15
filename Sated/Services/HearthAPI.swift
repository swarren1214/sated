import AuthenticationServices
import CryptoKit
import Foundation
import OSLog
import Security

/// The app's identity with the shared Hearth API: a silent anonymous Supabase session (or
/// Sign in with Apple), kept in the Keychain. `APIClient` asks it for tokens.
///
/// Reliability:
/// - A token is reused until a minute before it expires.
/// - Only one sign-in or refresh runs at a time; everyone else waits for it. (Two refreshes
///   at once would spend the same refresh token twice, and Supabase rejects the second.)
/// - A new anonymous user is created only when Supabase rejects the refresh token, never
///   because the network or Supabase failed, so a bad connection can't churn identities.
/// - If the Keychain can't be written, the session still works for this launch.
///
/// One sign-in for every Hearth app (see `HearthSharedSession` in HearthShared.swift):
/// - A signed-in (Apple) session is shared with BigTable and Suffice through `HearthAccounts`;
///   anonymous sessions never are.
/// - With no session or only an anonymous one, Sated adopts the shared one.
/// - Before spending a refresh token, the shared session is re-read: another app may already
///   have refreshed it.
/// - When the shared session disappears (signed out in another app) or changes person, Sated
///   follows it, falling back to an anonymous session.
actor HearthAPI {
    static let shared = HearthAPI()

    nonisolated struct Identity: Decodable, Sendable {
        let id: String
    }

    nonisolated private struct AuthUser: Codable, Sendable {
        let id: String
        let isAnonymous: Bool?
        let email: String?

        enum CodingKeys: String, CodingKey {
            case id
            case isAnonymous = "is_anonymous"
            case email
        }
    }

    nonisolated private struct AuthSession: Codable, Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Int
        let user: AuthUser

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresAt = "expires_at"
            case user
        }
    }

    nonisolated private struct AuthError: Decodable, Sendable {
        let msg: String?
        let message: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case msg, message
            case errorDescription = "error_description"
        }
    }

    nonisolated enum ClientError: LocalizedError, Sendable {
        case invalidResponse
        case service(String)
        /// Supabase refused the request (an expired refresh token, or sign-ins turned off).
        case rejected(String)
        case rateLimited
        case missingAppleToken
        case missingAppleNonce

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "The identity service returned an invalid response."
            case .service(let message), .rejected(let message): message
            case .rateLimited: "Too many requests just now. Try again in a minute."
            case .missingAppleToken: "Apple did not provide an identity token. Please try again."
            case .missingAppleNonce: "The Apple sign-in request expired. Please try again."
            }
        }
    }

    private static let keychainService = "com.stephenwarren.hearth.supabase"
    private static let keychainAccount = "session"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hearth", category: "api")

    private let session: URLSession
    private var authSession: AuthSession?
    private var renewal: Task<AuthSession, Error>?

    init(session: URLSession = .shared) {
        self.session = session
        authSession = Self.loadSession()
    }

    func prepareSession() async {
        // Screenshot mode (Debug) never signs in to the API.
        if ScreenshotMode.isOn { return }
        followSharedSession()
        do {
            _ = try await accessToken()
        } catch {
            Self.log.error("API session setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A valid access token. `renew` forces a refresh, after the API rejected the current one.
    func accessToken(renew: Bool = false) async throws -> String {
        if !renew, let authSession, authSession.expiresAt > Int(Date().timeIntervalSince1970) + 60 {
            return authSession.accessToken
        }
        if let renewal {
            return try await renewal.value.accessToken
        }
        let rejectedToken = renew ? authSession?.accessToken : nil
        let task = Task { try await self.obtainSession(rejectedToken: rejectedToken) }
        renewal = task
        defer { renewal = nil }
        return try await task.value.accessToken
    }

    func identity() async throws -> Identity {
        let data = try await authorizedData(path: "/v1/me")
        return try JSONDecoder().decode(Identity.self, from: data)
    }

    func createPlaidLinkToken() async throws -> Data {
        try await authorizedData(path: "/v1/banking/link-token", method: "POST", body: Data("{}".utf8))
    }

    /// Trades Apple's identity token for a Supabase session, and shares the sign-in (and who
    /// signed in with Apple) with the other Hearth apps.
    func signInWithApple(identityToken: Data?, nonce: String?, appleUserID: String? = nil, fullName: PersonNameComponents? = nil, email: String? = nil) async throws {
        guard let identityToken, let token = String(data: identityToken, encoding: .utf8) else {
            throw ClientError.missingAppleToken
        }
        guard let nonce else { throw ClientError.missingAppleNonce }
        let body = try JSONSerialization.data(withJSONObject: [
            "provider": "apple",
            "id_token": token,
            "nonce": nonce,
        ])
        let newSession: AuthSession = try await auth(path: "/auth/v1/token?grant_type=id_token", body: body)
        store(newSession)
        share(newSession)
        if let appleUserID {
            HearthAccounts.saveAppleID(HearthSharedAppleID(
                userID: appleUserID,
                fullName: Self.formatted(fullName),
                email: email,
                updatedBy: Self.hearthApp
            ))
        }
    }

    nonisolated static func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ClientError.service("Could not securely prepare Sign in with Apple.")
        }
        let nonce = bytes.map { String(format: "%02x", $0) }.joined()
        let digest = SHA256.hash(data: Data(nonce.utf8))
        request.nonce = digest.map { String(format: "%02x", $0) }.joined()
        return nonce
    }

    private func authorizedData(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var result = try await apiRequest(path: path, method: method, body: body, accessToken: accessToken())
        if result.response.statusCode == 401 {
            result = try await apiRequest(path: path, method: method, body: body, accessToken: accessToken(renew: true))
        }
        guard (200..<300).contains(result.response.statusCode) else {
            throw Self.error(from: result.data, status: result.response.statusCode)
        }
        return result.data
    }

    private func apiRequest(path: String, method: String, body: Data?, accessToken: String) async throws -> (data: Data, response: HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: AppConfig.apiBaseURL) else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        return (data, response)
    }

    /// Refreshes the session, or signs in anonymously when there's none or Supabase rejects
    /// the refresh token. Network and server failures are thrown as they are.
    /// `rejectedToken` is the access token the API just refused, if that's why we're here.
    private func obtainSession(rejectedToken: String?) async throws -> AuthSession {
        // Another Hearth app may have signed in, signed out or refreshed since we last looked;
        // if it already refreshed, use its token rather than spending the refresh token again.
        followSharedSession()
        if let current = authSession, current.accessToken != rejectedToken,
           current.expiresAt > Int(Date().timeIntervalSince1970) + 60 {
            return current
        }
        if let refreshToken = authSession?.refreshToken {
            do {
                return try await refresh(refreshToken)
            } catch ClientError.rejected(let message) {
                // Another Hearth app may have spent this refresh token a moment ago.
                if let shared = HearthAccounts.session(), shared.userID == authSession?.user.id,
                   shared.refreshToken != refreshToken {
                    let adopted = Self.authSession(from: shared)
                    store(adopted)
                    if adopted.expiresAt > Int(Date().timeIntervalSince1970) + 60 { return adopted }
                    do { return try await refresh(adopted.refreshToken) } catch ClientError.rejected {}
                }
                Self.log.notice("Refresh token rejected (\(message, privacy: .public)); starting a new anonymous session")
                // Don't adopt this dead session again from the shared Keychain.
                Self.markDead(refreshToken: authSession?.refreshToken ?? refreshToken)
                Self.deleteStoredSession()
                authSession = nil
            }
        }
        return try await signInAnonymously()
    }

    private func signInAnonymously() async throws -> AuthSession {
        let newSession: AuthSession = try await auth(path: "/auth/v1/signup", body: Data("{}".utf8))
        store(newSession)
        return newSession
    }

    private func refresh(_ refreshToken: String) async throws -> AuthSession {
        let body = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        let refreshed: AuthSession = try await auth(path: "/auth/v1/token?grant_type=refresh_token", body: body)
        store(refreshed)
        share(refreshed)
        return refreshed
    }

    private func auth<T: Decodable>(path: String, body: Data) async throws -> T {
        guard let url = URL(string: path, relativeTo: AppConfig.supabaseURL) else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(AppConfig.supabasePublishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        switch response.statusCode {
        case 200..<300:
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw ClientError.invalidResponse }
        case 429:
            throw ClientError.rateLimited
        case 400..<500:
            // An expired or reused refresh token, or anonymous sign-ins turned off (422).
            throw ClientError.rejected(Self.message(from: data, status: response.statusCode))
        default:
            throw Self.error(from: data, status: response.statusCode)
        }
    }

    /// Keeps the session for this launch, and in the Keychain for the next.
    private func store(_ session: AuthSession) {
        authSession = session
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status != errSecSuccess {
            Self.log.error("Couldn't save the API session to the Keychain (\(status))")
        }
    }

    private nonisolated static func loadSession() -> AuthSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    private nonisolated static func deleteStoredSession() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: One sign-in for every Hearth app

    /// What following the shared sign-in changed here.
    nonisolated enum SharedSignInChange: Sendable {
        case unchanged
        /// Took the session another Hearth app signed in with.
        case adopted
        /// The shared sign-in went away (signed out in another Hearth app); the next API call
        /// starts an anonymous session again.
        case signedOut
    }

    nonisolated private static let hearthApp: HearthApp = .sated
    /// The Supabase user whose session this app has seen in (or put in) the shared Keychain, so
    /// a missing shared session reads as "signed out in another app", not "never shared".
    nonisolated private static let sharedUserKey = "hearth.sharedSessionUserID"
    /// A hash of the last refresh token Supabase rejected, so a dead shared session isn't
    /// adopted again.
    nonisolated private static let deadTokenKey = "hearth.deadRefreshToken"

    /// True once someone has signed in with Apple, here or in another Hearth app (not an
    /// anonymous session).
    var isSignedInWithApple: Bool {
        guard let authSession else { return false }
        return authSession.user.isAnonymous != true
    }

    /// Applies the shared sign-in rules (see `HearthSharedSession`): one Keychain read, and
    /// nothing is written when this app is already in step, so its own writes don't loop.
    @discardableResult
    func followSharedSession() -> SharedSignInChange {
        guard !ScreenshotMode.isOn else { return .unchanged }
        let defaults = UserDefaults.standard
        let signedIn = isSignedInWithApple
        guard let shared = HearthAccounts.session() else {
            guard let current = authSession, signedIn else { return .unchanged }
            if defaults.string(forKey: Self.sharedUserKey) == current.user.id {
                // This sign-in was shared and now it's gone: signed out in another Hearth app.
                forgetSession()
                return .signedOut
            }
            // Signed in before the apps shared a sign-in: share it now.
            share(current)
            return .unchanged
        }
        if Self.isDead(refreshToken: shared.refreshToken) {
            // Supabase already refused this one; replace it with ours if we have one.
            if let current = authSession, signedIn { share(current) }
            return .unchanged
        }
        if let current = authSession, signedIn, current.user.id == shared.userID {
            if defaults.string(forKey: Self.sharedUserKey) != shared.userID {
                defaults.set(shared.userID, forKey: Self.sharedUserKey)
            }
            // Same person: keep whichever token lasts longer.
            if shared.refreshToken != current.refreshToken {
                if Int(shared.expiresAt) > current.expiresAt {
                    store(Self.authSession(from: shared))
                } else if current.expiresAt > Int(shared.expiresAt) {
                    share(current)
                }
            }
            return .unchanged
        }
        // No session, an anonymous one, or someone else signed in in another app: follow it.
        store(Self.authSession(from: shared))
        defaults.set(shared.userID, forKey: Self.sharedUserKey)
        return .adopted
    }

    /// Signs out here and in every Hearth app on this device. The next API call starts a new
    /// anonymous session.
    func signOut() {
        if isSignedInWithApple { HearthAccounts.signOutEverywhere() }
        forgetSession()
    }

    /// Forgets this app's session (not the shared one).
    private func forgetSession() {
        Self.deleteStoredSession()
        authSession = nil
        UserDefaults.standard.removeObject(forKey: Self.sharedUserKey)
    }

    /// Shares a signed-in session with the other Hearth apps. Anonymous sessions never are.
    private func share(_ session: AuthSession) {
        guard !ScreenshotMode.isOn, session.user.isAnonymous != true else { return }
        HearthAccounts.saveSession(HearthSharedSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: Double(session.expiresAt),
            userID: session.user.id,
            email: session.user.email,
            updatedBy: Self.hearthApp
        ))
        UserDefaults.standard.set(session.user.id, forKey: Self.sharedUserKey)
    }

    private nonisolated static func authSession(from shared: HearthSharedSession) -> AuthSession {
        AuthSession(
            accessToken: shared.accessToken,
            refreshToken: shared.refreshToken,
            expiresAt: Int(shared.expiresAt),
            user: AuthUser(id: shared.userID, isAnonymous: false, email: shared.email)
        )
    }

    private nonisolated static func tokenHash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func markDead(refreshToken: String) {
        UserDefaults.standard.set(tokenHash(refreshToken), forKey: deadTokenKey)
    }

    private nonisolated static func isDead(refreshToken: String) -> Bool {
        UserDefaults.standard.string(forKey: deadTokenKey) == tokenHash(refreshToken)
    }

    /// "Steve Warren", or nil when Apple didn't send a name (it only does the first time).
    nonisolated static func formatted(_ name: PersonNameComponents?) -> String? {
        guard let name else { return nil }
        let text = PersonNameComponentsFormatter.localizedString(from: name, style: .default)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The name another Hearth app got from Apple for this Apple user, for when Apple doesn't
    /// send it again.
    nonisolated static func sharedAppleName(for appleUserID: String) -> String? {
        guard let shared = HearthAccounts.appleID(), shared.userID == appleUserID else { return nil }
        return shared.fullName
    }

    private nonisolated static func message(from data: Data, status: Int) -> String {
        let detail = try? JSONDecoder().decode(AuthError.self, from: data)
        return detail?.message ?? detail?.msg ?? detail?.errorDescription ?? "The service returned HTTP \(status)."
    }

    private nonisolated static func error(from data: Data, status: Int) -> ClientError {
        .service(message(from: data, status: status))
    }
}

/// Keeps Sated's sign-in in step with the other Hearth apps while it's open: when another app
/// writes (`Hearth.didChange`: signed in, out, or refreshed) and when Sated becomes active.
@MainActor
enum HearthSignIn {
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil, !ScreenshotMode.isOn else { return }
        Hearth.startObservingChanges()
        observer = NotificationCenter.default.addObserver(forName: Hearth.didChange, object: nil, queue: .main) { _ in
            Task { @MainActor in await HearthSignIn.follow() }
        }
    }

    static func follow() async {
        guard !ScreenshotMode.isOn else { return }
        await HearthAPI.shared.followSharedSession()
    }
}
