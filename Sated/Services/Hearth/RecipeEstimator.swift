import Foundation

/// Sated's estimate of one serving of a meal BigTable planned, worked out on the device from
/// the recipes' ingredients and the bundled foods. Always an estimate: shown with "≈".
nonisolated struct MealEstimate: Hashable, Sendable {
    /// One serving of every recipe in the meal.
    var perServing: Nutrients
    var recipes: [RecipePart]

    var ingredients: [IngredientMatch] { recipes.flatMap(\.ingredients) }

    /// Ingredients that count toward confidence: everything but "salt and pepper to taste".
    var counted: Int { ingredients.filter { $0.quality != .skipped }.count }
    /// Ingredients matched to a food by every word, in a unit Sated could weigh.
    var confident: Int { ingredients.filter { $0.quality == .confident }.count }

    /// Fewer than half the ingredients matched confidently: still loggable, but flagged as a
    /// rough estimate.
    var isRough: Bool {
        counted == 0 || Double(confident) < Double(counted) * Self.confidentShare
    }

    /// At least this share of ingredients must match confidently for a normal estimate.
    static let confidentShare = 0.5

    /// One recipe in the meal, as estimated.
    nonisolated struct RecipePart: Hashable, Sendable, Identifiable {
        var id: String
        var title: String
        /// How many servings the ingredient amounts make.
        var servings: Double
        /// BigTable didn't say how many it serves, so Sated assumed `RecipeEstimator.defaultServings`.
        var servingsAssumed: Bool
        var ingredients: [IngredientMatch]
    }
}

/// One recipe ingredient and the food it was matched to.
nonisolated struct IngredientMatch: Hashable, Sendable {
    nonisolated enum Quality: String, Hashable, Sendable {
        /// Every word matched, and the amount was weighed with a real measure.
        case confident
        /// Matched on fewer words, or the amount was guessed (no amount, an unknown unit).
        case rough
        /// No food found; adds nothing to the estimate.
        case unmatched
        /// No amount and no unit ("salt to taste"); left out.
        case skipped
    }

    var ingredient: HearthMealPlan.Ingredient
    var food: FoodItem?
    var grams: Double?
    /// For the whole recipe's amount, before dividing by servings.
    var nutrients: Nutrients
    var quality: Quality
}

/// Estimates BigTable's recipes from Sated's bundled foods, all on the device.
///
/// Matching: each ingredient name is cleaned ("2 cups shredded cheddar, divided" → "cheese
/// cheddar"), with a few recipe words rewritten the way USDA names things ("bell pepper" →
/// "peppers sweet"). `FoodDatabase.search` finds candidates, which are re-ranked for
/// ingredients rather than dishes: every word must appear, extra words cost a little, dish
/// words ("dip", "soup", "with") cost a lot, and "raw" wins ties, so "onion" is "Onions, raw"
/// and not "Onion dip". When nothing matches every word, the main word alone is tried, and
/// that match only counts as rough.
///
/// Weighing: weights convert directly; volumes use the food's own measure ("1 cup, shredded"
/// is 113 g of cheddar) or, failing that, any volume measure it has, else water's density;
/// counts ("2", "whole", "3 cloves") use the food's matching measure ("1 clove", "1 medium",
/// "1 egg").
enum RecipeEstimator {
    /// BigTable leaves `servings` out when the recipe doesn't say; most family recipes feed four.
    static let defaultServings = 4.0

    /// One serving of each recipe, summed: a main and a side are one plate.
    static func estimate(_ recipes: [HearthMealPlan.Recipe], in database: FoodDatabase) -> MealEstimate {
        var perServing = Nutrients.zero
        var parts: [MealEstimate.RecipePart] = []
        for recipe in recipes {
            let said = recipe.servings.map { $0 > 0 } ?? false
            let servings = said ? recipe.servings ?? defaultServings : defaultServings
            let matches = recipe.ingredients.map { match($0, in: database) }
            let total = matches.reduce(Nutrients.zero) { $0 + $1.nutrients }
            perServing += total / servings
            parts.append(MealEstimate.RecipePart(
                id: recipe.id,
                title: recipe.title,
                servings: servings,
                servingsAssumed: !said,
                ingredients: matches
            ))
        }
        return MealEstimate(perServing: perServing, recipes: parts)
    }

    /// Matches and weighs one ingredient.
    static func match(_ ingredient: HearthMealPlan.Ingredient, in database: FoodDatabase) -> IngredientMatch {
        let unitText = ingredient.unit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if ingredient.amount == nil, unitText.isEmpty {
            return IngredientMatch(ingredient: ingredient, food: nil, grams: nil, nutrients: .zero, quality: .skipped)
        }
        guard let found = bestFood(for: ingredient.name, in: database) else {
            return IngredientMatch(ingredient: ingredient, food: nil, grams: nil, nutrients: .zero, quality: .unmatched)
        }
        let food = found.food
        guard let servingGrams = food.grams, servingGrams > 0,
              let weight = grams(amount: ingredient.amount, unit: ingredient.unit, of: food) else {
            // A food without a known weight: count servings, roughly.
            let nutrients = food.nutrients * max(ingredient.amount ?? 1, 0)
            return IngredientMatch(ingredient: ingredient, food: food, grams: nil, nutrients: nutrients, quality: .rough)
        }
        let nutrients = food.nutrients * (weight.grams / servingGrams)
        let quality: IngredientMatch.Quality = found.allWords && weight.exact ? .confident : .rough
        return IngredientMatch(ingredient: ingredient, food: food, grams: weight.grams, nutrients: nutrients, quality: quality)
    }

    // MARK: Matching

    struct FoodMatch {
        var food: FoodItem
        /// False when only the main word matched.
        var allWords: Bool
    }

    /// The food an ingredient most likely is, or nil.
    static func bestFood(for name: String, in database: FoodDatabase) -> FoodMatch? {
        let query = queryWords(for: name)
        guard !query.isEmpty else { return nil }
        var attempts: [(words: [String], allWords: Bool)] = [(query, true)]
        // A rewrite that finds nothing ("rice vinegar" → "rice white vinegar"): the words as written.
        let written = queryWords(for: name, rewriting: false)
        if written != query, !written.isEmpty { attempts.append((written, true)) }
        // Last, the main word as written ("flour" in "almond flour"), as a rough match.
        if written.count > 1, let main = written.last(where: { !neutralWords.contains($0) }) {
            attempts.append((queryWords(for: main), false))
        }
        for attempt in attempts {
            var best: FoodItem?
            var bestScore = -Double.infinity
            let text = attempt.words.map(searchStem).joined(separator: " ")
            for food in database.search(text, limit: 200) {
                guard let value = rate(food, for: attempt.words), value > bestScore else { continue }
                best = food
                bestScore = value
            }
            if let best { return FoodMatch(food: best, allWords: attempt.allWords) }
        }
        return nil
    }

    /// The words to look an ingredient up by: "Yellow onion, diced" → ["onions", "raw"].
    static func queryWords(for name: String, rewriting: Bool = true) -> [String] {
        var text = FoodDatabase.fold(name)
        // "(about 2 lb)" and anything after the first comma ("onion, diced") describe prep.
        text = text.replacingOccurrences(of: "\\([^)]*\\)", with: " ", options: .regularExpression)
        if let comma = text.firstIndex(of: ",") { text = String(text[..<comma]) }
        var words = FoodDatabase.words(text).filter { !preparationWords.contains($0) && Double($0) == nil }
        // "ground cumin" is cumin; "ground beef" stays ground.
        if words.count > 1, words[0] == "ground", !groundMeats.contains(words[1]) { words.removeFirst() }
        guard rewriting else { return words }
        let joined = " " + words.joined(separator: " ") + " "
        for (phrase, replacement) in phrases where joined.contains(" \(phrase) ") {
            return FoodDatabase.words(joined.replacingOccurrences(of: " \(phrase) ", with: " \(replacement) "))
        }
        return words
    }

    /// How well a food fits as this ingredient; nil unless every word appears in its name.
    static func rate(_ food: FoodItem, for query: [String]) -> Double? {
        // Parentheses are footnotes ("(Includes foods for USDA's Food Distribution Program)").
        let name = FoodDatabase.fold(food.name)
            .replacingOccurrences(of: "\\([^)]*\\)", with: " ", options: .regularExpression)
        let words = FoodDatabase.words(name)
        for wanted in query where !words.contains(where: { sameWord(wanted, $0) }) {
            return nil
        }
        var score = 100.0
        let extras = words.filter { word in !query.contains(where: { sameWord($0, word) }) }
        // Exactly what was asked for: "Mustard" for mustard.
        if extras.isEmpty { score += 10 }
        for word in extras {
            if dishWords.contains(word) {
                score -= 30
            } else if neutralWords.contains(word) {
                score -= 1
            } else {
                score -= 5
            }
        }
        if words.contains("raw") { score += 8 }
        let head = FoodDatabase.words(String(name.prefix { $0 != "," }))
        if let first = head.first, query.contains(where: { sameWord($0, first) }) { score += 6 }
        // The importer's order only breaks near-ties: it ranks spices low for everyday search.
        score -= Double(food.rank ?? 0) / 10
        return score
    }

    /// The same word, singular or plural: "onion" and "onions", "tomato" and "tomatoes",
    /// "berry" and "berries".
    static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b || a + "s" == b || b + "s" == a || a + "es" == b || b + "es" == a { return true }
        if a.hasSuffix("ies"), b.hasSuffix("y") { return a.dropLast(3) == b.dropLast() }
        if b.hasSuffix("ies"), a.hasSuffix("y") { return b.dropLast(3) == a.dropLast() }
        return false
    }

    /// A word cut so `FoodDatabase.search`, which matches word starts, finds both its singular
    /// and plural: "potatoes" → "potato", "berries" → "berr".
    static func searchStem(_ word: String) -> String {
        guard word.count > 4 else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) }
        if word.hasSuffix("oes") { return String(word.dropLast(2)) }
        return word
    }

    /// Words about preparation, size or packaging, not about which food it is.
    static let preparationWords: Set<String> = [
        "chopped", "diced", "minced", "sliced", "shredded", "grated", "fresh", "freshly", "large",
        "medium", "small", "boneless", "skinless", "finely", "roughly", "thinly", "coarsely",
        "packed", "softened", "melted", "divided", "optional", "peeled", "seeded", "crushed",
        "cubed", "trimmed", "halved", "quartered", "rinsed", "drained", "room", "temperature",
        "lean", "extra", "virgin", "organic", "about", "plus", "more", "for", "serving", "to",
        "taste", "cut", "into", "inch", "pieces", "strips", "of", "a", "the", "cold", "warm",
        "hot", "juiced", "zested", "lightly", "beaten", "whisked", "yellow", "florets",
        "fillet", "fillets", "kosher", "slice", "slices", "sprig", "sprigs",
    ]

    /// Ground meats keep "ground"; for anything else ("ground cumin") it's preparation.
    static let groundMeats: Set<String> = ["beef", "turkey", "pork", "chicken", "lamb", "veal", "bison"]

    /// Recipe words USDA spells differently, longest first. The first that appears is rewritten.
    static let phrases: [(String, String)] = [
        ("garlic cloves", "garlic raw"), ("garlic clove", "garlic raw"),
        ("flour tortillas", "tortilla flour"), ("flour tortilla", "tortilla flour"),
        ("corn tortillas", "tortilla corn"), ("corn tortilla", "tortilla corn"),
        ("bell peppers", "peppers sweet"), ("bell pepper", "peppers sweet"),
        ("green onions", "onions spring"), ("green onion", "onions spring"),
        ("scallions", "onions spring"), ("scallion", "onions spring"),
        ("red onions", "onions raw"), ("red onion", "onions raw"),
        ("white onions", "onions raw"), ("white onion", "onions raw"),
        ("sweet onion", "onions raw"),
        ("ground beef", "beef ground"), ("ground turkey", "turkey ground"), ("ground pork", "pork ground"),
        ("chicken broth", "soup chicken broth ready serve"), ("chicken stock", "soup chicken broth ready serve"),
        ("beef broth", "soup beef broth ready serve"), ("beef stock", "soup beef broth ready serve"),
        ("vegetable broth", "soup vegetable broth ready serve"), ("vegetable stock", "soup vegetable broth ready serve"),
        ("whole wheat flour", "wheat flour whole grain"), ("bread flour", "wheat flour white bread"),
        ("all purpose flour", "wheat flour white all purpose"), ("flour", "wheat flour white all purpose"),
        ("parmesan cheese", "cheese parmesan"), ("parmesan", "cheese parmesan"),
        ("cheddar cheese", "cheese cheddar"), ("cheddar", "cheese cheddar"),
        ("mozzarella cheese", "cheese mozzarella"), ("mozzarella", "cheese mozzarella"),
        ("cream cheese", "cheese cream"), ("feta cheese", "cheese feta"), ("feta", "cheese feta"),
        ("egg noodles", "noodles egg"), ("spaghetti", "pasta dry"), ("penne", "pasta dry"),
        ("pasta", "pasta dry"),
        ("eggs", "egg whole raw"), ("egg", "egg whole raw"),
        ("brown sugar", "sugar brown"), ("powdered sugar", "sugar powdered"),
        ("chicken breasts", "chicken breast"), ("chicken thighs", "chicken thigh"),
        ("tortillas", "tortilla"), ("brown rice", "rice brown"), ("wild rice", "wild rice"),
        ("rice", "rice white"),
        ("vegetable oil", "oil vegetable"), ("canola oil", "oil canola"),
        ("zucchini", "squash summer"),
        ("tomato sauce", "sauce tomato"), ("diced tomatoes", "tomatoes canned"),
        ("crushed tomatoes", "tomatoes canned"),
        ("turkey bacon", "bacon turkey"), ("bacon", "pork cured bacon"),
        ("potatoes", "potatoes flesh skin raw"), ("potato", "potatoes flesh skin raw"),
        ("tofu", "tofu raw firm"), ("bread crumbs", "bread crumbs"), ("bread", "bread white"),
        ("garlic", "garlic raw"), ("onions", "onions raw"), ("onion", "onions raw"),
    ]

    /// Words in a food's name that make it a dish rather than an ingredient.
    static let dishWords: Set<String> = [
        "dip", "soup", "salad", "sandwich", "casserole", "pie", "cake", "souffle", "creamed",
        "deviled", "fried", "stewed", "sauce", "dressing", "mix", "topping", "bread", "baby",
        "frozen", "meal", "dinner", "with", "breaded", "nuggets", "patty", "bits", "pickled",
        "restaurant", "fast", "pre", "precooked", "home", "recipe", "flavored", "sweetened",
        "puerto", "rican", "mexican", "style", "meatless", "vegetarian", "imitation",
        "substitute", "skin", "flour", "babyfood", "toddler", "stage", "greens", "buns", "bun", "rolls",
        "frosted", "glazed", "toast", "pudding", "cereal", "drink", "beverage", "smoothie", "pastry",
        "danish", "bagel", "crackers", "pancakes", "waffles", "coated", "muffin", "cookie", "cookies", "stuffed", "chips", "candy", "bar",
    ]

    /// Words in a food's name that say little about which food it is.
    static let neutralWords: Set<String> = [
        "raw", "fresh", "whole", "plain", "regular", "ns", "as", "to", "form", "or", "type", "all",
        "purpose", "enriched", "unenriched", "spices", "table", "fluid", "dry", "uncooked",
        "unprepared", "includes", "tops", "bulb", "meat", "only", "boneless", "skinless",
        "broiler", "broilers", "fryers", "ground",
    ]

    // MARK: Weighing

    struct Weight {
        var grams: Double
        /// False when the amount or the measure was guessed.
        var exact: Bool
    }

    /// Grams in each weight unit.
    static let weights: [String: Double] = ["g": 1, "kg": 1000, "mg": 0.001, "oz": 28.35, "lb": 453.6]
    /// Milliliters in each volume unit (US measures).
    static let volumes: [String: Double] = [
        "ml": 1, "l": 1000, "tsp": 4.93, "tbsp": 14.79, "cup": 236.6, "fl oz": 29.57,
        "pint": 473.2, "quart": 946.4, "gallon": 3785,
    ]
    /// Common counted things, in grams, for foods that don't list them. A rough guess.
    static let typicalCounts: [String: Double] = ["can": 400, "clove": 3, "stick": 113, "pinch": 0.4, "dash": 0.4]

    static let unitAliases: [String: String] = [
        "gram": "g", "grams": "g", "gr": "g", "kilogram": "kg", "kilograms": "kg", "kgs": "kg",
        "milligram": "mg", "milligrams": "mg", "ounce": "oz", "ounces": "oz", "pound": "lb",
        "pounds": "lb", "lbs": "lb", "milliliter": "ml", "milliliters": "ml", "millilitre": "ml",
        "millilitres": "ml", "liter": "l", "liters": "l", "litre": "l", "litres": "l",
        "teaspoon": "tsp", "teaspoons": "tsp", "tsps": "tsp", "tablespoon": "tbsp",
        "tablespoons": "tbsp", "tbsps": "tbsp", "tbs": "tbsp", "tbl": "tbsp", "tbls": "tbsp",
        "cups": "cup", "c": "cup", "fluid ounce": "fl oz", "fluid ounces": "fl oz", "floz": "fl oz",
        "fl oz": "fl oz", "pints": "pint", "pt": "pint", "quarts": "quart", "qt": "quart",
        "gallons": "gallon", "gal": "gallon", "pinches": "pinch", "dashes": "dash",
        "": "whole", "each": "whole", "ea": "whole", "whole": "whole", "count": "whole", "item": "whole",
    ]

    /// BigTable's unit in one spelling: "Tablespoons" → "tbsp", "cloves" → "clove", nil → "whole".
    static func normalizedUnit(_ unit: String?) -> String {
        let text = FoodDatabase.fold(unit ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if let alias = unitAliases[text] { return alias }
        if text.count > 3, text.hasSuffix("s") { return String(text.dropLast()) }
        return text
    }

    /// How much `amount` `unit` of `food` weighs. Nil when the food's weight isn't known.
    static func grams(amount: Double?, unit: String?, of food: FoodItem) -> Weight? {
        guard let servingGrams = food.grams, servingGrams > 0 else { return nil }
        let quantity = max(amount ?? 1, 0)
        let saidAmount = amount != nil
        let canonical = normalizedUnit(unit)
        if let perUnit = weights[canonical] {
            return Weight(grams: quantity * perUnit, exact: saidAmount)
        }
        if let milliliters = volumes[canonical] {
            if let perMilliliter = density(of: food, preferring: canonical) {
                return Weight(grams: quantity * milliliters * perMilliliter, exact: saidAmount)
            }
            // No volume measure for this food: about as dense as water.
            return Weight(grams: quantity * milliliters, exact: false)
        }
        if let portion = countMeasure(canonical, in: food) {
            return Weight(grams: quantity * portion.grams, exact: saidAmount)
        }
        if let typical = typicalCounts[canonical] {
            return Weight(grams: quantity * typical, exact: false)
        }
        // An unknown unit: one of the food's servings each.
        return Weight(grams: quantity * servingGrams, exact: false)
    }

    /// Grams per milliliter, from the food's measure in `unit` if it has one ("1 cup,
    /// shredded"), else its first volume measure.
    static func density(of food: FoodItem, preferring unit: String) -> Double? {
        var fallback: Double?
        for portion in food.measures {
            guard let measured = volume(of: portion.label), measured.milliliters > 0 else { continue }
            let perMilliliter = portion.grams / measured.milliliters
            if measured.unit == unit { return perMilliliter }
            if fallback == nil { fallback = perMilliliter }
        }
        return fallback
    }

    /// The volume a measure's label describes: "1 cup, shredded" → 236.6 ml of "cup";
    /// "1/2 cup" → 118.3 ml. Nil for anything else ("1 slice", "1 oz").
    static func volume(of label: String) -> (milliliters: Double, unit: String)? {
        let tokens = FoodDatabase.fold(label)
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "(" || $0 == ")" })
            .map(String.init)
        guard tokens.count >= 2, let quantity = number(tokens[0]), quantity > 0 else { return nil }
        let spoken = tokens[1] == "fl" && tokens.count >= 3 && tokens[2] == "oz" ? "fl oz" : tokens[1]
        let unit = normalizedUnit(spoken)
        guard let milliliters = volumes[unit] else { return nil }
        return (quantity * milliliters, unit)
    }

    /// "2", "0.5" or "1/2".
    static func number(_ token: String) -> Double? {
        if let value = Double(token) { return value }
        let parts = token.split(separator: "/")
        guard parts.count == 2, let top = Double(parts[0]), let bottom = Double(parts[1]), bottom > 0 else { return nil }
        return top / bottom
    }

    /// The food's measure for a counted unit: "clove" → "1 clove"; a whole one ("2 eggs", "1
    /// onion") → a medium one, a whole one, or a measure named for the food ("1 egg").
    static func countMeasure(_ unit: String, in food: FoodItem) -> FoodItem.Portion? {
        if unit != "whole" { return MealParser.measure(named: unit, in: food) }
        let singles = food.measures.filter { portion in
            let words = FoodDatabase.words(portion.label)
            return words.count > 1 && words[0] == "1"
        }
        func having(_ test: ([String]) -> Bool) -> FoodItem.Portion? {
            singles.first { test(FoodDatabase.words($0.label)) }
        }
        let nameWords = FoodDatabase.words(food.name)
        func named(_ words: [String]) -> Bool {
            nameWords.contains { sameWord($0, words[1]) }
        }
        return having { $0[1] == "medium" }
            ?? having { named($0) && $0.contains("medium") }
            ?? having { ["whole", "fruit", "regular"].contains($0[1]) }
            ?? having { named($0) }
            ?? having { ["large", "small", "piece"].contains($0[1]) }
    }
}
