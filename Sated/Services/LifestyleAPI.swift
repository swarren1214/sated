import AuthenticationServices
import CryptoKit
import Foundation
import OSLog
import Security

/// The app's identity with the shared Lifestyle API: a silent anonymous Supabase session (or
/// Sign in with Apple), kept in the Keychain. `APIClient` asks it for tokens.
///
/// Reliability:
/// - A token is reused until a minute before it expires.
/// - Only one sign-in or refresh runs at a time; everyone else waits for it. (Two refreshes
///   at once would spend the same refresh token twice, and Supabase rejects the second.)
/// - A new anonymous user is created only when Supabase rejects the refresh token, never
///   because the network or Supabase failed, so a bad connection can't churn identities.
/// - If the Keychain can't be written, the session still works for this launch.
actor LifestyleAPI {
    static let shared = LifestyleAPI()

    nonisolated struct Identity: Decodable, Sendable {
        let id: String
    }

    nonisolated private struct AuthUser: Codable, Sendable {
        let id: String
        let isAnonymous: Bool?

        enum CodingKeys: String, CodingKey {
            case id
            case isAnonymous = "is_anonymous"
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

    private static let keychainService = "com.stephenwarren.lifestyle.supabase"
    private static let keychainAccount = "session"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lifestyle", category: "api")

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
        let task = Task { try await self.obtainSession() }
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

    func signInWithApple(identityToken: Data?, nonce: String?) async throws {
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
    private func obtainSession() async throws -> AuthSession {
        if let refreshToken = authSession?.refreshToken {
            do {
                return try await refresh(refreshToken)
            } catch ClientError.rejected(let message) {
                Self.log.notice("Refresh token rejected (\(message, privacy: .public)); starting a new anonymous session")
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

    private nonisolated static func message(from data: Data, status: Int) -> String {
        let detail = try? JSONDecoder().decode(AuthError.self, from: data)
        return detail?.message ?? detail?.msg ?? detail?.errorDescription ?? "The service returned HTTP \(status)."
    }

    private nonisolated static func error(from data: Data, status: Int) -> ClientError {
        .service(message(from: data, status: status))
    }
}
