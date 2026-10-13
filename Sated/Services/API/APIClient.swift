import Foundation
import OSLog

/// What went wrong talking to the API, in terms the app can act on.
nonisolated enum APIError: Error, Equatable, LocalizedError, Sendable {
    /// No internet connection. Not retried: it won't change in a second.
    case offline
    case timedOut
    /// Too many requests; try again after `retryAfter` seconds when known.
    case rateLimited(retryAfter: Int?)
    /// The API or its data provider is having trouble. Usually temporary.
    case unavailable
    /// The server (or a provider behind it) isn't set up for this yet.
    case notConfigured
    case badResponse
    /// Anything else the API refused, by its error code.
    case refused(code: String, status: Int)

    /// A failure getting a token from `LifestyleAPI`.
    init(sessionError error: Error) {
        switch error {
        case let error as APIError: self = error
        case is URLError: self.init(urlError: error)
        case LifestyleAPI.ClientError.rejected:
            // Supabase refused to sign in (anonymous sign-ins are off, or the key is wrong).
            self = .notConfigured
        case LifestyleAPI.ClientError.rateLimited: self = .rateLimited(retryAfter: nil)
        default: self = .unavailable
        }
    }

    init(urlError error: Error) {
        guard let error = error as? URLError else {
            self = (error is CancellationError) ? .unavailable : .badResponse
            return
        }
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            self = .offline
        case .timedOut:
            self = .timedOut
        default:
            self = .unavailable
        }
    }

    /// Whether trying again soon may work.
    var isTransient: Bool {
        switch self {
        case .timedOut, .unavailable: true
        case .rateLimited(let seconds): (seconds ?? 0) <= RetryPolicy.longestWait
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .offline: "You're offline. Connect to the internet and try again."
        case .timedOut: "The connection is slow right now. Try again in a moment."
        case .rateLimited: "Too many requests just now. Try again in a minute."
        case .unavailable: "Menus aren't available right now. Try again in a moment."
        case .notConfigured: "Restaurant menus aren't set up yet."
        case .badResponse: "Something went wrong reading the menu. Try again."
        case .refused: "That request didn't work. Try again."
        }
    }
}

/// When to try a failed request again. Pure, so it's tested directly.
nonisolated enum RetryPolicy {
    /// Three tries in all.
    static let attempts = 3
    /// The longest a Retry-After is honored inline; longer waits are reported instead.
    static let longestWait = 8

    /// How long to wait before attempt `next` (2 or 3) after `error`, or nil to give up.
    static func delay(before next: Int, after error: APIError, jitter: Double = .random(in: 0.8...1.2)) -> Duration? {
        guard next <= attempts, error.isTransient else { return nil }
        if case .rateLimited(let seconds?) = error {
            return .seconds(max(1, seconds))
        }
        // 0.6 s, then 1.2 s, give or take a fifth so many devices don't retry in step.
        return .milliseconds(Int(600 * pow(2, Double(next - 2)) * jitter))
    }
}

/// Talks to the shared Lifestyle API: attaches the session's token from `LifestyleAPI`, retries
/// what's safe to retry, renews a rejected token once, and turns every failure into an
/// `APIError`.
nonisolated struct APIClient: Sendable {
    static let shared = APIClient()

    nonisolated private struct ErrorEnvelope: Decodable, Sendable {
        nonisolated struct Body: Decodable, Sendable { var code: String; var requestId: String? }
        var error: Body
    }

    var baseURL: URL = AppConfig.apiBaseURL
    var urlSession: URLSession = APIClient.makeSession()
    var session: LifestyleAPI = .shared
    private static let log = Logger(subsystem: "com.stephenwarren.sated", category: "api")

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func get<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        let url = components.url!
        return try await send(retryable: true) { token in
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    /// A POST. `retryable` only for requests that change nothing (lookups).
    func post<T: Decodable & Sendable, Body: Encodable & Sendable>(_ path: String, body: Body, retryable: Bool) async throws -> T {
        let url = baseURL.appending(path: path)
        let data = try JSONEncoder().encode(body)
        return try await send(retryable: retryable) { token in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    private func send<T: Decodable>(retryable: Bool, _ make: (String) -> URLRequest) async throws -> T {
        var attempt = 1
        var renewedToken = false
        var renew = false
        while true {
            try Task.checkCancellation()
            do {
                let current = try await token(renew: renew)
                renew = false
                return try await perform(make(current))
            } catch APIError.refused(code: "UNAUTHORIZED", status: 401) where !renewedToken {
                // The token was rejected (revoked, or the project's keys rotated): renew once.
                renewedToken = true
                renew = true
                continue
            } catch let error as APIError {
                attempt += 1
                guard retryable, let wait = RetryPolicy.delay(before: attempt, after: error) else { throw error }
                Self.log.info("Retrying after \(String(describing: error), privacy: .public) (attempt \(attempt))")
                try await Task.sleep(for: wait)
            }
        }
    }

    private func token(renew: Bool = false) async throws -> String {
        do {
            return try await session.accessToken(renew: renew)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError(sessionError: error)
        }
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw APIError(urlError: error)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        let requestID = http.value(forHTTPHeaderField: "X-Request-ID") ?? "-"

        if (200..<300).contains(http.statusCode) {
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                Self.log.error("Couldn't decode \(request.url?.path() ?? "", privacy: .public) [\(requestID, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
                throw APIError.badResponse
            }
        }

        let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.code ?? "HTTP_\(http.statusCode)"
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
        Self.log.notice("\(request.url?.path() ?? "", privacy: .public) → \(http.statusCode) \(code, privacy: .public) [\(requestID, privacy: .public)]")
        throw Self.error(status: http.statusCode, code: code, retryAfter: retryAfter)
    }

    /// The API's documented statuses and codes, as app errors.
    static func error(status: Int, code: String, retryAfter: Int?) -> APIError {
        switch (status, code) {
        case (401, _): .refused(code: "UNAUTHORIZED", status: 401)
        case (429, _): .rateLimited(retryAfter: retryAfter)
        case (503, "PROVIDER_NOT_CONFIGURED"), (503, "QUOTA_NOT_CONFIGURED"), (503, "AUTH_NOT_CONFIGURED"), (503, "STORAGE_NOT_CONFIGURED"):
            .notConfigured
        case (503, "PROVIDER_QUOTA_EXCEEDED"): .rateLimited(retryAfter: retryAfter ?? 60)
        case (504, _): .timedOut
        case (500, _), (502, _), (503, _): .unavailable
        default: .refused(code: code, status: status)
        }
    }
}
