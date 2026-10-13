import CoreGraphics
import Foundation

/// A piece of text the camera recognized, with where it sits on screen.
nonisolated struct TextPiece: Sendable, Equatable {
    var text: String
    var rect: CGRect
}

/// What was read from a Nutrition Facts panel. Every value is per serving, and nil when it
/// wasn't found.
nonisolated struct LabelReading: Sendable, Equatable {
    var servingText: String?
    var servingGrams: Double?
    var calories: Double?
    var fat: Double?
    var carbs: Double?
    var protein: Double?
    var fiber: Double?

    /// Calories, fat, carbs and protein: enough to log it.
    var hasCore: Bool { calories != nil && fat != nil && carbs != nil && protein != nil }

    /// Whether the printed calories agree with the macros (4 kcal per gram of protein and carbs,
    /// 9 per gram of fat). Labels round, and fiber and sugar alcohols count for less, so it
    /// allows a quarter either way. A misread digit (8 read as 0, a dropped digit) fails it.
    var isConsistent: Bool {
        guard let calories, let fat, let carbs, let protein else { return false }
        let estimate = protein * 4 + carbs * 4 + fat * 9
        if calories < 30, estimate < 30 { return true }
        return abs(estimate - calories) <= max(20, 0.25 * max(calories, estimate))
    }

    /// This reading with any gaps filled from `other`.
    func filled(from other: LabelReading) -> LabelReading {
        LabelReading(
            servingText: servingText ?? other.servingText,
            servingGrams: servingGrams ?? other.servingGrams,
            calories: calories ?? other.calories,
            fat: fat ?? other.fat,
            carbs: carbs ?? other.carbs,
            protein: protein ?? other.protein,
            fiber: fiber ?? other.fiber
        )
    }
}

/// Finds the Nutrition Facts panel among everything the camera reads, and reads it with rules
/// rather than a model: the panel's format is regulated, so "Total Fat 8g" and "Calories 230"
/// can be matched directly, and a number is never invented.
nonisolated enum LabelParser {
    // MARK: Finding the panel

    /// Words that only appear on (or right next to) a nutrition panel.
    static let panelWords = [
        "nutrition facts", "valeur nutritive", "nutrition information", "calorie", "total fat",
        "lipides", "saturated", "trans fat", "cholesterol", "sodium", "carbohydrate", "glucides",
        "dietary fiber", "fibre", "total sugars", "sucres", "protein", "proteines",
        "serving size", "servings per", "daily value", "valeur quotidienne",
    ]

    /// The panel: the text that belongs to it and the box around it, in the same coordinates
    /// as the pieces. Nil when there's no panel in view.
    static func locatePanel(_ pieces: [TextPiece]) -> (rect: CGRect, pieces: [TextPiece])? {
        let anchors = pieces.filter { piece in
            let text = fold(piece.text)
            return panelWords.contains { text.contains($0) }
        }
        let anchorText = anchors.map { fold($0.text) }.joined(separator: " ")
        guard anchors.count >= 3, anchorText.contains("calorie"),
              ["fat", "lipides", "carbohydrate", "glucides", "protein"].contains(where: anchorText.contains)
        else { return nil }

        // Start from the heading, or the calories line, and grow through nearby panel lines.
        // Packaging text elsewhere ("20g Protein!" on the front) is too far away to join.
        let seed = anchors.first { let t = fold($0.text); return t.contains("nutrition facts") || t.contains("valeur nutritive") }
            ?? anchors.first { fold($0.text).contains("calorie") }!
        let lineHeight = median(anchors.map(\.rect.height))
        let reach = max(lineHeight * 2.2, 12)
        var cluster = [seed]
        var box = seed.rect
        var remaining = anchors.filter { $0 != seed }
        var grew = true
        while grew {
            grew = false
            for (index, piece) in remaining.enumerated().reversed() where box.insetBy(dx: -reach, dy: -reach).intersects(piece.rect) {
                cluster.append(piece)
                box = box.union(piece.rect)
                remaining.remove(at: index)
                grew = true
            }
        }
        guard cluster.count >= 3 else { return nil }

        // Then take in the values and percentages on the same rows, which may sit to the right
        // of the names (or in a second column on dual-column labels).
        let rows = box.insetBy(dx: 0, dy: -lineHeight * 0.5)
        let sideways = box.width * 0.9
        let members = pieces.filter { piece in
            let mid = CGPoint(x: piece.rect.midX, y: piece.rect.midY)
            return mid.y >= rows.minY && mid.y <= rows.maxY
                && piece.rect.maxX >= box.minX - lineHeight && piece.rect.minX <= box.maxX + sideways
        }
        let panel = members.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        return (panel.insetBy(dx: -8, dy: -8), members)
    }

    /// The panel's text as lines, top to bottom: pieces on the same baseline are joined left
    /// to right, so "Calories" and "230" printed apart become "Calories 230".
    static func rows(_ pieces: [TextPiece]) -> [String] {
        let sorted = pieces.sorted { $0.rect.midY < $1.rect.midY }
        var rows: [[TextPiece]] = []
        for piece in sorted {
            if let last = rows.last?.last, abs(piece.rect.midY - last.rect.midY) < min(piece.rect.height, last.rect.height) * 0.5 {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }
        return rows.map { $0.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " ") }
    }

    // MARK: Reading it

    static func parse(_ lines: [String]) -> LabelReading {
        let rows = lines.map(clean)
        var reading = LabelReading()
        reading.calories = calories(in: rows)
        reading.fat = grams(in: rows, keys: ["total fat", "fat / lipides", "lipides", "fat"], skip: ["saturated", "sat.", "trans", "calories from", "satures"])
        reading.carbs = grams(in: rows, keys: ["total carbohydrate", "total carb", "carbohydrate", "glucides", "carbs"], skip: [])
        reading.protein = grams(in: rows, keys: ["protein", "proteines"], skip: [])
        reading.fiber = grams(in: rows, keys: ["dietary fiber", "dietary fibre", "fiber", "fibre", "fibres"], skip: ["soluble", "insoluble"])
        (reading.servingText, reading.servingGrams) = serving(in: lines)
        return reading
    }

    /// Fixes common camera misreads in numbers: "1Og" → "10g", "Og" → "0g".
    static func clean(_ line: String) -> String {
        var text = fold(line)
        text = text.replacingOccurrences(of: #"(?<=\d)o|o(?=\d)"#, with: "0", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<![a-z])o\s?g\b"#, with: "0g", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text
    }

    private static func calories(in rows: [String]) -> Double? {
        for (index, row) in rows.enumerated() where row.contains("calorie") {
            if ["calories from", "calories a day", "calories per day", "2,000 calorie", "2000 calorie", "daily", "diet"].contains(where: row.contains) { continue }
            guard let range = row.range(of: "calorie") else { continue }
            let after = String(row[range.upperBound...])
            if let value = firstNumber(in: after, unitless: true) { return value }
            // The number printed big on its own line just below.
            if index + 1 < rows.count, let value = firstNumber(in: rows[index + 1], unitless: true),
               rows[index + 1].count <= 8 {
                return value
            }
        }
        return nil
    }

    /// The first "8g" (or "<1g") after the first matching key, on a row without any skip word.
    private static func grams(in rows: [String], keys: [String], skip: [String]) -> Double? {
        for key in keys {
            for (index, row) in rows.enumerated() {
                guard let range = row.range(of: key) else { continue }
                if skip.contains(where: row.contains) { continue }
                let after = String(row[range.upperBound...])
                if let value = firstGrams(in: after) { return value }
                if index + 1 < rows.count, let value = firstGrams(in: rows[index + 1]),
                   rows[index + 1].range(of: #"^[<\d.,\s]+g"#, options: .regularExpression) != nil {
                    return value
                }
            }
        }
        return nil
    }

    /// "8g", "8 g", "0.5g", "<1g", "less than 1g". Not "mg", not "%".
    static func firstGrams(in text: String) -> Double? {
        let pattern = #"(<|less than)?\s*(\d+(?:[.,]\d+)?)\s*g(?![a-z])"#
        guard let match = text.range(of: pattern, options: .regularExpression) else { return nil }
        let found = String(text[match])
        guard let number = found.range(of: #"\d+(?:[.,]\d+)?"#, options: .regularExpression) else { return nil }
        let value = Double(found[number].replacingOccurrences(of: ",", with: ".")) ?? 0
        let lessThan = found.hasPrefix("<") || found.hasPrefix("less")
        return lessThan ? value / 2 : value
    }

    /// The first number that isn't a percentage, gram or milligram amount ("Calories 230 12%").
    private static func firstNumber(in text: String, unitless: Bool) -> Double? {
        let pattern = #"\d{1,4}(?:,\d{3})?(?![\d.,]*\s*(%|g|mg|kj))"#
        guard let match = text.range(of: pattern, options: .regularExpression) else { return nil }
        return Double(text[match].replacingOccurrences(of: ",", with: ""))
    }

    /// "2/3 cup (55g)" from "Serving size 2/3 cup (55g)", or Canada's "Per 1 cup (250 mL)".
    static func serving(in lines: [String]) -> (String?, Double?) {
        for line in lines {
            let folded = fold(line)
            var rest: String?
            if let range = line.range(of: #"(?i)serving\s*size"#, options: .regularExpression) {
                rest = String(line[range.upperBound...])
            } else if folded.hasPrefix("per "), !folded.contains("container") {
                rest = String(line.dropFirst(4))
            }
            guard var text = rest?.trimmingCharacters(in: CharacterSet(charactersIn: " :.-")) else { continue }
            // Bilingual labels keep the English part: "1 cup (250 mL) / pour 1 tasse (250 mL)"
            // → "1 cup (250 mL)", and "1 cup / 1 tasse (250 mL)" → "1 cup (250 mL)".
            if let slash = text.range(of: " / ") {
                let head = String(text[..<slash.lowerBound])
                let tail = text[slash.upperBound...]
                if head.contains("(") {
                    text = head
                } else {
                    let amount = tail.range(of: #"\([^)]*\)"#, options: .regularExpression).map { String(tail[$0]) }
                    text = head + (amount.map { " " + $0 } ?? "")
                }
            }
            guard !text.isEmpty else { continue }
            var grams: Double?
            if let match = text.range(of: #"(\d+(?:\.\d+)?)\s*g\b"#, options: .regularExpression),
               let number = text[match].range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression) {
                grams = Double(text[match][number])
            }
            return (text, grams)
        }
        return (nil, nil)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 16 }
        return sorted[sorted.count / 2]
    }
}

/// Readings from many camera frames, voted per value. A value counts once the same number has
/// been read `needed` times, which smooths over a single frame's misread digit.
nonisolated struct LabelConsensus: Sendable {
    private var votes: [String: [Double: Int]] = [:]
    private var servingVotes: [String: Int] = [:]
    private(set) var frames = 0

    mutating func add(_ reading: LabelReading) {
        frames += 1
        let values: [(String, Double?)] = [
            ("calories", reading.calories), ("fat", reading.fat), ("carbs", reading.carbs),
            ("protein", reading.protein), ("fiber", reading.fiber), ("grams", reading.servingGrams),
        ]
        for (key, value) in values {
            guard let value else { continue }
            votes[key, default: [:]][value, default: 0] += 1
        }
        if let serving = reading.servingText {
            servingVotes[serving, default: 0] += 1
        }
    }

    func confirmed(needed: Int = 3) -> LabelReading {
        func winner(_ key: String) -> Double? {
            guard let best = votes[key]?.max(by: { $0.value < $1.value }), best.value >= needed else { return nil }
            return best.key
        }
        let serving = servingVotes.max(by: { $0.value < $1.value }).flatMap { $0.value >= needed ? $0.key : nil }
        return LabelReading(
            servingText: serving,
            servingGrams: winner("grams"),
            calories: winner("calories"),
            fat: winner("fat"),
            carbs: winner("carbs"),
            protein: winner("protein"),
            fiber: winner("fiber")
        )
    }

    /// The most-read value for each field so far, however few votes it has.
    func leading() -> LabelReading {
        confirmed(needed: 1)
    }
}
