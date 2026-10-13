import AuthenticationServices
import CryptoKit
import Foundation
import OSLog
import Security

actor LifestyleAPI {
    static let shared = LifestyleAPI()

    struct Identity: Decodable, Sendable {
        let id: String
    }

    private struct AuthUser: Codable, Sendable {
        let id: String
        let isAnonymous: Bool?

        enum CodingKeys: String, CodingKey {
            case id
            case isAnonymous = "is_anonymous"
        }
    }

    private struct AuthSession: Codable, Sendable {
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

    private struct AuthError: Decodable {
        let msg: String?
        let message: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case msg, message
            case errorDescription = "error_description"
        }
    }

    enum ClientError: LocalizedError {
        case invalidResponse
        case service(String)
        case missingAppleToken
        case missingAppleNonce

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "The identity service returned an invalid response."
            case .service(let message): message
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

    init(session: URLSession = .shared) {
        self.session = session
        authSession = Self.loadSession()
    }

    func prepareSession() async {
        do {
            _ = try await identity()
        } catch {
            Self.log.error("API session setup failed: \(error.localizedDescription, privacy: .public)")
        }
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
        try store(newSession)
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
        var current = try await validSession()
        var result = try await apiRequest(path: path, method: method, body: body, accessToken: current.accessToken)
        if result.response.statusCode == 401 {
            current = try await refresh(current.refreshToken)
            result = try await apiRequest(path: path, method: method, body: body, accessToken: current.accessToken)
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

    private func validSession() async throws -> AuthSession {
        if let authSession, authSession.expiresAt > Int(Date().timeIntervalSince1970) + 60 {
            return authSession
        }
        if let refreshToken = authSession?.refreshToken {
            do { return try await refresh(refreshToken) }
            catch {
                Self.deleteStoredSession()
                authSession = nil
            }
        }
        return try await signInAnonymously()
    }

    private func signInAnonymously() async throws -> AuthSession {
        let newSession: AuthSession = try await auth(path: "/auth/v1/signup", body: Data("{}".utf8))
        try store(newSession)
        return newSession
    }

    private func refresh(_ refreshToken: String) async throws -> AuthSession {
        let body = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        let refreshed: AuthSession = try await auth(path: "/auth/v1/token?grant_type=refresh_token", body: body)
        try store(refreshed)
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
        guard (200..<300).contains(response.statusCode) else { throw Self.error(from: data, status: response.statusCode) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ClientError.invalidResponse }
    }

    private func store(_ session: AuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw ClientError.service("Could not securely save the API session.")
            }
        } else if updateStatus != errSecSuccess {
            throw ClientError.service("Could not securely update the API session.")
        }
        authSession = session
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

    private nonisolated static func error(from data: Data, status: Int) -> ClientError {
        let detail = try? JSONDecoder().decode(AuthError.self, from: data)
        let message = detail?.message ?? detail?.msg ?? detail?.errorDescription
        return .service(message ?? "The service returned HTTP \(status).")
    }
}
