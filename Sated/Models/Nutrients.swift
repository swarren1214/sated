import Foundation

/// Calories and the four tracked macros, in kcal and grams.
nonisolated struct Nutrients: Codable, Hashable, Sendable {
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var fiber: Double = 0

    static let zero = Nutrients()

    static func + (lhs: Nutrients, rhs: Nutrients) -> Nutrients {
        Nutrients(
            calories: lhs.calories + rhs.calories,
            protein: lhs.protein + rhs.protein,
            carbs: lhs.carbs + rhs.carbs,
            fat: lhs.fat + rhs.fat,
            fiber: lhs.fiber + rhs.fiber
        )
    }

    static func += (lhs: inout Nutrients, rhs: Nutrients) { lhs = lhs + rhs }

    static func * (lhs: Nutrients, factor: Double) -> Nutrients {
        Nutrients(
            calories: lhs.calories * factor,
            protein: lhs.protein * factor,
            carbs: lhs.carbs * factor,
            fat: lhs.fat * factor,
            fiber: lhs.fiber * factor
        )
    }

    static func / (lhs: Nutrients, divisor: Double) -> Nutrients {
        divisor == 0 ? .zero : lhs * (1 / divisor)
    }

    /// Share of calories from protein, carbs and fat (4, 4 and 9 kcal per gram), each 0...1.
    var calorieSplit: (protein: Double, carbs: Double, fat: Double) {
        let p = protein * 4, c = carbs * 4, f = fat * 9
        let total = p + c + f
        guard total > 0 else { return (0, 0, 0) }
        return (p / total, c / total, f / total)
    }

    /// A one-line description for lists and for the on-device model.
    var summary: String {
        "\(Int(calories.rounded())) kcal, \(Grams.text(protein)) g protein, \(Grams.text(carbs)) g carbs, \(Grams.text(fat)) g fat, \(Grams.text(fiber)) g fiber"
    }
}

/// Daily targets (Settings › Daily Goals). Stored in UserDefaults through @AppStorage.
nonisolated struct Goals: Hashable, Sendable {
    var calories: Double = 2400
    var protein: Double = 180
    var carbs: Double = 240
    var fat: Double = 75
    var fiber: Double = 35

    static let defaults = Goals()

    /// Reads the saved goals, falling back to the defaults for any that were never set.
    static func load(from store: UserDefaults = .standard) -> Goals {
        func value(_ key: String, _ fallback: Double) -> Double {
            store.object(forKey: key) == nil ? fallback : store.double(forKey: key)
        }
        let d = Goals.defaults
        return Goals(
            calories: value(SettingsKey.goalCalories, d.calories),
            protein: value(SettingsKey.goalProtein, d.protein),
            carbs: value(SettingsKey.goalCarbs, d.carbs),
            fat: value(SettingsKey.goalFat, d.fat),
            fiber: value(SettingsKey.goalFiber, d.fiber)
        )
    }
}

/// Gram amounts as people read them: whole grams at 10 g and above, one decimal below.
nonisolated enum Grams {
    static func text(_ value: Double) -> String {
        if value >= 10 || value == value.rounded() {
            return Int(value.rounded()).formatted()
        }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    /// A weight to the nearest gram, at least 1: "240".
    static func whole(_ value: Double) -> String {
        max(Int(value.rounded()), 1).formatted()
    }
}
