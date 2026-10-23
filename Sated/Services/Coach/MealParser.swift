import Foundation
import FoundationModels
import SwiftData

// MARK: - Model output

@Generable
nonisolated struct ParsedMeal {
    @Guide(description: "The meal the person named, if any")
    var meal: MealMention

    @Guide(description: "The day they said they ate it: \"today\" or no day is today, \"yesterday\" or \"last night\" is yesterday")
    var day: DayMention

    @Guide(description: "Each separate food the person said they ate, in the order said", .maximumCount(12))
    var items: [ParsedFood]
}

@Generable
nonisolated enum MealMention {
    case breakfast, lunch, snack, dinner, notSaid
}

@Generable
nonisolated enum DayMention {
    case today, yesterday
}

@Generable
nonisolated struct ParsedFood {
    @Guide(description: "The restaurant, chain or brand this food came from, spelled as the business spells it (\"Chick-fil-A\", \"McDonald's\", \"Chipotle\"). When they name a place once for several foods, repeat it for every food from that place. Empty when no place or brand was said.")
    var restaurant: String

    @Guide(description: "The food as they named it, keeping menu and brand words but no amount or size, singular. For example \"grilled chicken sandwich\", \"waffle fries\", \"Chick-fil-A sauce\", \"honey roasted BBQ sauce\", \"large egg\".")
    var name: String

    @Guide(description: "A short, generic food name to search a nutrition database with, singular, no amount and no brand. For example \"chicken sandwich\", \"french fries\", \"large egg\", \"sourdough bread\".")
    var food: String

    @Guide(description: "How many units were eaten. \"two eggs\" is 2, \"half a cup\" is 0.5, \"three packets\" is 3, \"a slice\" is 1. Use 1 when no amount is given.")
    var quantity: Double

    @Guide(description: "The unit said, in lowercase singular: egg, slice, cup, tbsp, oz, g, scoop, piece, packet, serving. Use \"serving\" when none is said.")
    var unit: String

    @Guide(description: "The size said, in lowercase: small, medium, large, regular or kids. Empty when no size was said.")
    var size: String
}

extension ParsedFood {
    /// A food with only the generic parts said, as before restaurants were understood.
    init(food: String, quantity: Double, unit: String) {
        self.init(restaurant: "", name: food, food: food, quantity: quantity, unit: unit, size: "")
    }
}

/// One line of a parsed voice entry: what was said, matched to a food when possible.
struct VoiceItem: Identifiable, Hashable {
    let id = UUID()
    var spoken: String
    var food: FoodItem?
    var servings: Double
    /// The restaurant it came from, when they said one and it was found.
    var place: PlaceRef?
    /// The match is the closest thing found, not the item they named (a generic sandwich
    /// for a restaurant's sandwich), so it's worth a look before logging.
    var isApproximate = false

    var nutrients: Nutrients { (food?.nutrients ?? .zero) * servings }
}

/// Turns "a Chick-fil-A grilled chicken sandwich, a regular waffle fries and three packets of
/// honey roasted BBQ sauce" into foods. The model only splits the sentence into foods, places
/// and amounts; every number shown comes from a menu, the person's own log or the database
/// (see `SpokenFoodMatcher`).
enum MealParser {
    static let instructions = """
    You turn what someone says they ate into a list of foods and amounts. \
    Only list foods they said. Never add foods, sides or drinks they didn't mention. \
    Split combined dishes only when they named the parts ("eggs and toast" is two foods; "a burrito" is one). \
    Keep restaurant and brand names: they decide which menu the food comes from. \
    Sauces, dressings and drinks they name are separate foods.
    """

    struct Result {
        var meal: Meal?
        /// 0 for today, 1 for yesterday.
        var daysAgo: Int
        var items: [VoiceItem]
    }

    /// - Parameter context: the person's log, to match foods they've had before. Optional so
    ///   tests and previews can leave it out.
    static func parse(_ transcript: String, database: FoodDatabase, context: ModelContext? = nil, menus: SpokenFoodMatcher.MenuSource = .live) async throws -> Result {
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
        let items = await SpokenFoodMatcher.match(parsed.items, database: database, context: context, menus: menus)
        return Result(meal: meal, daysAgo: parsed.day == .yesterday ? 1 : 0, items: items)
    }

    static func describe(_ item: ParsedFood) -> String {
        let amount = item.quantity.formatted(.number.precision(.fractionLength(0...2)))
        let said = item.name.trimmingCharacters(in: .whitespaces).isEmpty ? item.food : item.name
        let sized = item.size.isEmpty ? said : "\(item.size) \(said)"
        return item.unit == "serving" ? "\(amount) \(sized)" : "\(amount) \(item.unit) \(sized)"
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
