import SwiftData
import SwiftUI

/// Today: calories left, the four macros, a summary, and the day's meals.
struct TodayView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var showsSettings = false

    var body: some View {
        DayLog(day: day)
            .id(day)
            .navigationTitle("Today")
            .navigationSubtitle(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    StreakBadge()
                }
                // The badge draws its own glass capsule, sized to its contents.
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "person.crop.circle") { showsSettings = true }
                }
            }
            .sheet(isPresented: $showsSettings) {
                NavigationStack { SettingsView() }
            }
            .onChange(of: scenePhase) { _, phase in
                // A new day starts when the app comes back after midnight.
                if phase == .active { day = Calendar.current.startOfDay(for: .now) }
            }
    }
}

/// One day's log. Its query is fixed to that day.
private struct DayLog: View {
    let day: Date
    @Query private var entries: [FoodEntry]
    @Environment(AppRouter.self) private var router
    @Environment(HealthService.self) private var health
    @AppStorage(SettingsKey.goalCalories) private var goalCalories = Goals.defaults.calories
    @AppStorage(SettingsKey.goalProtein) private var goalProtein = Goals.defaults.protein
    @AppStorage(SettingsKey.goalCarbs) private var goalCarbs = Goals.defaults.carbs
    @AppStorage(SettingsKey.goalFat) private var goalFat = Goals.defaults.fat
    @AppStorage(SettingsKey.goalFiber) private var goalFiber = Goals.defaults.fiber

    init(day: Date) {
        self.day = day
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        _entries = Query(filter: #Predicate<FoodEntry> { $0.date >= day && $0.date < end }, sort: \.date)
    }

    private var goals: Goals {
        Goals(calories: goalCalories, protein: goalProtein, carbs: goalCarbs, fat: goalFat, fiber: goalFiber)
    }

    private var totals: Nutrients { entries.reduce(.zero) { $0 + $1.nutrients } }

    private var openMeals: [Meal] {
        let logged = Set(entries.map(\.meal))
        return Meal.allCases.filter { !logged.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                CalorieCard(totals: totals, goals: goals, active: health.activeEnergyToday)

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Macros")
                    HStack(spacing: 8) {
                        ForEach(Macro.allCases) { macro in
                            MacroRingTile(macro: macro, value: macro.value(in: totals), goal: macro.goal(in: goals))
                        }
                    }
                }

                if !entries.isEmpty {
                    SummaryCard(text: Summaries.dayText(totals: totals, goals: goals, openMeals: openMeals.filter { $0 != .snack }))
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Meals") {
                        Button("Add Food", systemImage: "plus") { router.addFood() }
                            .font(.body)
                    }
                    VStack(spacing: 0) {
                        ForEach(Meal.allCases) { meal in
                            let items = entries.filter { $0.meal == meal }
                            MealRow(meal: meal, entries: items, day: day)
                            if meal != Meal.allCases.last {
                                Divider().padding(.leading, 62)
                            }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
    }
}

private struct CalorieCard: View {
    var totals: Nutrients
    var goals: Goals
    var active: Double?

    private var left: Double { goals.calories - totals.calories }

    var body: some View {
        Card(padding: 20) {
            HStack(spacing: 20) {
                ProgressRing(progress: goals.calories > 0 ? totals.calories / goals.calories : 0, lineWidth: 16, color: left < 0 ? .over : nil) {
                    VStack(spacing: 2) {
                        Text(Int(abs(left).rounded()).formatted())
                            .font(.title.bold())
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(left >= 0 ? "KCAL LEFT" : "KCAL OVER")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 136, height: 136)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Calories")
                .accessibilityValue("\(Int(totals.calories.rounded())) of \(Int(goals.calories)) eaten, \(Int(abs(left).rounded())) \(left >= 0 ? "left" : "over")")

                VStack(alignment: .leading, spacing: 12) {
                    stat("Eaten", totals.calories)
                    stat("Goal", goals.calories)
                    if let active {
                        stat("Active · Health", active, symbol: "heart.fill")
                    }
                }
            }
        }
    }

    private func stat(_ title: String, _ value: Double, symbol: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).foregroundStyle(.pink).imageScale(.small)
                }
                Text(title)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Text("\(Text(Int(value.rounded()).formatted()).font(.title3.weight(.semibold))) \(Text("kcal").font(.footnote).foregroundStyle(.secondary))")
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SummaryCard: View {
    var text: String
    @Environment(AppRouter.self) private var router

    var body: some View {
        Button {
            router.tab = OnDeviceModel.isOffered ? .coach : .trends
        } label: {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("SUMMARY", systemImage: "sparkles")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tint)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct MealRow: View {
    var meal: Meal
    var entries: [FoodEntry]
    var day: Date
    @Environment(AppRouter.self) private var router

    private var calories: Double { entries.reduce(0) { $0 + $1.nutrients.calories } }

    var body: some View {
        if entries.isEmpty {
            Button { router.addFood(to: meal) } label: { row }
                .buttonStyle(.plain)
                .accessibilityLabel("Add food to \(meal.name)")
        } else {
            NavigationLink { MealView(meal: meal, day: day) } label: { row }
                .buttonStyle(.plain)
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            SymbolTile(systemName: meal.symbol)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(meal.name)
                    Spacer()
                    if !entries.isEmpty {
                        Text("\(Int(calories.rounded())) kcal")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // An empty meal shows a plus (the whole row adds to it); a logged one opens.
            if entries.isEmpty {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .contentShape(.rect)
    }

    private var subtitle: String {
        guard let first = entries.first else { return "Not logged yet" }
        return "\(first.date.formatted(date: .omitted, time: .shortened)) · " + entries.map(\.name).joined(separator: ", ")
    }
}

/// Days in a row with something logged.
private struct StreakBadge: View {
    @Query private var recent: [FoodEntry]
    @AppStorage(SettingsKey.accent) private var accent: AccentOption = .orange

    init() {
        let start = Calendar.current.date(byAdding: .day, value: -120, to: .now) ?? .now
        _recent = Query(filter: #Predicate<FoodEntry> { $0.date >= start })
    }

    var body: some View {
        let streak = Summaries.streak(recent.map(\.record))
        // Its own capsule, so it widens with the number instead of squeezing into a circle.
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
            Text("\(streak)")
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(accent.color)
        .padding(.horizontal, 16)
        .frame(minWidth: 72, minHeight: 44)
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Logging streak")
        .accessibilityValue("\(streak) day\(streak == 1 ? "" : "s")")
    }
}

#Preview {
    NavigationStack { TodayView() }
        .previewEnvironment()
}
