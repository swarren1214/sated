import Foundation
import SwiftData

/// The four meals a day is split into.
nonisolated enum Meal: String, CaseIterable, Identifiable, Codable, Sendable {
    case breakfast, lunch, snack, dinner

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .breakfast: "sunrise.fill"
        case .lunch: "sun.max.fill"
        case .snack: "carrot.fill"
        case .dinner: "moon.stars.fill"
        }
    }

    /// The meal a new entry most likely belongs to, from the time of day.
    static func suggested(for date: Date = .now, calendar: Calendar = .current) -> Meal {
        switch calendar.component(.hour, from: date) {
        case 4..<11: .breakfast
        case 11..<15: .lunch
        case 15..<17: .snack
        default: .dinner
        }
    }
}

/// Where an entry's nutrition came from.
nonisolated enum FoodSource: String, Codable, Sendable {
    case usda, openFoodFacts, label, voice, quickAdd
}

/// One food the person ate. Nutrients are stored per serving; `servings` scales them.
///
/// Every property has a default and nothing is unique, so the model syncs with CloudKit.
@Model
final class FoodEntry {
    var id: UUID = UUID()
    var date: Date = Date.now
    var mealRaw: String = Meal.breakfast.rawValue
    var name: String = ""
    var brand: String?
    var servingLabel: String = "1 serving"
    var servings: Double = 1
    var caloriesPerServing: Double = 0
    var proteinPerServing: Double = 0
    var carbsPerServing: Double = 0
    var fatPerServing: Double = 0
    var fiberPerServing: Double = 0
    var sourceRaw: String = FoodSource.usda.rawValue
    /// The bundled food or barcode this came from, so it can be logged again from Recent.
    var foodID: String?

    init(
        date: Date = .now,
        meal: Meal,
        name: String,
        brand: String? = nil,
        servingLabel: String,
        servings: Double = 1,
        perServing: Nutrients,
        source: FoodSource,
        foodID: String? = nil
    ) {
        self.date = date
        self.mealRaw = meal.rawValue
        self.name = name
        self.brand = brand
        self.servingLabel = servingLabel
        self.servings = servings
        self.caloriesPerServing = perServing.calories
        self.proteinPerServing = perServing.protein
        self.carbsPerServing = perServing.carbs
        self.fatPerServing = perServing.fat
        self.fiberPerServing = perServing.fiber
        self.sourceRaw = source.rawValue
        self.foodID = foodID
    }

    var meal: Meal {
        get { Meal(rawValue: mealRaw) ?? .snack }
        set { mealRaw = newValue.rawValue }
    }

    var source: FoodSource { FoodSource(rawValue: sourceRaw) ?? .quickAdd }

    var perServing: Nutrients {
        Nutrients(
            calories: caloriesPerServing,
            protein: proteinPerServing,
            carbs: carbsPerServing,
            fat: fatPerServing,
            fiber: fiberPerServing
        )
    }

    var nutrients: Nutrients { perServing * servings }

    /// "2 × 1 large egg", or the serving alone for one serving.
    var amountText: String {
        servings == 1 ? servingLabel : "\(servings.formatted(.number.precision(.fractionLength(0...2)))) × \(servingLabel)"
    }

    /// A plain snapshot, for summaries, Health and the coach.
    var record: EntryRecord {
        EntryRecord(id: id, date: date, meal: meal, name: name, nutrients: nutrients)
    }
}

/// A Sendable copy of an entry, used off the main actor and in tests.
nonisolated struct EntryRecord: Hashable, Sendable {
    var id: UUID
    var date: Date
    var meal: Meal
    var name: String
    var nutrients: Nutrients
}
