import Foundation
import OSLog
import SwiftData
import WatchConnectivity

/// The iPhone's side of the Watch app.
///
/// The phone keeps the log; the Watch never stores entries of its own. Whenever the log or the
/// goals change, the phone sends the Watch a fresh `WatchSnapshot` as its application context
/// (the system delivers only the latest one, even if the Watch was asleep). The Watch sends back:
/// - log requests through `transferUserInfo`, which the system queues until the phone is in
///   range. Each has an ID, so one that arrives twice is filed once.
/// - dictation to parse, through `sendMessage`. This wakes the app in the background, runs the
///   same on-device parsing as Say It, and replies with the matched foods.
final class WatchBridge: NSObject {
    static let shared = WatchBridge()

    private var container: ModelContainer?
    private var lastSent: Data?
    private var pending: Task<Void, Never>?
    private let log = Logger(subsystem: "com.stephenwarren.sated", category: "watch")

    /// The Watch log requests already filed, newest last.
    private static let appliedKey = "watch.appliedLogIDs"
    private static let appliedLimit = 200

    func start(container: ModelContainer) {
        guard self.container == nil, WCSession.isSupported() else { return }
        self.container = container
        // A background launch for the Watch has no scene; start loading the foods now.
        _ = FoodDatabase.shared
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Coalesces bursts, like several voice items saved at once.
    func schedule() {
        guard container != nil else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            push()
        }
    }

    /// Sends the Watch the latest now, without the usual short wait. For Siri, which may be
    /// suspended right after it logs.
    func refreshNow() {
        pending?.cancel()
        push()
    }

    private func push(force: Bool = false) {
        let session = WCSession.default
        guard let container, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        do {
            let snapshot = makeSnapshot(context: container.mainContext)
            let data = try WatchLink.encode(snapshot)
            guard force || data != lastSent else { return }
            try session.updateApplicationContext([WatchLink.kindKey: WatchLink.Kind.snapshot.rawValue, WatchLink.payloadKey: data])
            lastSent = data
        } catch {
            log.error("Couldn't update the Watch: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Snapshot

    func makeSnapshot(context: ModelContext, now: Date = .now, calendar: Calendar = .current) -> WatchSnapshot {
        let today = WidgetSync.makeSnapshot(context: context, now: now, calendar: calendar)
        let usuals = Usuals.current(in: context, now: now, calendar: calendar)
        return WatchSnapshot(
            day: today.day,
            calories: today.calories,
            protein: today.protein,
            carbs: today.carbs,
            fat: today.fat,
            fiber: today.fiber,
            goalCalories: today.goalCalories,
            goalProtein: today.goalProtein,
            goalCarbs: today.goalCarbs,
            goalFat: today.goalFat,
            goalFiber: today.goalFiber,
            usuals: Dictionary(uniqueKeysWithValues: usuals.map { ($0.key.rawValue, $0.value) }),
            appliedLogIDs: appliedIDs,
            accent: today.accent
        )
    }

    // MARK: Logging

    private var appliedIDs: [UUID] {
        get { (UserDefaults.standard.stringArray(forKey: Self.appliedKey) ?? []).compactMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue.suffix(Self.appliedLimit).map(\.uuidString), forKey: Self.appliedKey) }
    }

    /// Files foods logged on the Watch, once, then tells the Watch they're in.
    func apply(_ request: WatchLogRequest) {
        guard let container else { return }
        guard !appliedIDs.contains(request.id) else {
            push(force: true)
            return
        }
        let context = container.mainContext
        let meal = Meal(rawValue: request.meal) ?? .suggested(for: request.date)
        for food in request.foods where food.servings > 0 {
            FoodLog.add(food, meal: meal, date: request.date, in: context)
        }
        appliedIDs.append(request.id)
        log.info("Filed \(request.foods.count) foods from the Watch")
        schedule()
    }

    // MARK: Parsing

    /// Turns dictation into foods with the same parser as Say It. When the on-device model isn't
    /// available (or fails), falls back to searching the database for the whole phrase.
    func parse(_ text: String) async -> WatchParseReply {
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return WatchParseReply(error: "Didn't catch anything. Try again.") }

        // Logging by voice or a sentence (the Watch's Say It, Siri's Log Food) is Sated Plus or
        // Hearth+. Woken in the background, the plan may not be read yet: check, but wait at
        // most two seconds so the Watch and Siri still get an answer in time.
        let purchases = HearthPurchases.shared
        if !purchases.isUnlocked, purchases.isConfigured {
            Task { await purchases.refresh() }
            for _ in 0..<10 where !purchases.isUnlocked {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        guard purchases.isUnlocked else {
            return WatchParseReply(error: "Logging by voice is part of Sated Plus and Hearth+. Open Sated on your iPhone to try it free.")
        }

        // Woken in the background, the bundled foods may still be loading.
        let database = FoodDatabase.shared
        for _ in 0..<30 where !database.isLoaded {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard database.isLoaded else { return WatchParseReply(error: "Sated is still starting on your iPhone. Try again in a moment.") }

        if OnDeviceModel.availability == .available {
            do {
                // The Watch stops waiting for a reply after a while; leave time for the fallback.
                // A restaurant's menu is usually saved on the phone already; asking for a new one
                // waits a few seconds at most.
                let context = container?.mainContext
                let parsing = Task { () async throws -> WatchParseReply in
                    let result = try await MealParser.parse(transcript, database: database, context: context)
                    var approximate: [String] = []
                    let foods = result.items.compactMap { item -> WatchFood? in
                        guard let food = item.food else { return nil }
                        var watchFood = WatchFood(food: food, servings: item.servings)
                        watchFood.placeID = item.place?.id
                        watchFood.placeName = item.place?.name
                        if item.isApproximate { approximate.append(watchFood.id) }
                        return watchFood
                    }
                    let unmatched = result.items.filter { $0.food == nil }.map(\.spoken)
                    return WatchParseReply(
                        meal: result.meal?.rawValue,
                        foods: foods,
                        unmatched: unmatched,
                        approximate: approximate.isEmpty ? nil : approximate,
                        daysAgo: result.daysAgo == 0 ? nil : result.daysAgo
                    )
                }
                // The model, then restaurant menus (at most `SpokenFoodMatcher.menuWait`).
                let limit = Task {
                    try? await Task.sleep(for: .seconds(14))
                    parsing.cancel()
                }
                defer { limit.cancel() }
                let reply = try await parsing.value
                if !reply.foods.isEmpty || !reply.unmatched.isEmpty { return reply }
            } catch {
                log.error("Watch parse failed, searching instead: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let match = database.search(transcript, limit: 1).first {
            return WatchParseReply(foods: [WatchFood(food: match, servings: 1)])
        }
        return WatchParseReply(error: "Couldn't find that. Try naming each food and how much.")
    }
}

// MARK: - WCSessionDelegate

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.push(force: true) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// After switching to a different Watch: activate again so the new one gets updates.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// The Watch app was installed or the Watch was paired: send it everything.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.push(force: true) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard WatchLink.kind(of: userInfo) == .log else { return }
        let data = WatchLink.payload(of: userInfo)
        Task { @MainActor in
            guard let request = WatchLink.decode(WatchLogRequest.self, from: data) else { return }
            self.apply(request)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = Reply(send: replyHandler)
        guard WatchLink.kind(of: message) == .parse else {
            reply.send([:])
            return
        }
        let data = WatchLink.payload(of: message)
        Task { @MainActor in
            let result: WatchParseReply
            if let request = WatchLink.decode(WatchParseRequest.self, from: data) {
                result = await self.parse(request.text)
            } else {
                result = WatchParseReply(error: "Update Sated on your iPhone and Watch, then try again.")
            }
            reply.send((try? WatchLink.message(.parse, result)) ?? [:])
        }
    }
}

/// WatchConnectivity's reply handler, carried to the main actor. It's safe to call from any thread.
nonisolated private struct Reply: @unchecked Sendable {
    let send: ([String: Any]) -> Void
}

// MARK: - Conversions

extension WatchFood {
    var nutrients: Nutrients {
        Nutrients(calories: calories, protein: protein, carbs: carbs, fat: fat, fiber: fiber)
    }

    var place: PlaceRef? {
        placeName.map { PlaceRef(id: placeID ?? $0, name: $0) }
    }

    @MainActor init(entry: FoodEntry) {
        self.init(
            id: entry.id.uuidString,
            foodID: entry.foodID,
            name: entry.name,
            brand: entry.brand,
            serving: entry.servingLabel,
            servings: entry.servings,
            calories: entry.caloriesPerServing,
            protein: entry.proteinPerServing,
            carbs: entry.carbsPerServing,
            fat: entry.fatPerServing,
            fiber: entry.fiberPerServing,
            source: entry.sourceRaw,
            placeID: entry.placeID,
            placeName: entry.placeName
        )
    }

    init(food: FoodItem, servings: Double) {
        self.init(
            id: "\(food.id).\(UUID().uuidString)",
            foodID: food.id,
            name: food.name,
            brand: food.brand,
            serving: food.servingText,
            servings: servings,
            calories: food.calories,
            protein: food.protein,
            carbs: food.carbs,
            fat: food.fat,
            fiber: food.fiber,
            source: food.source.rawValue
        )
    }
}
