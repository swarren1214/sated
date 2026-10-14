import Foundation

// What the iPhone and the Watch send each other over WatchConnectivity.
//
// The iPhone keeps the log. It sends the Watch a `WatchSnapshot` (today's totals, goals and
// usuals) as its application context whenever something changes. The Watch sends back
// `WatchLogRequest`s through `transferUserInfo`, which queues them until the phone is in range,
// and asks the phone to parse dictation with `sendMessage`. Every payload travels as JSON
// `Data` under one key, so both sides decode the same Codable types.
//
// Compiled into the app, the Watch app and the widget extension.

nonisolated enum WatchLink {
    static let kindKey = "kind"
    static let payloadKey = "payload"

    enum Kind: String, Sendable {
        /// Phone → Watch, application context: a `WatchSnapshot`.
        case snapshot
        /// Watch → phone, message with reply: a `WatchParseRequest`, answered with a `WatchParseReply`.
        case parse
        /// Watch → phone, user info: a `WatchLogRequest`.
        case log
    }

    static func message(_ kind: Kind, _ value: some Encodable) throws -> [String: Any] {
        [kindKey: kind.rawValue, payloadKey: try encoder.encode(value)]
    }

    static func kind(of message: [String: Any]) -> Kind? {
        (message[kindKey] as? String).flatMap(Kind.init(rawValue:))
    }

    /// The raw JSON, so it can cross to the main actor before decoding.
    static func payload(of message: [String: Any]) -> Data? {
        message[payloadKey] as? Data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func encode(_ value: some Encodable) throws -> Data {
        try encoder.encode(value)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

/// A food the Watch can log: one of the person's usuals, or a match for something they said.
/// Nutrients are per serving; `servings` scales them.
nonisolated struct WatchFood: Codable, Hashable, Sendable, Identifiable {
    /// Stable within one snapshot or reply, for lists.
    var id: String
    /// The bundled food or barcode it came from, kept so the phone's Recent and usuals match.
    var foodID: String?
    var name: String
    var brand: String?
    var serving: String
    var servings: Double
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var fiber: Double
    /// `FoodSource` raw value.
    var source: String
    var placeID: String?
    var placeName: String?

    var totalCalories: Double { calories * servings }
    var totalProtein: Double { protein * servings }

    /// "2 × 1 large egg", or the serving alone for one serving.
    var amountText: String {
        servings == 1 ? serving : "\(servings.formatted(.number.precision(.fractionLength(0...2)))) × \(serving)"
    }
}

/// What the Watch shows: today's totals and goals, and the usual foods for each meal.
nonisolated struct WatchSnapshot: Codable, Hashable, Sendable {
    /// The start of the day the totals are for.
    var day: Date
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var fiber: Double
    var goalCalories: Double
    var goalProtein: Double
    var goalCarbs: Double
    var goalFat: Double
    var goalFiber: Double
    /// Usual foods by `Meal` raw value, best first.
    var usuals: [String: [WatchFood]]
    /// The Watch log requests the phone has already filed, newest last, so the Watch can stop
    /// counting them as pending.
    var appliedLogIDs: [UUID]
    var accent: WidgetSnapshot.RGB

    func usuals(for meal: Meal) -> [WatchFood] { usuals[meal.rawValue] ?? [] }

    /// Today's totals as the Watch should show them on `date`: the phone's numbers (zero once
    /// the day has turned over), plus anything logged on the Watch that the phone hasn't filed yet.
    func totals(on date: Date, adding pending: [WatchLogRequest], calendar: Calendar = .current) -> WatchTotals {
        let today = calendar.startOfDay(for: date)
        var totals = today > day
            ? WatchTotals()
            : WatchTotals(calories: calories, protein: protein, carbs: carbs, fat: fat, fiber: fiber)
        let applied = Set(appliedLogIDs)
        for request in pending where !applied.contains(request.id) && calendar.isDate(request.date, inSameDayAs: today) {
            totals.add(request)
        }
        return totals
    }

    /// Before the phone has sent anything.
    static let empty = WatchSnapshot(
        day: .distantPast,
        calories: 0, protein: 0, carbs: 0, fat: 0, fiber: 0,
        goalCalories: 2400, goalProtein: 180, goalCarbs: 240, goalFat: 75, goalFiber: 35,
        usuals: [:],
        appliedLogIDs: [],
        accent: WidgetSnapshot.RGB(red: 0xE8 / 255, green: 0x65 / 255, blue: 0x0F / 255)
    )
}

/// Calories and macros for the Watch's summary.
nonisolated struct WatchTotals: Hashable, Sendable {
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var fiber: Double = 0

    mutating func add(_ request: WatchLogRequest) {
        for food in request.foods {
            calories += food.calories * food.servings
            protein += food.protein * food.servings
            carbs += food.carbs * food.servings
            fat += food.fat * food.servings
            fiber += food.fiber * food.servings
        }
    }
}

/// Foods logged on the Watch, for the phone to file. The `id` makes it safe to send twice.
nonisolated struct WatchLogRequest: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var date: Date
    /// `Meal` raw value.
    var meal: String
    var foods: [WatchFood]
}

/// Something said on the Watch, for the phone's on-device model to turn into foods.
nonisolated struct WatchParseRequest: Codable, Sendable {
    var text: String
}

nonisolated struct WatchParseReply: Codable, Sendable {
    /// The meal they named, as a `Meal` raw value, if they named one.
    var meal: String?
    var foods: [WatchFood] = []
    /// Foods they said that weren't found, as said ("2 slices of mystery bread").
    var unmatched: [String] = []
    /// Set when nothing could be worked out; shown as is.
    var error: String?
}
