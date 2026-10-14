import Foundation
import OSLog

/// A menu and where it came from, so the screen can say when it's showing a saved copy.
nonisolated struct MenuResult: Equatable, Sendable {
    var menu: RestaurantMenu
    /// When this device received it.
    var savedAt: Date
    /// The network failed, so this is the copy saved on the device.
    var isOffline: Bool = false
}

/// What the API said about a place: whether it has a menu, and the chain it matched.
nonisolated struct LookupAnswer: Equatable, Sendable {
    var hasMenu: Bool
    var restaurant: String?
}

/// Restaurant menus and "does this place have one" answers, from the Lifestyle API, with a
/// small cache on the device so menus open instantly and still work with a bad connection.
///
/// - A menu is kept for a day (the provider's terms allow no longer) in Caches, so it never
///   goes into iCloud backups. A copy under six hours old is used without asking again.
/// - When the network fails, the saved copy is returned with `isOffline` instead of an error.
/// - Two screens asking for the same menu at once share one request.
/// - Lookups ("is this a chain?") are only names and yes/no, kept for a week (a no for a day).
actor RestaurantStore {
    static let shared = RestaurantStore()

    static let menuLifetime: TimeInterval = 24 * 3600
    static let menuFreshness: TimeInterval = 6 * 3600
    static let lookupLifetime: TimeInterval = 7 * 86_400
    static let missLifetime: TimeInterval = 86_400

    nonisolated private struct SavedMenu: Codable, Sendable {
        var menu: RestaurantMenu
        var savedAt: Date
    }

    nonisolated private struct SavedLookup: Codable, Sendable {
        var hasMenu: Bool
        var savedAt: Date
        /// The matched chain's name. Optional, so lookups saved before it was kept still load.
        var restaurant: String?
    }

    nonisolated private struct LookupBody: Encodable, Sendable {
        var names: [String]
    }

    private let client: APIClient
    private let directory: URL
    private let now: @Sendable () -> Date
    private var menus: [String: SavedMenu] = [:]
    private var lookups: [String: SavedLookup]?
    private var inFlight: [String: Task<RestaurantMenu, Error>] = [:]
    private let log = Logger(subsystem: "com.stephenwarren.sated", category: "restaurants")

    init(client: APIClient = .shared, directory: URL? = nil, now: @escaping @Sendable () -> Date = { Date.now }) {
        self.client = client
        self.now = now
        self.directory = directory ?? URL.cachesDirectory.appending(path: "Restaurants", directoryHint: .isDirectory)
    }

    // MARK: Menus

    /// The saved menu for a place, if one is still within its lifetime. Instant; no network.
    func savedMenu(for name: String) -> MenuResult? {
        guard let saved = loadMenu(key: Self.key(name)) else { return nil }
        return MenuResult(menu: saved.menu, savedAt: saved.savedAt)
    }

    /// Whether a saved menu is old enough (or was already stale on the server) to ask again.
    nonisolated static func needsRefresh(_ result: MenuResult, now: Date = .now) -> Bool {
        result.menu.stale || now.timeIntervalSince(result.savedAt) > menuFreshness
    }

    /// The place's menu: fresh from the API, or the saved copy when the network fails.
    /// Throws only when there's no saved copy to fall back on.
    func menu(for name: String) async throws -> MenuResult {
        let key = Self.key(name)
        let task: Task<RestaurantMenu, Error>
        if let running = inFlight[key] {
            task = running
        } else {
            let client = client
            task = Task {
                try await client.get("/v1/restaurants/menu", query: [URLQueryItem(name: "name", value: Self.apiName(name))]) as RestaurantMenu
            }
            inFlight[key] = task
        }
        do {
            let menu = try await task.value
            inFlight[key] = nil
            let saved = SavedMenu(menu: menu, savedAt: now())
            store(saved, key: key)
            remember(name, hasMenu: menu.hasMenu, restaurant: menu.restaurant)
            return MenuResult(menu: menu, savedAt: saved.savedAt)
        } catch {
            inFlight[key] = nil
            if error is CancellationError { throw error }
            if let saved = loadMenu(key: key) {
                log.notice("Menu request failed (\(String(describing: error), privacy: .public)); using the saved copy")
                return MenuResult(menu: saved.menu, savedAt: saved.savedAt, isOffline: true)
            }
            throw error
        }
    }

    // MARK: Lookups

    /// What's known, without asking: true for a chain with a menu, false for none, nil unknown.
    func knownHasMenu(_ name: String) -> Bool? {
        validLookup(Self.key(name))?.hasMenu
    }

    /// The saved answer for a place, without asking.
    func known(_ name: String) -> LookupAnswer? {
        validLookup(Self.key(name)).map { LookupAnswer(hasMenu: $0.hasMenu, restaurant: $0.restaurant) }
    }

    /// Which of these places have menus. Asks the API only about places it doesn't know yet,
    /// twelve at a time. Places it couldn't find out about are left out of the answer.
    func lookup(_ names: [String]) async -> [String: LookupAnswer] {
        var answers: [String: LookupAnswer] = [:]
        var unknown: [String] = []
        for name in names where !Self.apiName(name).isEmpty {
            if let known = known(name) { answers[name] = known } else if !unknown.contains(name) { unknown.append(name) }
        }
        for start in stride(from: 0, to: unknown.count, by: 12) {
            let batch = Array(unknown[start..<min(start + 12, unknown.count)])
            do {
                let body = LookupBody(names: batch.map(Self.apiName))
                let response: RestaurantLookup = try await client.post("/v1/restaurants/lookup", body: body, retryable: true)
                // One answer per name, in the order sent.
                for (name, item) in zip(batch, response.items) {
                    guard let hasMenu = item.hasMenu else { continue }
                    answers[name] = LookupAnswer(hasMenu: hasMenu, restaurant: item.restaurant)
                    remember(name, hasMenu: hasMenu, restaurant: item.restaurant, save: false)
                }
                saveLookups()
            } catch {
                log.notice("Lookup failed: \(String(describing: error), privacy: .public)")
                break
            }
        }
        return answers
    }

    /// A name as the API accepts it: trimmed, one line, at most 120 characters.
    nonisolated static func apiName(_ name: String) -> String {
        let line = name.components(separatedBy: .controlCharacters).joined(separator: " ")
        return String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    }

    // MARK: Storage

    /// The cache key for a place: the name folded the way the server folds it, so
    /// "Chipotle Mexican Grill" and "chipotle mexican grill" share one entry.
    nonisolated static func key(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "['’`.]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(folded.prefix(100))
    }

    private func menuURL(_ key: String) -> URL {
        directory.appending(path: "menu-\(key.replacingOccurrences(of: " ", with: "-")).json")
    }

    private func loadMenu(key: String) -> SavedMenu? {
        var found = menus[key]
        if found == nil, let data = try? Data(contentsOf: menuURL(key)) {
            found = try? JSONDecoder().decode(SavedMenu.self, from: data)
        }
        guard let saved = found else { return nil }
        guard now().timeIntervalSince(saved.savedAt) < Self.menuLifetime else {
            menus[key] = nil
            try? FileManager.default.removeItem(at: menuURL(key))
            return nil
        }
        menus[key] = saved
        return saved
    }

    private func store(_ saved: SavedMenu, key: String) {
        menus[key] = saved
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: menuURL(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            log.error("Couldn't save a menu: \(error.localizedDescription, privacy: .public)")
        }
        pruneMenus()
    }

    /// Removes menus past their lifetime, so the folder never grows.
    private func pruneMenus() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.lastPathComponent.hasPrefix("menu-") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now().timeIntervalSince(modified) > Self.menuLifetime { try? FileManager.default.removeItem(at: file) }
        }
    }

    private var lookupsURL: URL { directory.appending(path: "lookups.json") }

    private func loadLookupsIfNeeded() {
        guard lookups == nil else { return }
        lookups = (try? Data(contentsOf: lookupsURL)).flatMap { try? JSONDecoder().decode([String: SavedLookup].self, from: $0) } ?? [:]
    }

    private func validLookup(_ key: String) -> SavedLookup? {
        loadLookupsIfNeeded()
        guard let saved = lookups?[key] else { return nil }
        let lifetime = saved.hasMenu ? Self.lookupLifetime : Self.missLifetime
        return now().timeIntervalSince(saved.savedAt) < lifetime ? saved : nil
    }

    private func remember(_ name: String, hasMenu: Bool, restaurant: String?, save: Bool = true) {
        loadLookupsIfNeeded()
        lookups?[Self.key(name)] = SavedLookup(hasMenu: hasMenu, savedAt: now(), restaurant: restaurant)
        if save { saveLookups() }
    }

    private func saveLookups() {
        guard var all = lookups else { return }
        let date = now()
        all = all.filter { date.timeIntervalSince($0.value.savedAt) < ($0.value.hasMenu ? Self.lookupLifetime : Self.missLifetime) }
        lookups = all
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(all).write(to: lookupsURL, options: .atomic)
        } catch {
            log.error("Couldn't save lookups: \(error.localizedDescription, privacy: .public)")
        }
    }
}
