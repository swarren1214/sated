import Foundation
import SwiftData

/// A restaurant the person has logged food at.
nonisolated struct Spot: Identifiable, Hashable, Sendable {
    var place: PlaceRef
    /// Distinct days with food logged there.
    var visits: Int
    var lastVisit: Date

    var id: String { place.id }

    /// "6 visits · last Oct 3"
    var detail: String {
        let last = Calendar.current.isDateInToday(lastVisit) ? "today" : "last \(lastVisit.formatted(.dateTime.month(.abbreviated).day()))"
        return "\(visits == 1 ? "1 visit" : "\(visits) visits") · \(last)"
    }
}

/// Something the person often orders at a place, ready to log again from what was saved.
nonisolated struct Usual: Identifiable, Hashable, Sendable {
    var food: FoodItem
    var servings: Double
    var times: Int

    var id: String { food.id }
}

/// Eating-out history read from the log: everything here comes from the person's own
/// entries, so it works offline and needs nothing from the server.
enum EatingOutHistory {
    /// How far back to look.
    static let window = 180

    private static func entries(in context: ModelContext, limit: Int = 600) -> [FoodEntry] {
        let start = Calendar.current.date(byAdding: .day, value: -window, to: .now) ?? .distantPast
        var descriptor = FetchDescriptor<FoodEntry>(
            predicate: #Predicate { $0.date >= start && $0.placeName != nil },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func matches(_ entry: FoodEntry, _ place: PlaceRef) -> Bool {
        if let id = entry.placeID, id == place.id { return true }
        return entry.placeName.map { RestaurantStore.key($0) == RestaurantStore.key(place.name) } ?? false
    }

    /// Places the person has eaten at, most visited first.
    static func spots(in context: ModelContext, limit: Int = 6) -> [Spot] {
        var byKey: [String: (place: PlaceRef, days: Set<Date>, last: Date)] = [:]
        for entry in entries(in: context) {
            guard let place = entry.place else { continue }
            let key = RestaurantStore.key(place.name)
            let day = Calendar.current.startOfDay(for: entry.date)
            var spot = byKey[key] ?? (place, [], entry.date)
            spot.days.insert(day)
            spot.last = max(spot.last, entry.date)
            byKey[key] = spot
        }
        return byKey.values
            .map { Spot(place: $0.place, visits: $0.days.count, lastVisit: $0.last) }
            .sorted { ($0.visits, $0.lastVisit) > ($1.visits, $1.lastVisit) }
            .prefix(limit)
            .map { $0 }
    }

    /// What the person orders here most, as logged (amount included).
    static func usuals(at place: PlaceRef, in context: ModelContext, limit: Int = 3) -> [Usual] {
        var counts: [String: (entry: FoodEntry, times: Int)] = [:]
        for entry in entries(in: context) where matches(entry, place) {
            let key = entry.foodID ?? entry.name.lowercased()
            if let existing = counts[key] {
                counts[key] = (existing.entry, existing.times + 1)
            } else {
                counts[key] = (entry, 1)  // newest first, so this is the latest way it was logged
            }
        }
        return counts.values
            .sorted { ($0.times, $0.entry.date) > ($1.times, $1.entry.date) }
            .prefix(limit)
            .map { Usual(food: food(from: $0.entry), servings: $0.entry.servings, times: $0.times) }
    }

    /// Everything logged on the most recent day at this place.
    static func lastVisit(at place: PlaceRef, in context: ModelContext) -> [FoodEntry] {
        let here = entries(in: context).filter { matches($0, place) }
        guard let latest = here.first else { return [] }
        return here.filter { Calendar.current.isDate($0.date, inSameDayAs: latest.date) }.reversed()
    }

    /// An entry as a food to log again.
    static func food(from entry: FoodEntry) -> FoodItem {
        FoodItem(
            id: entry.foodID ?? "place.\(entry.id.uuidString)",
            name: entry.name,
            brand: entry.brand,
            serving: entry.servingLabel,
            nutrients: entry.perServing,
            source: entry.source
        )
    }
}
