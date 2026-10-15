import Foundation

/// A chain's menu from the Hearth API (`GET /v1/restaurants/menu`), with nutrition per serving.
nonisolated struct RestaurantMenu: Codable, Hashable, Sendable {
    /// The place name that was asked about.
    var query: String
    /// The chain it matched, or nil when the place doesn't publish nutrition.
    var restaurant: String?
    var hasMenu: Bool
    var items: [MenuItem]
    /// When the server fetched it from the provider. Kept as text: it has fractional seconds.
    var fetchedAt: String
    /// The provider failed and the server sent an older copy.
    var stale: Bool
    var attribution: String

    var fetchedDate: Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(fetchedAt))
            ?? (try? Date.ISO8601FormatStyle().parse(fetchedAt))
    }

    /// Categories in menu order, for the chips.
    var categories: [String] {
        var seen = Set<String>()
        return items.compactMap(\.category).filter { seen.insert($0).inserted }
    }
}

nonisolated struct MenuItem: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var category: String?
    var servings: [MenuServing]

    /// The serving to start with: the provider's default, else the first.
    var defaultServing: MenuServing? {
        servings.first(where: \.isDefault) ?? servings.first
    }

    /// "Regular · 655 kcal · 50 g protein"
    var listDetail: String {
        guard let serving = defaultServing else { return "No nutrition listed" }
        var parts = [serving.label, "\(Int(serving.calories.rounded())) kcal"]
        if let protein = serving.protein { parts.append("\(Grams.text(protein)) g protein") }
        return parts.joined(separator: " · ")
    }

    /// The item as a loggable food, measured by `serving`.
    func food(serving: MenuServing, restaurant: String) -> FoodItem {
        FoodItem(
            id: serving.id,
            name: name,
            brand: restaurant,
            serving: serving.label,
            grams: serving.grams,
            nutrients: serving.nutrients,
            source: .restaurant
        )
    }
}

nonisolated struct MenuServing: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var description: String
    var grams: Double?
    var calories: Double
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var fiber: Double?
    var isDefault: Bool

    var nutrients: Nutrients {
        Nutrients(calories: calories, protein: protein ?? 0, carbs: carbs ?? 0, fat: fat ?? 0, fiber: fiber ?? 0)
    }

    /// "1 burrito bowl", without a trailing weight the picker shows separately.
    var label: String {
        let text = description.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "1 serving" : text
    }

    /// "1 bowl (340 g)"
    var text: String {
        guard let grams, grams > 0, !label.contains(" g") else { return label }
        return "\(label) (\(Grams.whole(grams)) g)"
    }
}

/// `POST /v1/restaurants/lookup`: which places are chains with menus.
nonisolated struct RestaurantLookup: Codable, Sendable {
    nonisolated struct Item: Codable, Sendable {
        var name: String
        var restaurant: String?
        /// nil when the server couldn't tell this time.
        var hasMenu: Bool?
    }
    var items: [Item]
}
