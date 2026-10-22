import Foundation
import SwiftData

/// Shares the food log with the other Hearth apps on this device (Ember answers "how many
/// calories do I have left?" from it): the last seven days' totals and entries, and the goals.
/// Written by WidgetSync whenever the log changes, so it's as fresh as the widgets.
enum HearthFoodLogPublisher {
    private static var lastPublished: HearthFoodLog?

    @MainActor
    static func publish(context: ModelContext, now: Date = .now, calendar: Calendar = .current) {
        guard !ScreenshotMode.isOn else { return }
        let today = calendar.startOfDay(for: now)
        let since = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let descriptor = FetchDescriptor<FoodEntry>(predicate: #Predicate { $0.date >= since }, sortBy: [SortDescriptor(\.date)])
        let entries = (try? context.fetch(descriptor)) ?? []
        let goals = Goals.load()

        var days: [HearthFoodLog.Day] = []
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: since) else { continue }
            let todays = entries.filter { calendar.isDate($0.date, inSameDayAs: day) }
            let totals = todays.reduce(Nutrients.zero) { $0 + $1.record.nutrients }
            days.append(HearthFoodLog.Day(
                date: HearthDay.string(from: day, calendar: calendar),
                totals: HearthFoodLog.Totals(calories: totals.calories, protein: totals.protein, carbs: totals.carbs, fat: totals.fat, fiber: totals.fiber),
                entries: todays.prefix(40).map { entry in
                    let nutrients = entry.record.nutrients
                    return HearthFoodLog.Entry(name: entry.name, meal: entry.mealRaw, calories: nutrients.calories,
                                               protein: nutrients.protein, servings: entry.servings, place: entry.placeName)
                }
            ))
        }
        let log = HearthFoodLog(
            goals: HearthFoodLog.Totals(calories: goals.calories, protein: goals.protein, carbs: goals.carbs, fat: goals.fat, fiber: goals.fiber),
            days: days
        )
        guard log != lastPublished else { return }
        _ = Hearth.publish(log, from: .sated)
        lastPublished = log
    }
}
