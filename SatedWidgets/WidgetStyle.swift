import SwiftUI
import WidgetKit

extension WidgetSnapshot {
    var accentColor: Color { Color(.sRGB, red: accent.red, green: accent.green, blue: accent.blue) }
    var isOver: Bool { calories > goalCalories * 1.1 }
    var progress: Double { goalCalories > 0 ? calories / goalCalories : 0 }

    /// Protein, carbs, fat and fiber, each with its goal and color.
    var macros: [MacroLine] {
        [
            MacroLine(name: "Protein", short: "P", value: protein, goal: goalProtein, color: .macroProtein),
            MacroLine(name: "Carbs", short: "C", value: carbs, goal: goalCarbs, color: .macroCarbs),
            MacroLine(name: "Fat", short: "F", value: fat, goal: goalFat, color: .macroFat),
            MacroLine(name: "Fiber", short: "Fb", value: fiber, goal: goalFiber, color: .macroFiber),
        ]
    }
}

struct MacroLine: Identifiable {
    var name: String
    var short: String
    var value: Double
    var goal: Double
    var color: Color
    var id: String { name }
    var progress: Double { goal > 0 ? min(value / goal, 1) : 0 }
}

// The app's macro colors (DesignSystem/Theme.swift).
extension Color {
    static let macroProtein = Color(.sRGB, red: 1, green: 0x37 / 255, blue: 0x5F / 255)
    static let macroCarbs = Color(.sRGB, red: 0xF5 / 255, green: 0xA6 / 255, blue: 0x23 / 255)
    static let macroFat = Color(.sRGB, red: 0x0A / 255, green: 0x84 / 255, blue: 1)
    static let macroFiber = Color(.sRGB, red: 0x2F / 255, green: 0xB5 / 255, blue: 0x7A / 255)
    static let overGoal = Color(.sRGB, red: 1, green: 0x37 / 255, blue: 0x5F / 255)
}

enum Format {
    static func whole(_ value: Double) -> String { Int(value.rounded()).formatted() }
}

/// The calorie ring: fills toward the goal, red once well over it.
struct CalorieRing: View {
    var snapshot: WidgetSnapshot
    var lineWidth: CGFloat

    var body: some View {
        let color = snapshot.isOver ? Color.overGoal : snapshot.accentColor
        ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(snapshot.progress, 0.001), 1))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
        }
    }
}

/// "1,122" over "kcal left", or "+240" over "over goal".
struct CaloriesLeftLabel: View {
    var snapshot: WidgetSnapshot
    var size: CGFloat

    var body: some View {
        let left = snapshot.caloriesLeft
        VStack(spacing: 0) {
            Text(left >= 0 ? Format.whole(left) : "+" + Format.whole(-left))
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(.numericText())
                .widgetAccentable()
            Text(left >= 0 ? "kcal left" : "over goal")
                .font(.system(size: max(size * 0.38, 10), weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// A macro with its bar: "Protein  112 / 180 g".
struct MacroRow: View {
    var macro: MacroLine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(macro.name)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                Text("\(Text(Format.whole(macro.value)).foregroundStyle(.primary)) / \(Format.whole(macro.goal)) g")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(macro.color.opacity(0.18))
                    Capsule()
                        .fill(macro.color.gradient)
                        .frame(width: max(proxy.size.width * macro.progress, macro.value > 0 ? 5 : 0))
                        .widgetAccentable()
                }
            }
            .frame(height: 5)
        }
    }
}

/// Days logged in a row, with a flame.
struct StreakLabel: View {
    var streak: Int
    var color: Color

    var body: some View {
        if streak > 0 {
            Label("\(streak)", systemImage: "flame.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
                .monospacedDigit()
                .labelStyle(.titleAndIcon)
                .imageScale(.small)
        }
    }
}

/// The round + that opens Add Food.
struct AddFoodButton: View {
    var color: Color

    var body: some View {
        Link(destination: SatedLink.addFood) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color.gradient, in: .circle)
                .widgetAccentable()
        }
        .accessibilityLabel("Add Food")
    }
}

extension View {
    /// The widget background: the system color with a soft glow of the accent.
    func satedBackground(_ snapshot: WidgetSnapshot) -> some View {
        containerBackground(for: .widget) {
            ZStack {
                Color(uiColor: .systemBackground)
                RadialGradient(
                    colors: [snapshot.accentColor.opacity(0.16), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 260
                )
            }
        }
    }
}
