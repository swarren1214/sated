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
    /// Other ways to measure it ("1 cup", "1 slice", "1 oz"), each with its weight. Nutrients
    /// for any of them are scaled from `grams`, so only foods with a known weight have these.
    var portions: [Portion]?
    /// Search order from the importer: lower comes first among equally good matches.
    /// Foods as people eat them (FNDDS) rank ahead of ingredients (SR Legacy).
    var rank: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, brand, serving, grams, calories, protein, carbs, fat, fiber, portions, rank
    }

    /// A household measure and what it weighs. Stored compactly as `["1 cup", 240]`.
    nonisolated struct Portion: Hashable, Codable, Sendable, Identifiable {
        var label: String
        var grams: Double

        var id: String { label }

        /// "1 cup (240 g)"
        var text: String {
            label.hasSuffix(" g") ? label : "\(label) (\(Grams.whole(grams)) g)"
        }

        init(label: String, grams: Double) {
            self.label = label
            self.grams = grams
        }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            label = try container.decode(String.self)
            grams = try container.decode(Double.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(label)
            try container.encode(grams)
        }
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

    /// Every way to measure this food: its own serving first, then the other portions, then
    /// ounces and 100 g. Empty when the serving's weight isn't known.
    var measures: [Portion] {
        guard let grams, grams > 0 else { return [] }
        var all = [Portion(label: serving, grams: grams)]
        for portion in (portions ?? []) + [Portion(label: "1 oz", grams: 28.35), Portion(label: "100 g", grams: 100)]
        where portion.grams > 0 && !all.contains(where: { $0.label == portion.label }) {
            all.append(portion)
        }
        return all
    }

    /// The same food measured another way, with nutrients scaled by weight.
    func measured(by portion: Portion) -> FoodItem {
        guard let grams, grams > 0, portion.label != serving else { return self }
        var copy = self
        copy.serving = portion.label
        copy.grams = portion.grams
        let factor = portion.grams / grams
        copy.calories = calories * factor
        copy.protein = protein * factor
        copy.carbs = carbs * factor
        copy.fat = fat * factor
        copy.fiber = fiber * factor
        return copy
    }

    var nutrients: Nutrients {
        Nutrients(calories: calories, protein: protein, carbs: carbs, fat: fat, fiber: fiber)
    }

    /// "6 oz (170 g)" when the weight adds information.
    var servingText: String {
        guard let grams, !serving.contains(" g") else { return serving }
        return "\(serving) (\(Grams.whole(grams)) g)"
    }

    /// "350 kcal · 38 g protein"
    var listDetail: String {
        "\(servingText) · \(Int(calories.rounded())) kcal · \(Grams.text(protein)) g protein"
    }
}
