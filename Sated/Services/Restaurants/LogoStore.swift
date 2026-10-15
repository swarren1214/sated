import CryptoKit
import Foundation
import OSLog
import UIKit

/// What to find a logo by: the place's own website domain (most accurate), or the name of the
/// chain it matched. Never a raw place name, which could match an unrelated company.
nonisolated struct LogoKey: Hashable, Sendable {
    var domain: String?
    var name: String?

    init?(domain: String?, chain: String?) {
        let chain = chain?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard domain != nil || !(chain ?? "").isEmpty else { return nil }
        self.domain = domain
        self.name = domain == nil ? chain : nil
    }

    /// Stable across launches: "d:chipotle.com" or "n:chipotle".
    var id: String {
        if let domain { return "d:\(domain)" }
        return "n:\(RestaurantStore.key(name ?? ""))"
    }
}

/// Restaurant logos from Logo.dev, through the Hearth API (`POST /v1/brands/logos`), which
/// turns domains and chain names into CDN image URLs.
///
/// - Logos are saved in Caches for 30 days and show offline. A "no logo" answer is kept for
///   three days, so missing logos aren't asked for on every scroll.
/// - Badges asking at the same moment are gathered into one API request (up to 24 at a time).
/// - The same logo is never downloaded twice at once.
/// - Any failure leaves the initials badge in place: logos are decoration, never a blocker.
actor LogoStore {
    static let shared = LogoStore()

    static let imageLifetime: TimeInterval = 30 * 86_400
    static let missingLifetime: TimeInterval = 3 * 86_400
    /// After a failed request, how long to leave that logo (or the API) alone.
    static let retryAfter: TimeInterval = 120
    /// Points of the largest badge × 3, rounded up.
    static let pixelSize = 160

    nonisolated private struct Request: Encodable, Sendable {
        nonisolated struct Item: Encodable, Sendable {
            var id: String
            var domain: String?
            var name: String?
        }
        var items: [Item]
        var size: Int
        var format = "png"
    }

    nonisolated private struct Response: Decodable, Sendable {
        nonisolated struct Item: Decodable, Sendable {
            var id: String
            var url: String
        }
        var items: [Item]
    }

    private let client: APIClient
    private let directory: URL
    private let urlSession: URLSession
    private var memory: [String: UIImage] = [:]
    private var urls: [String: URL] = [:]
    private var downloads: [String: Task<UIImage?, Never>] = [:]
    private var failedAt: [String: Date] = [:]
    private var apiFailedAt: Date?
    /// Logos gathered for the next API request, by batch number.
    private var batches: [Int: [String: LogoKey]] = [:]
    private var openBatch: (number: Int, task: Task<[String: URL], Never>)?
    private var nextBatch = 0
    private let log = Logger(subsystem: "com.stephenwarren.sated", category: "logos")

    init(client: APIClient = .shared, directory: URL? = nil) {
        self.client = client
        self.directory = directory ?? URL.cachesDirectory.appending(path: "Logos", directoryHint: .isDirectory)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        urlSession = URLSession(configuration: configuration)
    }

    /// The logo for `key`, or nil when there's none (or it can't be fetched right now).
    func image(for key: LogoKey) async -> UIImage? {
        let id = key.id
        if let image = memory[id] { return image }
        if let image = savedImage(id) {
            memory[id] = image
            return image
        }
        if isMarkedMissing(id) { return nil }
        if let failed = failedAt[id], Date.now.timeIntervalSince(failed) < Self.retryAfter { return nil }
        if let running = downloads[id] { return await running.value }
        let task = Task { await self.fetch(key) }
        downloads[id] = task
        let image = await task.value
        downloads[id] = nil
        return image
    }

    // MARK: Fetching

    private func fetch(_ key: LogoKey) async -> UIImage? {
        let id = key.id
        guard let url = await resolve(key) else {
            failedAt[id] = .now
            return nil
        }
        do {
            let (data, response) = try await urlSession.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 {
                markMissing(id)
                return nil
            }
            guard status == 200, data.count <= 1_000_000, let image = UIImage(data: data) else {
                failedAt[id] = .now
                return nil
            }
            save(data, id: id)
            memory[id] = image
            return image
        } catch {
            failedAt[id] = .now
            return nil
        }
    }

    /// The CDN URL for a logo: remembered, or asked for together with any other logos wanted
    /// in the next moment.
    private func resolve(_ key: LogoKey) async -> URL? {
        let id = key.id
        if let url = urls[id] { return url }
        if let failed = apiFailedAt, Date.now.timeIntervalSince(failed) < Self.retryAfter { return nil }
        // Join the request that's gathering, or start one.
        let task: Task<[String: URL], Never>
        if let open = openBatch, (batches[open.number]?.count ?? 24) < 24 {
            batches[open.number]?[id] = key
            task = open.task
        } else {
            let number = nextBatch
            nextBatch += 1
            batches[number] = [id: key]
            task = Task {
                // Let the other badges on screen join this request.
                try? await Task.sleep(for: .milliseconds(60))
                return await self.send(batch: number)
            }
            openBatch = (number, task)
        }
        return await task.value[id]
    }

    /// Sends one gathered batch and remembers the URLs that came back.
    private func send(batch number: Int) async -> [String: URL] {
        if openBatch?.number == number { openBatch = nil }
        guard let keys = batches.removeValue(forKey: number), !keys.isEmpty else { return [:] }
        let body = Request(
            items: keys.map { Request.Item(id: $0.key, domain: $0.value.domain, name: $0.value.name) },
            size: Self.pixelSize
        )
        var found: [String: URL] = [:]
        do {
            let response: Response = try await client.post("/v1/brands/logos", body: body, retryable: true)
            for item in response.items {
                // Only Logo.dev's CDN, whatever the response says.
                if let url = URL(string: item.url), url.scheme == "https", url.host() == "img.logo.dev" { found[item.id] = url }
            }
            urls.merge(found) { $1 }
            apiFailedAt = nil
        } catch {
            log.notice("Logo lookup failed: \(String(describing: error), privacy: .public)")
            apiFailedAt = .now
        }
        return found
    }

    // MARK: Storage

    private func fileURL(_ id: String, missing: Bool = false) -> URL {
        let hash = SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: missing ? "\(hash).missing" : "\(hash).png")
    }

    private func age(of file: URL) -> TimeInterval? {
        guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        return Date.now.timeIntervalSince(modified)
    }

    private func savedImage(_ id: String) -> UIImage? {
        let file = fileURL(id)
        guard let age = age(of: file) else { return nil }
        guard age < Self.imageLifetime, let data = try? Data(contentsOf: file), let image = UIImage(data: data) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return image
    }

    private func isMarkedMissing(_ id: String) -> Bool {
        let file = fileURL(id, missing: true)
        guard let age = age(of: file) else { return false }
        if age < Self.missingLifetime { return true }
        try? FileManager.default.removeItem(at: file)
        return false
    }

    private func save(_ data: Data, id: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(id), options: .atomic)
            try? FileManager.default.removeItem(at: fileURL(id, missing: true))
        } catch {
            log.error("Couldn't save a logo: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func markMissing(_ id: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data().write(to: fileURL(id, missing: true), options: .atomic)
    }
}
