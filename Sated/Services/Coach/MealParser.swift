import Foundation
import FoundationModels

// MARK: - Model output

@Generable
nonisolated struct ParsedMeal {
    @Guide(description: "The meal the person named, if any")
    var meal: MealMention

    @Guide(description: "Each separate food the person said they ate, in the order said", .maximumCount(12))
    var items: [ParsedFood]
}

@Generable
nonisolated enum MealMention {
    case breakfast, lunch, snack, dinner, notSaid
}

@Generable
nonisolated struct ParsedFood {
    @Guide(description: "A short, generic food name to search a nutrition database with, singular, no amount. For example \"large egg\", \"sourdough bread\", \"chicken breast\".")
    var food: String

    @Guide(description: "How many units were eaten. \"two eggs\" is 2, \"half a cup\" is 0.5, \"a slice\" is 1. Use 1 when no amount is given.")
    var quantity: Double

    @Guide(description: "The unit said, in lowercase singular: egg, slice, cup, tbsp, oz, g, scoop, piece, serving. Use \"serving\" when none is said.")
    var unit: String
}

/// One line of a parsed voice entry: what was said, matched to a food when possible.
struct VoiceItem: Identifiable, Hashable {
    let id = UUID()
    var spoken: String
    var food: FoodItem?
    var servings: Double

    var nutrients: Nutrients { (food?.nutrients ?? .zero) * servings }
}

/// Turns "two eggs and a slice of sourdough toast for dinner" into foods from the database.
/// The model only splits the sentence into foods and amounts; every number shown comes from
/// the database.
enum MealParser {
    static let instructions = """
    You turn what someone says they ate into a list of foods and amounts. \
    Only list foods they said. Never add foods, sides or drinks they didn't mention. \
    Split combined dishes only when they named the parts ("eggs and toast" is two foods; "a burrito" is one).
    """

    static func parse(_ transcript: String, database: FoodDatabase) async throws -> (meal: Meal?, items: [VoiceItem]) {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: "What they said: \"\(transcript)\"", generating: ParsedMeal.self)
        let parsed = response.content
        let meal: Meal? = switch parsed.meal {
        case .breakfast: .breakfast
        case .lunch: .lunch
        case .snack: .snack
        case .dinner: .dinner
        case .notSaid: nil
        }
        let items = parsed.items.map { item in
            let match = database.search(item.food, limit: 1).first
            return VoiceItem(
                spoken: describe(item),
                food: match,
                servings: match.map { servings(for: item, food: $0) } ?? max(item.quantity, 0.25)
            )
        }
        return (meal, items)
    }

    static func describe(_ item: ParsedFood) -> String {
        let amount = item.quantity.formatted(.number.precision(.fractionLength(0...2)))
        return item.unit == "serving" ? "\(amount) \(item.food)" : "\(amount) \(item.unit) \(item.food)"
    }

    /// Converts a spoken amount into servings of the matched food. Weights are converted
    /// through the food's serving weight; any other unit counts servings directly.
    static func servings(for item: ParsedFood, food: FoodItem) -> Double {
        let quantity = max(item.quantity, 0.25)
        let grams: Double? = switch item.unit {
        case "g", "gram": quantity
        case "oz", "ounce": quantity * 28.35
        case "lb", "pound": quantity * 453.6
        default: nil
        }
        if let grams, let servingGrams = food.grams, servingGrams > 0 {
            return (grams / servingGrams * 4).rounded() / 4
        }
        // "2 cups of rice", "3 slices of pizza": weigh it with the food's matching measure.
        if let measure = Self.measure(named: item.unit, in: food), let servingGrams = food.grams, servingGrams > 0 {
            return (quantity * measure.grams / servingGrams * 4).rounded() / 4
        }
        return quantity
    }

    /// The food's measure for a spoken unit: "cup" matches "1 cup, cooked", "slice" matches
    /// "1 piece, medium pizza" too. Only single measures ("1 …") count.
    static func measure(named unit: String, in food: FoodItem) -> FoodItem.Portion? {
        let spoken = FoodDatabase.fold(unit).trimmingCharacters(in: .whitespaces)
        guard !spoken.isEmpty else { return nil }
        let singular = spoken.count > 3 && spoken.hasSuffix("s") ? String(spoken.dropLast()) : spoken
        let aliases: [String: [String]] = [
            "tablespoon": ["tbsp"], "tbsp": ["tbsp"], "teaspoon": ["tsp"], "tsp": ["tsp"],
            "slice": ["slice", "piece"], "piece": ["piece", "slice"], "cup": ["cup"],
        ]
        let wanted = aliases[singular] ?? [singular]
        return food.measures.first { portion in
            let words = FoodDatabase.words(portion.label)
            guard words.first == "1", words.count > 1 else { return false }
            return wanted.contains(words[1])
        }
    }
}
