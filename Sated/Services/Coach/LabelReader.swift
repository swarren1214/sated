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

/// The fallback for labels the rules in `LabelParser` can't read (unusual layouts, curved or
/// glared packaging): the on-device model reads the panel's text. It only ever sees text from
/// inside the panel, and is told to copy numbers, never estimate them.
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
    On labels with two columns (per serving and per container), use the per-serving column. \
    The text may be out of order or contain other words from the package; ignore anything that isn't the label.
    """

    static func read(_ lines: [String]) async throws -> LabelReading {
        let text = lines.joined(separator: "\n")
        let lowered = text.lowercased()
        guard lowered.contains("calorie") else { throw ReadError.notALabel }
        let session = LanguageModelSession(instructions: instructions)
        let label = try await session.respond(to: "Label text:\n\(text)", generating: NutritionLabel.self).content
        guard label.calories >= 0, label.calories < 3000 else { throw ReadError.notALabel }
        return LabelReading(
            servingText: label.servingSize.isEmpty ? nil : label.servingSize,
            servingGrams: label.servingGrams,
            calories: label.calories,
            fat: label.fat,
            carbs: label.carbs,
            protein: label.protein,
            fiber: label.fiber
        )
    }
}
