import Foundation
import OSLog

/// The foods bundled with the app (Resources/Foods/foods.json), searchable offline.
///
/// The bundled file is built from USDA FoodData Central by scripts/build_foods.py. Search runs
/// in memory: a few thousand foods take well under a millisecond per keystroke. If the list
/// grows past ~20,000 foods, move it to a SQLite FTS table; only this type needs to change.
@Observable
final class FoodDatabase {
    static let shared = FoodDatabase()

    private(set) var foods: [FoodItem] = []
    private var index: [String: FoodItem] = [:]
    private let log = Logger(subsystem: "com.stephenwarren.sated", category: "foods")

    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "foods", withExtension: "json") else {
            log.fault("foods.json is missing from the bundle")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            var decoded = try JSONDecoder().decode([FoodItem].self, from: data)
            for i in decoded.indices { decoded[i].source = .usda }
            foods = decoded
            index = Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            log.fault("Couldn't read foods.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    init(foods: [FoodItem]) {
        self.foods = foods
        self.index = Dictionary(foods.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func food(id: String) -> FoodItem? { index[id] }

    /// Foods whose name contains every word typed, best matches first.
    func search(_ query: String, limit: Int = 40) -> [FoodItem] {
        let words = Self.words(query)
        guard !words.isEmpty else { return [] }
        let scored: [(FoodItem, Int)] = foods.compactMap { food in
            let name = Self.fold(food.name)
            guard words.allSatisfy({ name.contains($0) }) else { return nil }
            var score = 0
            if name.hasPrefix(words[0]) { score += 10 }
            if name.split(separator: " ").contains(where: { $0.hasPrefix(words[0]) }) { score += 5 }
            score -= name.count / 10
            return (food, score)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Up to `limit` foods that fit in what's left today, richest in what's most behind.
    func suggestions(remaining: Nutrients, goals: Goals, limit: Int = 3) -> [FoodItem] {
        guard remaining.calories > 50 else { return [] }
        let proteinNeed = max(remaining.protein, 0) / max(goals.protein, 1)
        let fiberNeed = max(remaining.fiber, 0) / max(goals.fiber, 1)
        return foods
            .filter { $0.calories > 20 && $0.calories <= remaining.calories }
            .map { food -> (FoodItem, Double) in
                let density = (food.protein * proteinNeed / max(goals.protein, 1) + food.fiber * fiberNeed / max(goals.fiber, 1)) / food.calories
                return (food, density)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    static func words(_ text: String) -> [String] {
        fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
