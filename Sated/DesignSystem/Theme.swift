import SwiftUI

/// Keys for settings stored with @AppStorage. Keep every key here so views stay in sync.
nonisolated enum SettingsKey {
    static let appearance = "settings.appearance"
    static let goalCalories = "goals.calories"
    static let goalProtein = "goals.protein"
    static let goalCarbs = "goals.carbs"
    static let goalFat = "goals.fat"
    static let goalFiber = "goals.fiber"
    static let saveToHealth = "health.save"
    static let readActiveEnergy = "health.readActive"
    static let confirmVoiceEntries = "coach.confirmVoice"
    static let spokenReplies = "coach.spokenReplies"
}

/// Sated's tint everywhere: the orange of its icon. (It used to be a setting, Accent Color.)
enum Accent {
    static let color = Color(hex: 0xE8650F)
}

/// Settings › Appearance.
enum AppearanceOption: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var name: String { rawValue.capitalized }
}

/// The four tracked macros. Each keeps one color everywhere: rings, bars, charts and labels.
enum Macro: String, CaseIterable, Identifiable {
    case protein, carbs, fat, fiber

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .protein: Color(hex: 0xFF375F)
        case .carbs: Color(hex: 0xF5A623)
        case .fat: Color(hex: 0x0A84FF)
        case .fiber: Color(hex: 0x2FB57A)
        }
    }

    func value(in nutrients: Nutrients) -> Double {
        switch self {
        case .protein: nutrients.protein
        case .carbs: nutrients.carbs
        case .fat: nutrients.fat
        case .fiber: nutrients.fiber
        }
    }

    func goal(in goals: Goals) -> Double {
        switch self {
        case .protein: goals.protein
        case .carbs: goals.carbs
        case .fat: goals.fat
        case .fiber: goals.fiber
        }
    }
}

/// "iPhone" or "iPad", for text that names the device ("Coach runs on this iPad").
enum DeviceName {
    static var current: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }
}

extension View {
    /// Keeps content to a comfortable reading width on iPad, centered; no change on iPhone.
    func readableWidth(_ maxWidth: CGFloat = 720) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Over-goal red, used for calorie days well above target. Never the accent.
    static let over = Color(hex: 0xFF375F)
}
