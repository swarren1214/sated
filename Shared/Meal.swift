import Foundation

/// The four meals a day is split into. Shared with the Watch app, which files entries the same way.
nonisolated enum Meal: String, CaseIterable, Identifiable, Codable, Sendable {
    case breakfast, lunch, snack, dinner

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .breakfast: "sunrise.fill"
        case .lunch: "sun.max.fill"
        case .snack: "carrot.fill"
        case .dinner: "moon.stars.fill"
        }
    }

    /// The meal a new entry most likely belongs to, from the time of day.
    static func suggested(for date: Date = .now, calendar: Calendar = .current) -> Meal {
        switch calendar.component(.hour, from: date) {
        case 4..<11: .breakfast
        case 11..<15: .lunch
        case 15..<17: .snack
        default: .dinner
        }
    }
}
