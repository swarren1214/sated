import Foundation

/// How many servings of a BigTable meal to start the stepper at. The person can always change it.
///
/// In order:
/// 1. **Same as last time**: they've logged this meal before, so start where they did.
/// 2. **Fits your day**: the share of today's remaining calories that this meal would get,
///    split across the meals still open (breakfast 25%, lunch 30%, dinner 35%, snack 10% of
///    the day), divided by one serving, to the nearest quarter, between ½ and 3.
/// 3. **One serving**: when the estimate is rough, nothing's left, or a serving is tiny.
nonisolated struct ServingSuggestion: Equatable, Sendable {
    nonisolated enum Reason: Equatable, Sendable {
        case lastTime
        /// Calories this meal gets of what's left.
        case fitsDay(target: Double)
        case standard
    }

    var servings: Double
    var reason: Reason

    static let range: ClosedRange<Double> = 0.5...3
    static let step = 0.25

    /// Each meal's usual share of the day's calories.
    static func share(of meal: Meal) -> Double {
        switch meal {
        case .breakfast: 0.25
        case .lunch: 0.30
        case .dinner: 0.35
        case .snack: 0.10
        }
    }

    /// - Parameters:
    ///   - perServing: calories in one serving of the meal.
    ///   - isRough: the estimate matched too few ingredients to size a portion by.
    ///   - meal: the meal it's being logged to.
    ///   - goal: the day's calorie goal.
    ///   - eaten: calories already logged that day.
    ///   - openMeals: meals with nothing logged yet that day (including `meal`).
    ///   - lastServings: servings logged the last time this BigTable meal was logged.
    static func suggest(
        perServing: Double,
        isRough: Bool,
        meal: Meal,
        goal: Double,
        eaten: Double,
        openMeals: Set<Meal>,
        lastServings: Double?
    ) -> ServingSuggestion {
        if let lastServings, lastServings > 0 {
            return ServingSuggestion(servings: clamp(lastServings), reason: .lastTime)
        }
        guard !isRough, perServing >= 50, goal > 0 else { return .one }
        let left = goal - eaten
        guard left > 0 else { return .one }
        var open = openMeals
        open.insert(meal)
        let shares = open.reduce(0) { $0 + share(of: $1) }
        let target = left * share(of: meal) / max(shares, share(of: meal))
        let servings = clamp((target / perServing / step).rounded() * step)
        return ServingSuggestion(servings: servings, reason: .fitsDay(target: target))
    }

    static let one = ServingSuggestion(servings: 1, reason: .standard)

    private static func clamp(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// "Same as last time", "Sized to the ~690 kcal left for dinner", or nil.
    func explanation(for meal: Meal) -> String? {
        switch reason {
        case .lastTime:
            "Same as last time."
        case .fitsDay(let target):
            "Sized to fit the ≈ \(Int(target.rounded()).formatted()) kcal your day has for \(meal.name.lowercased())."
        case .standard:
            nil
        }
    }
}
