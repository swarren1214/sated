import Foundation
import FoundationModels

@Generable
nonisolated struct NutritionLabel {
    @Guide(description: "The serving size exactly as printed, for example \"1 bar (60g)\" or \"2/3 cup (55g)\"")
    var servingSize: String

    @Guide(description: "The serving size in grams, if printed")
    var servingGrams: Double?

    @Guide(description: "Calories per serving")
    var calories: Double

    @Guide(description: "Protein per serving, in grams")
    var protein: Double

    @Guide(description: "Total carbohydrate per serving, in grams")
    var carbs: Double

    @Guide(description: "Total fat per serving, in grams")
    var fat: Double

    @Guide(description: "Dietary fiber per serving, in grams. 0 if not listed.")
    var fiber: Double
}

/// Reads a Nutrition Facts panel from text the camera recognized. The model copies numbers
/// from the label; it is told never to estimate.
enum LabelReader {
    nonisolated enum ReadError: LocalizedError {
        case notALabel

        var errorDescription: String? {
            "That doesn't look like a Nutrition Facts label. Hold the camera closer so the whole panel is in view."
        }
    }

    static let instructions = """
    You read a US or Canadian Nutrition Facts label from text recognized by a camera. \
    Copy the per-serving values exactly as printed. Never estimate or calculate a value that isn't on the label. \
    The text may be out of order or contain other words from the package; ignore anything that isn't the label.
    """

    static func read(_ lines: [String], name: String) async throws -> FoodItem {
        let text = lines.joined(separator: "\n")
        let lowered = text.lowercased()
        guard lowered.contains("calorie"), lowered.contains("protein") || lowered.contains("fat") else {
            throw ReadError.notALabel
        }
        let session = LanguageModelSession(instructions: instructions)
        let label = try await session.respond(to: "Label text:\n\(text)", generating: NutritionLabel.self).content
        guard label.calories >= 0, label.calories < 3000 else { throw ReadError.notALabel }
        return FoodItem(
            id: "label.\(UUID().uuidString)",
            name: name,
            serving: label.servingSize.isEmpty ? "1 serving" : label.servingSize,
            grams: label.servingGrams,
            nutrients: Nutrients(calories: label.calories, protein: label.protein, carbs: label.carbs, fat: label.fat, fiber: label.fiber),
            source: .label
        )
    }
}
