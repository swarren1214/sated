import Foundation
import SwiftData
import UIKit

/// Adds, changes and removes entries, keeping Apple Health in step. Views call these instead
/// of inserting into the model context themselves.
enum FoodLog {
    @discardableResult
    static func add(_ food: FoodItem, servings: Double, meal: Meal, date: Date = .now, in context: ModelContext) -> FoodEntry {
        let entry = FoodEntry(
            date: date,
            meal: meal,
            name: food.name,
            brand: food.brand,
            servingLabel: food.servingText,
            servings: servings,
            perServing: food.nutrients,
            source: food.source,
            foodID: food.id
        )
        context.insert(entry)
        try? context.save()
        let record = entry.record
        Task { await HealthService.shared.save(record) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return entry
    }

    static func update(_ entry: FoodEntry, servings: Double, meal: Meal, in context: ModelContext) {
        entry.servings = servings
        entry.meal = meal
        try? context.save()
        let record = entry.record
        Task { await HealthService.shared.update(record) }
    }

    static func delete(_ entry: FoodEntry, in context: ModelContext) {
        let id = entry.id
        context.delete(entry)
        try? context.save()
        Task { await HealthService.shared.remove(entryID: id) }
    }

    /// The last few distinct foods logged, newest first, for Add Food › Recent.
    static func recentFoods(in context: ModelContext, limit: Int = 8) -> [FoodItem] {
        var descriptor = FetchDescriptor<FoodEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 60
        let entries = (try? context.fetch(descriptor)) ?? []
        var seen = Set<String>()
        var foods: [FoodItem] = []
        for entry in entries {
            let key = entry.foodID ?? entry.name.lowercased()
            guard seen.insert(key).inserted else { continue }
            foods.append(FoodItem(
                id: entry.foodID ?? "recent.\(entry.id.uuidString)",
                name: entry.name,
                brand: entry.brand,
                serving: entry.servingLabel,
                nutrients: entry.perServing,
                source: entry.source
            ))
            if foods.count == limit { break }
        }
        return foods
    }

    /// The log as CSV, for Settings › Export.
    static func csv(in context: ModelContext) -> String {
        let descriptor = FetchDescriptor<FoodEntry>(sortBy: [SortDescriptor(\.date)])
        let entries = (try? context.fetch(descriptor)) ?? []
        func field(_ text: String) -> String { "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        var lines = ["date,meal,food,amount,calories,protein_g,carbs_g,fat_g,fiber_g"]
        for entry in entries {
            let n = entry.nutrients
            let values = [n.calories, n.protein, n.carbs, n.fat, n.fiber].map { String(format: "%.1f", $0) }
            lines.append(([entry.date.ISO8601Format(), entry.meal.rawValue, field(entry.name), field(entry.amountText)] + values).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}
