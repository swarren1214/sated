import Foundation
import SwiftData

/// What Siri and Shortcuts actually do, on the main actor with the app's store. The intents in
/// `SatedIntents.swift` only collect parameters and speak the results.
///
/// Siri can run these with the app closed. Each one makes sure the widgets and the Watch are
/// watching the store first, and pushes them the new totals right away, because the app may be
/// suspended a moment after Siri finishes.
enum IntentActions {
    private static var context: ModelContext {
        let container = Persistence.shared
        WidgetSync.start(container: container)
        WatchBridge.shared.start(container: container)
        return container.mainContext
    }

    /// Pushes new totals to the widgets and the Watch.
    private static func refreshOthers() {
        WidgetSync.refreshNow()
        WatchBridge.shared.refreshNow()
    }

    // MARK: Usuals

    static func usuals(for meal: Meal) -> [WatchFood] {
        Usuals.current(in: context)[meal] ?? []
    }

    /// Usuals by ID, from any meal. A food that has dropped out of the usuals isn't found.
    static func usuals(ids: [String]) -> [WatchFood] {
        let all = Usuals.current(in: context).values.joined()
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    // MARK: Logging

    /// Logs foods for today and returns what's left afterwards. Waits for Apple Health, since
    /// the app may be suspended as soon as Siri is done.
    @discardableResult
    static func log(_ foods: [WatchFood], meal: Meal) async -> TodayStatus {
        let context = context
        var records: [EntryRecord] = []
        for food in foods where food.servings > 0 {
            records.append(FoodLog.add(food, meal: meal, saveToHealth: false, in: context).record)
        }
        try? context.save()
        refreshOthers()
        let status = today()
        for record in records {
            await HealthService.shared.save(record)
        }
        return status
    }

    // MARK: Today

    static func today() -> TodayStatus {
        let snapshot = WidgetSync.makeSnapshot(context: context)
        return TodayStatus(
            calories: snapshot.calories,
            protein: snapshot.protein,
            goalCalories: snapshot.goalCalories,
            goalProtein: snapshot.goalProtein
        )
    }

    // MARK: Parsing

    /// The same parsing as Say It and the Watch: the on-device model when it's available, a
    /// database search otherwise.
    static func parse(_ text: String) async -> WatchParseReply {
        // Launched by Siri, the bundled foods take a moment to load.
        let database = FoodDatabase.shared
        for _ in 0..<80 where !database.isLoaded {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard database.isLoaded else {
            return WatchParseReply(error: "Sated is still starting. Try again in a moment.")
        }
        return await WatchBridge.shared.parse(text)
    }
}

/// Today's calories and protein against the goals, and how Siri says them.
nonisolated struct TodayStatus: Equatable, Sendable {
    var calories: Double
    var protein: Double
    var goalCalories: Double
    var goalProtein: Double

    var caloriesLeft: Double { goalCalories - calories }
    var proteinLeft: Double { goalProtein - protein }

    /// "You have 1,240 calories left today, and 62 grams of protein to go."
    var spoken: String {
        let left = Int(caloriesLeft.rounded())
        let calories = left >= 0
            ? "You have \(left.formatted()) \(left == 1 ? "calorie" : "calories") left today"
            : "You're \((-left).formatted()) \(left == -1 ? "calorie" : "calories") over today"
        let protein = Int(proteinLeft.rounded())
        guard protein > 0 else { return calories + ", and you've hit your protein goal." }
        return calories + ", and \(protein) \(protein == 1 ? "gram" : "grams") of protein to go."
    }
}

/// How Siri describes foods.
nonisolated enum SpokenFoods {
    /// "2 large eggs and a slice of sourdough" style, from the foods' names and amounts:
    /// "Large egg (2), Sourdough bread and Coffee".
    static func list(_ foods: [WatchFood]) -> String {
        let names = foods.map { food in
            food.servings == 1 ? food.name : "\(food.name) (\(food.servings.formatted(.number.precision(.fractionLength(0...2)))))"
        }
        return ListFormatter.localizedString(byJoining: names)
    }

    static func calories(_ foods: [WatchFood]) -> Int {
        Int(foods.reduce(0) { $0 + $1.totalCalories }.rounded())
    }

    /// "Log Large egg (2) and Sourdough bread, 290 calories, to breakfast?"
    static func confirmation(_ foods: [WatchFood], meal: Meal, unmatched: [String] = []) -> String {
        var text = "Log \(list(foods)), \(calories(foods).formatted()) calories, to \(meal.name.lowercased())?"
        if !unmatched.isEmpty {
            text += " I couldn't find \(ListFormatter.localizedString(byJoining: unmatched))."
        }
        return text
    }
}
