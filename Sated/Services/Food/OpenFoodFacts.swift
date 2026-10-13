import Foundation
import OSLog

/// Looks up packaged foods by barcode in Open Food Facts, straight from the phone.
///
/// Reads need no account, only a User-Agent naming the app. The limit is 15 product reads a
/// minute per person, which one-at-a-time scanning never reaches. Search is limited much more
/// tightly, so Sated never uses it: typed search runs against the bundled USDA list instead.
/// Data is ODbL; Settings › About credits it.
nonisolated struct OpenFoodFacts: Sendable {
    enum LookupError: LocalizedError {
        case notFound
        case noNutrition(name: String)
        case offline
        case busy

        var errorDescription: String? {
            switch self {
            case .notFound: "This barcode isn't in Open Food Facts yet. Scan the nutrition label instead."
            case .noNutrition(let name): "\(name) is in Open Food Facts but has no calorie data. Scan the nutrition label instead."
            case .offline: "Couldn't reach Open Food Facts. Check your connection, or scan the nutrition label instead."
            case .busy: "Open Food Facts is busy. Wait a moment and scan again."
            }
        }
    }

    var session: URLSession = .shared
    var userAgent: String

    private static let log = Logger(subsystem: "com.stephenwarren.sated", category: "openfoodfacts")

    func product(barcode: String) async throws -> FoodItem {
        let digits = barcode.filter(\.isNumber)
        guard !digits.isEmpty,
              let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(digits).json?fields=product_name,brands,serving_size,serving_quantity,nutriments")
        else { throw LookupError.notFound }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.log.error("Lookup failed: \(error.localizedDescription, privacy: .public)")
            throw LookupError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 || status == 503 { throw LookupError.busy }
        if status == 404 { throw LookupError.notFound }
        return try Self.parse(data, barcode: digits)
    }

    /// Turns an Open Food Facts product response into a food with one serving.
    /// Uses the per-serving values when the product lists them, otherwise 100 g.
    static func parse(_ data: Data, barcode: String) throws -> FoodItem {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (number(root["status"]) ?? 0) == 1,
              let product = root["product"] as? [String: Any]
        else { throw LookupError.notFound }

        let name = (product["product_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (name?.isEmpty == false ? name : nil) ?? "Product \(barcode)"
        let brand = (product["brands"] as? String)?
            .split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let nutriments = product["nutriments"] as? [String: Any] ?? [:]

        let servingGrams = number(product["serving_quantity"])
        let servingSize = (product["serving_size"] as? String)?.trimmingCharacters(in: .whitespaces)

        func value(_ key: String, per suffix: String) -> Double? { number(nutriments["\(key)_\(suffix)"]) }

        // Prefer the label's own serving; fall back to scaling 100 g values; else 100 g.
        let perServingCalories = value("energy-kcal", per: "serving")
        let per100Calories = value("energy-kcal", per: "100g")
        let useServing = perServingCalories != nil || (servingGrams != nil && per100Calories != nil)

        let label: String
        let grams: Double?
        let nutrients: Nutrients
        if useServing, let servingGrams {
            label = servingSize.flatMap { $0.isEmpty ? nil : $0 } ?? "1 serving"
            grams = servingGrams
            let factor = servingGrams / 100
            func pick(_ key: String) -> Double {
                value(key, per: "serving") ?? (value(key, per: "100g") ?? 0) * factor
            }
            nutrients = Nutrients(calories: pick("energy-kcal"), protein: pick("proteins"), carbs: pick("carbohydrates"), fat: pick("fat"), fiber: pick("fiber"))
        } else if let perServingCalories {
            label = servingSize.flatMap { $0.isEmpty ? nil : $0 } ?? "1 serving"
            grams = nil
            nutrients = Nutrients(
                calories: perServingCalories,
                protein: value("proteins", per: "serving") ?? 0,
                carbs: value("carbohydrates", per: "serving") ?? 0,
                fat: value("fat", per: "serving") ?? 0,
                fiber: value("fiber", per: "serving") ?? 0
            )
        } else if let per100Calories {
            label = "100 g"
            grams = 100
            nutrients = Nutrients(
                calories: per100Calories,
                protein: value("proteins", per: "100g") ?? 0,
                carbs: value("carbohydrates", per: "100g") ?? 0,
                fat: value("fat", per: "100g") ?? 0,
                fiber: value("fiber", per: "100g") ?? 0
            )
        } else {
            throw LookupError.noNutrition(name: displayName)
        }

        return FoodItem(id: "off.\(barcode)", name: displayName, brand: brand, serving: label, grams: grams, nutrients: nutrients, source: .openFoodFacts)
    }

    /// Open Food Facts sends numbers as numbers or strings depending on the product.
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string.replacingOccurrences(of: ",", with: "."))
        default: nil
        }
    }
}
