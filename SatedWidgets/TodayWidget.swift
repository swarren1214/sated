import SwiftUI
import WidgetKit

/// Today at a glance: the calorie ring with all four macros (medium), plus meals and the week
/// (large). The + opens Add Food.
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.stephenwarren.sated.today", provider: SnapshotProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Today")
        .description("Calories, protein, carbs, fat and fiber against your goals.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct TodayWidgetView: View {
    var entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: WidgetSnapshot { entry.snapshot }

    var body: some View {
        Group {
            if family == .systemLarge || family == .systemExtraLarge {
                large
            } else {
                medium
            }
        }
        .redacted(reason: entry.isSample ? .placeholder : [])
        .widgetURL(SatedLink.today)
        .satedBackground(snapshot)
    }

    // MARK: Medium

    private var medium: some View {
        HStack(spacing: 18) {
            ZStack {
                CalorieRing(snapshot: snapshot, lineWidth: 12)
                CaloriesLeftLabel(snapshot: snapshot, size: 24)
                    .padding(.horizontal, 14)
            }
            .frame(width: 118, height: 118)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.macros) { MacroRow(macro: $0) }
            }
        }
        .overlay(alignment: .topTrailing) {
            AddFoodButton(color: snapshot.accentColor)
                .offset(x: 6, y: -6)
        }
    }

    // MARK: Large

    private var large: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            HStack(spacing: 18) {
                ZStack {
                    CalorieRing(snapshot: snapshot, lineWidth: 12)
                    CaloriesLeftLabel(snapshot: snapshot, size: 24)
                        .padding(.horizontal, 14)
                }
                .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.macros) { MacroRow(macro: $0) }
                }
            }

            meals

            week
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Today")
                    .font(.headline)
                Text("\(Format.whole(snapshot.calories)) of \(Format.whole(snapshot.goalCalories)) kcal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            StreakLabel(streak: snapshot.streak, color: snapshot.accentColor)
            AddFoodButton(color: snapshot.accentColor)
        }
    }

    private var meals: some View {
        VStack(spacing: 0) {
            ForEach(snapshot.meals) { meal in
                HStack(spacing: 10) {
                    Image(systemName: meal.symbol)
                        .font(.caption)
                        .foregroundStyle(meal.logged ? snapshot.accentColor : Color.secondary)
                        .frame(width: 18)
                        .widgetAccentable()
                    Text(meal.name)
                        .font(.subheadline)
                    Spacer()
                    if meal.logged {
                        Text("\(Format.whole(meal.calories)) kcal")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text("Open")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(snapshot.accentColor)
                    }
                }
                .frame(height: 24)
            }
        }
    }

    /// The last seven days as bars against the goal line; today in the accent.
    private var week: some View {
        let goal = max(snapshot.goalCalories, 1)
        let top = max(snapshot.week.map(\.calories).max() ?? 0, goal) * 1.08
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(snapshot.week) { day in
                let isToday = Calendar.current.isDate(day.date, inSameDayAs: snapshot.day)
                VStack(spacing: 4) {
                    GeometryReader { proxy in
                        VStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(barColor(day.calories, isToday: isToday))
                                .frame(height: max(proxy.size.height * day.calories / top, day.calories > 0 ? 3 : 0))
                                .widgetAccentable(isToday)
                        }
                    }
                    Text(day.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption2.weight(isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? AnyShapeStyle(snapshot.accentColor) : AnyShapeStyle(.secondary))
                }
            }
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) {
            // The goal line, at the goal's height within the bar area.
            GeometryReader { proxy in
                let barArea = proxy.size.height - 16
                Rectangle()
                    .fill(.secondary.opacity(0.5))
                    .frame(height: 1)
                    .offset(y: barArea * (1 - goal / top))
            }
            .allowsHitTesting(false)
        }
    }

    private func barColor(_ calories: Double, isToday: Bool) -> Color {
        let goal = snapshot.goalCalories
        if calories > goal * 1.1 { return .overGoal }
        if isToday || calories >= goal * 0.9 { return snapshot.accentColor }
        return snapshot.accentColor.opacity(0.35)
    }
}

#Preview(as: .systemMedium) {
    TodayWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample)
}

#Preview(as: .systemLarge) {
    TodayWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .sample)
}
