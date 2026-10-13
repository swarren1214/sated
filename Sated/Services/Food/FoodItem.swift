import Foundation

/// A food that can be logged: from the bundled USDA list, a barcode, or a nutrition label.
/// Nutrients are for one serving.
nonisolated struct FoodItem: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var brand: String?
    /// "1 cup", "6 oz", "1 bar (60 g)"
    var serving: String
    var grams: Double?
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var fiber: Double
    var source: FoodSource = .usda

    enum CodingKeys: String, CodingKey {
        case id, name, brand, serving, grams, calories, protein, carbs, fat, fiber
    }

    init(id: String, name: String, brand: String? = nil, serving: String, grams: Double? = nil, nutrients: Nutrients, source: FoodSource) {
        self.id = id
        self.name = name
        self.brand = brand
        self.serving = serving
        self.grams = grams
        self.calories = nutrients.calories
        self.protein = nutrients.protein
        self.carbs = nutrients.carbs
        self.fat = nutrients.fat
        self.fiber = nutrients.fiber
        self.source = source
    }

    var nutrients: Nutrients {
        Nutrients(calories: calories, protein: protein, carbs: carbs, fat: fat, fiber: fiber)
    }

    /// "6 oz (170 g)" when the weight adds information.
    var servingText: String {
        guard let grams, !serving.contains(" g") else { return serving }
        return "\(serving) (\(Int(grams.rounded())) g)"
    }

    /// "350 kcal · 38 g protein"
    var listDetail: String {
        "\(servingText) · \(Int(calories.rounded())) kcal · \(Grams.text(protein)) g protein"
    }
}
