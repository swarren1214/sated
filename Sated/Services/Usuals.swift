import Foundation
import SwiftData

/// The foods someone logs again and again at each meal, for one-tap logging on the Watch.
///
/// A food's score for a meal is the number of days it was logged at that meal, with recent days
/// counting more (a day 30 days ago counts about half as much as today). Logging the same food
/// twice in one meal counts once. Each meal's list is topped up with the person's overall
/// favorites, so a meal they rarely log still offers something.
nonisolated enum Usuals {
    /// A logged food, copied out of SwiftData so ranking can be tested.
    struct Logged: Sendable {
        var date: Date
        var meal: Meal
        var food: WatchFood
    }

    static let lookback = 90
    private static let halfLifeDays = 30.0

    static func rank(_ logged: [Logged], now: Date = .now, perMeal: Int = 8, calendar: Calendar = .current) -> [Meal: [WatchFood]] {
        let today = calendar.startOfDay(for: now)
        guard let since = calendar.date(byAdding: .day, value: -lookback, to: today) else { return [:] }

        struct Tally: Sendable {
            var food: WatchFood
            var latest: Date
            var days: Set<Date> = []
            var score = 0.0
        }
        var byMeal: [Meal: [String: Tally]] = [:]
        var overall: [String: Tally] = [:]

        func count(_ item: Logged, day: Date, weight: Double, into tally: inout Tally?) {
            if tally == nil { tally = Tally(food: item.food, latest: item.date) }
            // The latest log decides the amount, so a usual reflects how much they eat now.
            if item.date > tally!.latest {
                tally!.food = item.food
                tally!.latest = item.date
            }
            if tally!.days.insert(day).inserted { tally!.score += weight }
        }

        for item in logged where item.date >= since && item.date <= now {
            let itemKey = key(for: item.food)
            let day = calendar.startOfDay(for: item.date)
            let age = Double(max(calendar.dateComponents([.day], from: day, to: today).day ?? 0, 0))
            let weight = pow(0.5, age / halfLifeDays)
            count(item, day: day, weight: weight, into: &byMeal[item.meal, default: [:]][itemKey])
            count(item, day: day, weight: weight, into: &overall[itemKey])
        }

        func ordered(_ tallies: [Tally]) -> [Tally] {
            tallies.sorted { $0.score != $1.score ? $0.score > $1.score : $0.latest > $1.latest }
        }
        let favorites = ordered(Array(overall.values))

        var result: [Meal: [WatchFood]] = [:]
        for meal in Meal.allCases {
            var picks = ordered(Array((byMeal[meal] ?? [:]).values)).prefix(perMeal).map(\.food)
            var keys = Set(picks.map(key(for:)))
            for tally in favorites {
                guard picks.count < perMeal else { break }
                if keys.insert(key(for: tally.food)).inserted { picks.append(tally.food) }
            }
            result[meal] = picks.map { food in
                var food = food
                food.id = "\(meal.rawValue).\(key(for: food))"
                return food
            }
        }
        return result
    }

    /// Same food: the same bundled food or barcode, or the same name at the same place.
    static func key(for food: WatchFood) -> String {
        if let foodID = food.foodID, !foodID.hasPrefix("recent.") { return foodID }
        return "\(food.name.lowercased())|\(food.placeName?.lowercased() ?? "")"
    }
}

extension Usuals {
    /// The usuals from the log, for the Watch and Siri.
    @MainActor
    static func current(in context: ModelContext, now: Date = .now, calendar: Calendar = .current) -> [Meal: [WatchFood]] {
        let since = calendar.date(byAdding: .day, value: -lookback, to: calendar.startOfDay(for: now)) ?? now
        let descriptor = FetchDescriptor<FoodEntry>(predicate: #Predicate { $0.date >= since })
        let logged = ((try? context.fetch(descriptor)) ?? []).map {
            Logged(date: $0.date, meal: $0.meal, food: WatchFood(entry: $0))
        }
        return rank(logged, now: now, calendar: calendar)
    }
}
