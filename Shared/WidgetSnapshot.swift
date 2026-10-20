import Foundation

/// What the widgets show: today's totals, goals, meals, the last seven days and the streak.
///
/// The app writes it to the shared App Group folder whenever the log or goals change; the
/// widgets only read it. Compiled into both the app and the widget extension.
nonisolated struct WidgetSnapshot: Codable, Hashable, Sendable {
    static let groupID = "group.com.stephenwarren.sated"
    static let fileName = "widget-snapshot.json"

    struct MealLine: Codable, Hashable, Sendable, Identifiable {
        var name: String
        var symbol: String
        var calories: Double
        var logged: Bool
        var id: String { name }
    }

    struct DayLine: Codable, Hashable, Sendable, Identifiable {
        var date: Date
        var calories: Double
        var id: Date { date }
    }

    /// An sRGB color, so the widget can use the accent picked in the app.
    struct RGB: Codable, Hashable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
    }

    /// The start of the day the totals are for.
    var day: Date
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var fiber: Double
    var goalCalories: Double
    var goalProtein: Double
    var goalCarbs: Double
    var goalFat: Double
    var goalFiber: Double
    var meals: [MealLine]
    /// Seven days, oldest first, ending with `day`.
    var week: [DayLine]
    var streak: Int
    var accent: RGB

    var caloriesLeft: Double { goalCalories - calories }

    // MARK: Reading and writing

    static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appending(path: fileName)
    }

    static func load() -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    /// The snapshot as it should look on `date`. After midnight, before the app has run, the
    /// new day starts empty: totals at zero, meals open, the week moved along by a day.
    func asOf(_ date: Date, calendar: Calendar = .current) -> WidgetSnapshot {
        let today = calendar.startOfDay(for: date)
        guard today > day else { return self }
        var fresh = self
        fresh.day = today
        fresh.calories = 0
        fresh.protein = 0
        fresh.carbs = 0
        fresh.fat = 0
        fresh.fiber = 0
        fresh.meals = meals.map { MealLine(name: $0.name, symbol: $0.symbol, calories: 0, logged: false) }
        var days = week
        var next = calendar.date(byAdding: .day, value: 1, to: day) ?? today
        while next <= today {
            days.append(DayLine(date: next, calories: 0))
            next = calendar.date(byAdding: .day, value: 1, to: next) ?? today.addingTimeInterval(86_400)
        }
        fresh.week = Array(days.suffix(7))
        // Yesterday still counts toward the streak; an older gap ends it.
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day < yesterday {
            fresh.streak = 0
        }
        return fresh
    }

    /// Shown in the widget gallery and before the app has written anything.
    static let sample: WidgetSnapshot = {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let week = (0..<7).map { offset -> DayLine in
            let date = calendar.date(byAdding: .day, value: offset - 6, to: today) ?? today
            return DayLine(date: date, calories: [2180, 2390, 2050, 2620, 2310, 2240, 1278][offset])
        }
        return WidgetSnapshot(
            day: today,
            calories: 1278, protein: 112, carbs: 131, fat: 41, fiber: 22,
            goalCalories: 2400, goalProtein: 180, goalCarbs: 240, goalFat: 75, goalFiber: 35,
            meals: [
                MealLine(name: "Breakfast", symbol: "sunrise.fill", calories: 412, logged: true),
                MealLine(name: "Lunch", symbol: "sun.max.fill", calories: 618, logged: true),
                MealLine(name: "Snack", symbol: "carrot.fill", calories: 248, logged: true),
                MealLine(name: "Dinner", symbol: "moon.stars.fill", calories: 0, logged: false),
            ],
            week: week,
            streak: 12,
            accent: RGB(red: 0xDA / 255, green: 0x83 / 255, blue: 0x00 / 255)
        )
    }()
}

/// Links the widgets open. The app handles them in `AppRoot`.
nonisolated enum SatedLink {
    static let today = URL(string: "sated://today")!
    static let addFood = URL(string: "sated://add")!
    static let trends = URL(string: "sated://trends")!
}
