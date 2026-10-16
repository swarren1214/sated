import Charts
import SwiftData
import SwiftUI

/// Day, week and month summaries. Every number is computed in Summaries; nothing is estimated.
struct TrendsView: View {
    enum Range: String, CaseIterable, Identifiable {
        case day = "Day", week = "Week", month = "Month"
        var id: String { rawValue }
    }

    @State private var range: Range = .week
    @Query private var entries: [FoodEntry]
    @AppStorage(SettingsKey.goalCalories) private var goalCalories = Goals.defaults.calories
    @AppStorage(SettingsKey.goalProtein) private var goalProtein = Goals.defaults.protein
    @AppStorage(SettingsKey.goalCarbs) private var goalCarbs = Goals.defaults.carbs
    @AppStorage(SettingsKey.goalFat) private var goalFat = Goals.defaults.fat
    @AppStorage(SettingsKey.goalFiber) private var goalFiber = Goals.defaults.fiber

    private let calendar = Calendar.current

    init() {
        // Two months back covers this month and the last one for comparison.
        let start = Calendar.current.date(byAdding: .day, value: -62, to: Calendar.current.startOfDay(for: .now)) ?? .now
        _entries = Query(filter: #Predicate<FoodEntry> { $0.date >= start }, sort: \.date)
    }

    private var goals: Goals {
        Goals(calories: goalCalories, protein: goalProtein, carbs: goalCarbs, fat: goalFat, fiber: goalFiber)
    }

    var body: some View {
        let records = entries.map(\.record)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeaderTitle("Trends")
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch range {
                case .day: DayTrends(entries: entries.filter { calendar.isDateInToday($0.date) }, goals: goals)
                case .week: WeekTrends(records: records, goals: goals)
                case .month: MonthTrends(records: records, goals: goals)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .readableWidth(760)
        }
        .refreshable { await CloudRefresh.refresh() }
        .colorHeader("Trends")
        // The tab's own tint, so charts, rings and headings match the accent.
        .tint(Accent.color)
        // Screenshot mode (Debug): the range the screenshot asks for.
        .task {
            switch ScreenshotMode.screen {
            case .month?: range = .month
            case .day?: range = .day
            default: break
            }
        }
    }
}

// MARK: - Week

private struct WeekTrends: View {
    var records: [EntryRecord]
    var goals: Goals
    private let calendar = Calendar.current

    var body: some View {
        let today = calendar.startOfDay(for: .now)
        let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let days = Summaries.days(records, from: start, through: today, calendar: calendar)
        // Averages use finished days only; today is still in progress.
        let stats = PeriodStats(days: Array(days.dropLast()), goals: goals)
        let average = stats.average
        let difference = average.calories - goals.calories
        let loggedCount = stats.logged.count

        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text("LAST 7 DAYS · \(start.formatted(.dateTime.month(.abbreviated).day()))–\(today.formatted(.dateTime.day()))")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(Text(Int(average.calories.rounded()).formatted()).font(.largeTitle.bold())) \(Text("kcal / day").foregroundStyle(.secondary))")
                    .monospacedDigit()
                if loggedCount > 0 {
                    Text("\(Text("\(difference >= 0 ? "+" : "−")\(Int(abs(difference).rounded()))").foregroundStyle(difference > 0 ? Color.over : Color.green).fontWeight(.semibold)) vs goal · today in progress")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                CalorieChart(days: days, goal: goals.calories)
                    .frame(height: 190)
                    .padding(.top, 12)
                ChartLegend()
            }
        }

        Grid(horizontalSpacing: 8) {
            GridRow {
                StatTile(title: "On target", value: "\(stats.daysOnTarget)", unit: "/\(loggedCount) days")
                StatTile(title: "Protein goal", value: "\(stats.proteinGoalDays)", unit: "/\(loggedCount) days")
                StatTile(title: "Fiber goal", value: "\(stats.fiberGoalDays)", unit: "/\(loggedCount) days")
            }
        }

        SectionHeader("Daily Averages")
        Card(padding: 12) {
            VStack(spacing: 0) {
                ForEach(Macro.allCases) { macro in
                    MacroBarRow(macro: macro, value: macro.value(in: average), goal: macro.goal(in: goals))
                }
            }
            .padding(.horizontal, 4)
        }

        SummaryText(title: "WEEKLY SUMMARY", text: Summaries.weekText(stats, calendar: calendar))
    }
}

private struct CalorieChart: View {
    var days: [DaySummary]
    var goal: Double
    private let calendar = Calendar.current

    var body: some View {
        Chart {
            ForEach(days) { day in
                let isToday = calendar.isDateInToday(day.date)
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Calories", day.totals.calories),
                    width: .ratio(0.6)
                )
                .foregroundStyle(color(for: day, isToday: isToday))
                .opacity(isToday ? 0.35 : 1)
                .cornerRadius(6)
                .annotation(position: .top, spacing: 4) {
                    if day.isLogged {
                        Text("\((day.totals.calories / 1000).formatted(.number.precision(.fractionLength(1))))k")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            RuleMark(y: .value("Goal", goal))
                .foregroundStyle(Color.primary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                .annotation(position: .top, alignment: .trailing) {
                    Text("Goal \(Int(goal).formatted())")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let kcal = value.as(Double.self) { Text("\(Int(kcal / 1000))k") }
                }
            }
        }
        .accessibilityLabel("Daily calories for the last 7 days")
    }

    private func color(for day: DaySummary, isToday: Bool) -> Color {
        if isToday { return Accent.color }
        switch CalorieStatus(calories: day.totals.calories, goal: goal) {
        case .over: return .over
        case .under: return .gray
        case .on: return Accent.color
        }
    }
}

private struct ChartLegend: View {
    var body: some View {
        HStack(spacing: 16) {
            item("Within 10%", AnyShapeStyle(.tint))
            item("Over", AnyShapeStyle(Color.over))
            item("Under", AnyShapeStyle(Color.gray))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private func item(_ title: String, _ style: AnyShapeStyle) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(style).frame(width: 9, height: 9)
            Text(title)
        }
    }
}

// MARK: - Day

private struct DayTrends: View {
    var entries: [FoodEntry]
    var goals: Goals

    var body: some View {
        let totals = entries.reduce(Nutrients.zero) { $0 + $1.nutrients }
        let split = totals.calorieSplit

        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("TODAY SO FAR").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(Text(Int(totals.calories.rounded()).formatted()).font(.largeTitle.bold())) \(Text("of \(Int(goals.calories).formatted()) kcal").foregroundStyle(.secondary))")
                    .monospacedDigit()
                Text("Calories by macro").font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
                GeometryReader { proxy in
                    HStack(spacing: 3) {
                        Macro.protein.color.frame(width: max(0, proxy.size.width * split.protein - 2))
                        Macro.carbs.color.frame(width: max(0, proxy.size.width * split.carbs - 2))
                        Macro.fat.color.frame(width: max(0, proxy.size.width * split.fat - 2))
                    }
                }
                .frame(height: 16)
                .background(.quaternary)
                .clipShape(.capsule)
                HStack(spacing: 16) {
                    share(.protein, split.protein)
                    share(.carbs, split.carbs)
                    share(.fat, split.fat)
                }
                .font(.footnote)
            }
        }

        SectionHeader("Timeline")
        Card(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Meal.allCases) { meal in
                    let items = entries.filter { $0.meal == meal }
                    HStack(spacing: 12) {
                        Text(items.first?.date.formatted(date: .omitted, time: .shortened) ?? "—")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 70, alignment: .leading)
                        Group {
                            if items.isEmpty {
                                Circle().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                            } else {
                                Circle().fill(.tint)
                            }
                        }
                        .frame(width: 10, height: 10)
                        Text(meal.name)
                        Spacer()
                        if items.isEmpty {
                            Text("Open").fontWeight(.semibold).foregroundStyle(.tint)
                        } else {
                            Text("\(Int(items.reduce(0) { $0 + $1.nutrients.calories }.rounded())) kcal")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    if meal != Meal.allCases.last { Divider().padding(.leading, 16) }
                }
            }
        }

        SectionHeader("Against Goals")
        Card(padding: 12) {
            VStack(spacing: 0) {
                ForEach(Macro.allCases) { macro in
                    MacroBarRow(macro: macro, value: macro.value(in: totals), goal: macro.goal(in: goals))
                }
            }
            .padding(.horizontal, 4)
        }

        let open = Meal.allCases.filter { meal in meal != .snack && !entries.contains { $0.meal == meal } }
        SummaryText(title: "DAY SUMMARY", text: Summaries.dayText(totals: totals, goals: goals, openMeals: open))
    }

    private func share(_ macro: Macro, _ value: Double) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(macro.color).frame(width: 9, height: 9)
            Text("\(Text(macro.name).foregroundStyle(.secondary)) \(Text("\(Int((value * 100).rounded()))%").bold())")
                .monospacedDigit()
        }
    }
}

// MARK: - Month

private struct MonthTrends: View {
    var records: [EntryRecord]
    var goals: Goals
    private let calendar = Calendar.current

    var body: some View {
        let today = calendar.startOfDay(for: .now)
        let monthStart = calendar.dateInterval(of: .month, for: today)?.start ?? today
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let finished = monthStart <= yesterday ? Summaries.days(records, from: monthStart, through: yesterday, calendar: calendar) : []
        let stats = PeriodStats(days: finished, goals: goals)
        let previous = previousMonthAverage(before: monthStart)
        let monthEnd = calendar.dateInterval(of: .month, for: today).flatMap { calendar.date(byAdding: .day, value: -1, to: $0.end) } ?? today
        let monthDays = Summaries.days(records, from: monthStart, through: monthEnd, calendar: calendar)
        let leading = (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7

        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(today.formatted(.dateTime.month(.wide).year()).uppercased())
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(Text(Int(stats.average.calories.rounded()).formatted()).font(.largeTitle.bold())) \(Text("kcal / day").foregroundStyle(.secondary))")
                    .monospacedDigit()
                Text("\(stats.logged.count) days logged · \(stats.daysOnTarget) on target")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                MonthCalendar(
                    days: monthDays,
                    leading: leading,
                    goal: goals.calories,
                    today: today,
                    weekdays: calendar.veryShortWeekdaySymbols.rotated(by: calendar.firstWeekday - 1)
                )
                .padding(.top, 16)
            }
        }

        Grid(horizontalSpacing: 8) {
            GridRow {
                StatTile(title: "Avg protein", value: Grams.text(stats.average.protein), unit: " g")
                StatTile(title: "Avg fiber", value: Grams.text(stats.average.fiber), unit: " g")
                StatTile(title: "Last month", value: previous.map { Int($0.rounded()).formatted() } ?? "—", unit: previous == nil ? "" : " avg")
            }
        }

        SummaryText(title: "MONTHLY SUMMARY", text: Summaries.monthText(stats, previousAverage: previous, calendar: calendar))
    }

    private func previousMonthAverage(before monthStart: Date) -> Double? {
        guard let lastMonthEnd = calendar.date(byAdding: .day, value: -1, to: monthStart),
              let interval = calendar.dateInterval(of: .month, for: lastMonthEnd) else { return nil }
        let days = Summaries.days(records, from: interval.start, through: lastMonthEnd, calendar: calendar)
        let stats = PeriodStats(days: days, goals: goals)
        return stats.logged.isEmpty ? nil : stats.average.calories
    }
}

/// The month as a grid of small calorie rings, like Activity: each ring fills toward the
/// calorie goal, in the accent when the day was within 10%, red when over, and a lighter accent
/// when under. Today is marked in the accent; days still to come are just numbers.
private struct MonthCalendar: View {
    var days: [DaySummary]
    var leading: Int
    var goal: Double
    var today: Date
    var weekdays: [String]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: 1) }
                ForEach(days) { day in
                    DayRing(
                        day: day,
                        goal: goal,
                        isToday: Calendar.current.isDate(day.date, inSameDayAs: today),
                        isFuture: day.date > today
                    )
                }
            }
            HStack(spacing: 16) {
                legend("On target", AnyShapeStyle(.tint))
                legend("Over", AnyShapeStyle(Color.over))
                legend("Under", AnyShapeStyle(.tint.opacity(0.4)))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
    }

    private func legend(_ title: String, _ style: AnyShapeStyle) -> some View {
        HStack(spacing: 5) {
            Circle().strokeBorder(style, lineWidth: 2.5).frame(width: 10, height: 10)
            Text(title)
        }
    }
}

private struct DayRing: View {
    var day: DaySummary
    var goal: Double
    var isToday: Bool
    var isFuture: Bool

    private let lineWidth: CGFloat = 3.5

    var body: some View {
        ZStack {
            if !isFuture {
                Circle()
                    .stroke(isToday ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.quaternary), lineWidth: lineWidth)
                if day.isLogged {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(ringStyle, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            Text(day.date.formatted(.dateTime.day()))
                .font(.system(size: 13, weight: isToday ? .bold : .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(numberStyle)
        }
        .padding(lineWidth / 2 + 1)
        .frame(maxWidth: 40)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var status: CalorieStatus { CalorieStatus(calories: day.totals.calories, goal: goal) }

    private var progress: Double {
        min(max(day.totals.calories / max(goal, 1), 0.04), 1)
    }

    private var ringStyle: AnyShapeStyle {
        switch status {
        case .on: AnyShapeStyle(.tint)
        case .over: AnyShapeStyle(Color.over)
        case .under: AnyShapeStyle(.tint.opacity(0.4))
        }
    }

    private var numberStyle: AnyShapeStyle {
        if isToday { return AnyShapeStyle(.tint) }
        if isFuture { return AnyShapeStyle(.tertiary) }
        return day.isLogged ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    private var accessibilityText: String {
        let date = day.date.formatted(.dateTime.month(.wide).day())
        guard !isFuture else { return date }
        guard day.isLogged else { return "\(date), nothing logged" }
        let kcal = Int(day.totals.calories.rounded()).formatted()
        let verdict = switch status {
        case .on: "on target"
        case .over: "over goal"
        case .under: "under goal"
        }
        return "\(date), \(kcal) calories, \(verdict)"
    }
}

// MARK: - Shared

private struct StatTile: View {
    var title: String
    var value: String
    var unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text("\(Text(value).font(.title3.bold())) \(Text(unit).font(.footnote).foregroundStyle(.secondary))")
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}

private struct SummaryText: View {
    var title: String
    var text: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: "sparkles")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(text).font(.subheadline)
            }
        }
    }
}

private extension Array {
    func rotated(by count: Int) -> [Element] {
        guard !isEmpty else { return self }
        let shift = ((count % self.count) + self.count) % self.count
        return Array(self[shift...] + self[..<shift])
    }
}

#Preview {
    NavigationStack { TrendsView() }
        .previewEnvironment()
}
