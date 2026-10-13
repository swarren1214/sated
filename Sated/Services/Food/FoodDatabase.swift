import Foundation
import OSLog

/// The foods bundled with the app (Resources/Foods/foods.json), searchable offline.
///
/// The bundled file is built from USDA FoodData Central by scripts/build_foods.py: SR Legacy
/// (ingredients and basic foods) and FNDDS (foods as people eat them, like "Pizza, cheese").
/// About 13,000 foods, searched in memory: names are folded and split into words once at
/// load, so each keystroke is a quick scan. If a much larger list is added (USDA's branded
/// foods, say), move search to a SQLite FTS table; only this type needs to change.
@Observable
final class FoodDatabase {
    /// Loaded in the background at launch (decoding ~13,000 foods takes a moment); search
    /// returns nothing for that first instant. Previews load right away.
    static let shared = FoodDatabase(bundle: .main, inBackground: ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1")

    /// False until the bundled foods are in.
    private(set) var isLoaded = false

    private(set) var foods: [FoodItem] = []
    @ObservationIgnored private var index: [String: FoodItem] = [:]
    /// Folded names and their words, parallel to `foods`.
    @ObservationIgnored private var searchable: [Searchable] = []
    private let log = Logger(subsystem: "com.stephenwarren.sated", category: "foods")

    nonisolated struct Searchable: Sendable {
        var name: String
        var words: [Substring]
        /// Words before the first comma: "Pizza" in "Pizza, cheese, thin crust".
        var head: [Substring]
        /// The head words joined by spaces: "egg" for "Egg, whole, fried".
        var headText: String
        var rank: Int
    }

    init(bundle: Bundle = .main, inBackground: Bool = false) {
        guard let url = bundle.url(forResource: "foods", withExtension: "json") else {
            log.fault("foods.json is missing from the bundle")
            return
        }
        if inBackground {
            Task {
                let prepared = await Task.detached(priority: .userInitiated) { Self.prepare(try? Self.decode(url)) }.value
                apply(prepared)
            }
        } else {
            apply(Self.prepare(try? Self.decode(url)))
        }
    }

    init(foods: [FoodItem]) {
        apply(Self.prepare(foods))
    }

    nonisolated private struct Prepared: Sendable {
        var foods: [FoodItem]
        var index: [String: FoodItem]
        var searchable: [Searchable]
    }

    nonisolated private static func prepare(_ decoded: [FoodItem]?) -> Prepared {
        let foods = decoded ?? []
        return Prepared(
            foods: foods,
            index: Dictionary(foods.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            searchable: foods.map(makeSearchable)
        )
    }

    private func apply(_ prepared: Prepared) {
        if prepared.foods.isEmpty { log.fault("No foods loaded from foods.json") }
        foods = prepared.foods
        index = prepared.index
        searchable = prepared.searchable
        isLoaded = true
    }

    nonisolated private static func decode(_ url: URL) throws -> [FoodItem] {
        var decoded = try JSONDecoder().decode([FoodItem].self, from: Data(contentsOf: url))
        for i in decoded.indices { decoded[i].source = .usda }
        return decoded
    }

    nonisolated private static func makeSearchable(_ food: FoodItem) -> Searchable {
        let name = fold(food.name)
        let headWords = (name.split(separator: ",", maxSplits: 1).first.map { String($0) } ?? name)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return Searchable(
            name: name,
            words: name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }),
            head: headWords,
            headText: headWords.joined(separator: " "),
            rank: food.rank ?? 0
        )
    }

    func food(id: String) -> FoodItem? { index[id] }

    /// Foods matching every word typed (or a common synonym), best matches first: the main
    /// word of the name over a passing mention, whole words over word starts, foods as eaten
    /// over ingredients, and short names over long ones.
    func search(_ query: String, limit: Int = 40) -> [FoodItem] {
        let typed = Self.words(query)
        guard !typed.isEmpty else { return [] }
        // Each typed word, its singular ("eggs" finds "Egg, scrambled"), and any synonyms.
        let options = typed.map { word -> [Choice] in
            var choices = [Choice(word: word)]
            if word.count > 3, word.hasSuffix("s") { choices.append(Choice(word: String(word.dropLast()), wholeWordOnly: true)) }
            return choices + (Self.synonyms[word] ?? []).map { Choice(word: $0) }
        }
        let phrase = typed.joined(separator: " ")
        let babyFood = typed.contains { ["baby", "infant", "toddler", "formula"].contains($0) }

        var scored: [(Int, Int)] = []
        scored.reserveCapacity(256)
        for (i, entry) in searchable.enumerated() {
            var score = 0
            var matchedAll = true
            for (position, choices) in options.enumerated() {
                var best = Int.min
                for choice in choices {
                    best = max(best, Self.score(choice, in: entry, first: position == 0))
                }
                if best == Int.min { matchedAll = false; break }
                score += best
            }
            guard matchedAll else { continue }
            if !babyFood, entry.name.hasPrefix("baby") || entry.name.contains("infant formula") { score -= 60 }
            // The name is exactly what was typed, before its first comma: "Egg, scrambled"
            // for "egg", rather than "Egg roll".
            if entry.headText == phrase || entry.headText + "s" == phrase { score += 15 }
            score -= entry.rank
            score -= entry.words.count * 2
            scored.append((i, score))
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : searchable[$0.0].name.count < searchable[$1.0].name.count }
        return scored.prefix(limit).map { foods[$0.0] }
    }

    /// One way to match a typed word. A singular made from a plural ("egg" from "eggs") only
    /// matches whole words, so "fries" never matches "fried".
    nonisolated private struct Choice {
        var word: String
        var wholeWordOnly = false
    }

    /// How well one typed word matches a food's name; Int.min when it doesn't appear.
    nonisolated private static func score(_ choice: Choice, in entry: Searchable, first: Bool) -> Int {
        let word = choice.word
        if choice.wholeWordOnly {
            if let n = entry.head.firstIndex(where: { $0 == word }) { return (n == 0 ? 40 : 30) + (first ? 10 : 0) }
            return entry.words.contains(where: { $0 == word }) ? 14 : Int.min
        }
        if word.contains(" ") {
            // A multi-word synonym ("french fries"): the phrase must appear.
            guard entry.name.contains(word) else { return Int.min }
            return 30
        }
        var best = Int.min
        for (n, candidate) in entry.head.enumerated() {
            if candidate == word { best = max(best, n == 0 ? 40 : 30) }
            else if candidate.hasPrefix(word) { best = max(best, n == 0 ? 28 : 20) }
        }
        if best != Int.min { return first ? best + 10 : best }
        for candidate in entry.words {
            if candidate == word { best = max(best, 14) }
            else if candidate.hasPrefix(word) { best = max(best, 8) }
        }
        if best == Int.min, word.count >= 4, entry.name.contains(word) { best = 2 }
        return best
    }

    /// Everyday words USDA spells differently. Searching either side finds the other.
    nonisolated static let synonyms: [String: [String]] = {
        let pairs: [(String, String)] = [
            ("fries", "french fries"), ("chips", "potato chips"), ("soda", "soft drink"),
            ("pop", "soft drink"), ("coke", "cola"), ("ketchup", "catsup"), ("oatmeal", "oats"),
            ("pb", "peanut butter"), ("sub", "submarine sandwich"), ("hoagie", "submarine sandwich"),
            ("burger", "hamburger"), ("mac", "macaroni"),
            ("oj", "orange juice"), ("latte", "coffee, latte"), ("yoghurt", "yogurt"),
            ("donut", "doughnut"), ("doughnut", "donut"), ("cilantro", "coriander"),
            ("zucchini", "squash, summer"), ("garbanzo", "chickpeas"), ("chickpea", "garbanzo"),
            ("scallion", "onions, spring"), ("hotdog", "frankfurter"),
            ("ramen", "ramen noodle"), ("froyo", "frozen yogurt"), ("shake", "milkshake"),
        ]
        var map: [String: [String]] = [:]
        for (a, b) in pairs { map[a, default: []].append(b) }
        return map
    }()

    /// Up to `limit` foods that fit in what's left today, richest in what's most behind.
    func suggestions(remaining: Nutrients, goals: Goals, limit: Int = 3) -> [FoodItem] {
        guard remaining.calories > 50 else { return [] }
        let proteinNeed = max(remaining.protein, 0) / max(goals.protein, 1)
        let fiberNeed = max(remaining.fiber, 0) / max(goals.fiber, 1)
        // Only everyday foods (rank 0): protein powders and spices make poor suggestions.
        return foods
            .filter { ($0.rank ?? 0) == 0 && $0.calories > 20 && $0.calories <= remaining.calories }
            .map { food -> (FoodItem, Double) in
                let density = (food.protein * proteinNeed / max(goals.protein, 1) + food.fiber * fiberNeed / max(goals.fiber, 1)) / food.calories
                return (food, density)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    nonisolated static func words(_ text: String) -> [String] {
        fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
