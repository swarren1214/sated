import SwiftUI
import WidgetKit

/// Calories left today: a ring on the Home Screen, a gauge and a line on the Lock Screen.
struct CaloriesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.stephenwarren.sated.calories", provider: SnapshotProvider()) { entry in
            CaloriesWidgetView(entry: entry)
        }
        .configurationDisplayName("Calories Left")
        .description("How much of today's calorie goal is left.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct CaloriesWidgetView: View {
    var entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: WidgetSnapshot { entry.snapshot }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            default: small
            }
        }
        .redacted(reason: entry.isSample ? .placeholder : [])
        .widgetURL(SatedLink.today)
    }

    private var small: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Today")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(snapshot.accentColor)
                    .widgetAccentable()
                Spacer()
                StreakLabel(streak: snapshot.streak, color: snapshot.accentColor)
            }
            ZStack {
                CalorieRing(snapshot: snapshot, lineWidth: 11)
                CaloriesLeftLabel(snapshot: snapshot, size: 24)
                    .padding(.horizontal, 16)
            }
        }
        .satedBackground(snapshot)
    }

    private var circular: some View {
        Gauge(value: min(snapshot.calories, snapshot.goalCalories), in: 0...max(snapshot.goalCalories, 1)) {
            Image(systemName: "fork.knife")
        } currentValueLabel: {
            Text(Format.whole(abs(snapshot.caloriesLeft)))
                .monospacedDigit()
        }
        .gaugeStyle(.accessoryCircular)
        .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        .accessibilityLabel(accessibilitySummary)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.caloriesLeft >= 0
                 ? "\(Format.whole(snapshot.caloriesLeft)) kcal left"
                 : "\(Format.whole(-snapshot.caloriesLeft)) kcal over")
                .font(.headline)
                .monospacedDigit()
                .widgetAccentable()
            Gauge(value: min(snapshot.calories, snapshot.goalCalories), in: 0...max(snapshot.goalCalories, 1)) {
                EmptyView()
            }
            .gaugeStyle(.accessoryLinearCapacity)
            Text("P \(Format.whole(snapshot.protein)) · C \(Format.whole(snapshot.carbs)) · F \(Format.whole(snapshot.fat)) g")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .containerBackground(for: .widget) { Color.clear }
        .accessibilityElement(children: .combine)
    }

    private var inline: some View {
        Text(snapshot.caloriesLeft >= 0
             ? "\(Format.whole(snapshot.caloriesLeft)) kcal left · \(Format.whole(snapshot.protein)) g protein"
             : "\(Format.whole(-snapshot.caloriesLeft)) kcal over · \(Format.whole(snapshot.protein)) g protein")
            .containerBackground(for: .widget) { Color.clear }
    }

    private var accessibilitySummary: String {
        snapshot.caloriesLeft >= 0
            ? "\(Format.whole(snapshot.caloriesLeft)) calories left today"
            : "\(Format.whole(-snapshot.caloriesLeft)) calories over today's goal"
    }
}

#Preview(as: .systemSmall) {
    CaloriesWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample)
}

#Preview(as: .accessoryRectangular) {
    CaloriesWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample)
}
