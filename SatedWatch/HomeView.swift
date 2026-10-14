import SwiftUI
import WatchKit

/// The Watch app's only screen: today's calories, Say It, and the usuals for this meal.
struct HomeView: View {
    @Environment(WatchStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [WatchRoute] = []
    @State private var meal = Meal.suggested()
    /// Refreshed on returning to the app, so totals start over after midnight.
    @State private var now = Date.now

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    SummaryCard(totals: store.totals(on: now), snapshot: store.snapshot, hasSnapshot: store.hasSnapshot, accent: store.accent)
                        .listRowBackground(Color.clear)
                }

                Section {
                    TextFieldLink(prompt: Text("Two eggs and toast")) {
                        Label("Say What You Ate", systemImage: "mic.fill")
                            .font(.headline)
                    } onSubmit: { text in
                        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !said.isEmpty else { return }
                        path.append(.say(said))
                    }
                    .foregroundStyle(store.accent)
                }

                Section {
                    let usuals = store.usuals(for: meal)
                    if usuals.isEmpty {
                        Text(store.hasSnapshot
                             ? "Foods you log often at \(meal.name.lowercased()) show up here."
                             : "Open Sated on your iPhone to bring your usuals over.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(usuals) { food in
                            NavigationLink(value: WatchRoute.confirm(foods: [food], meal: meal)) {
                                FoodRow(food: food)
                            }
                        }
                    }
                    Picker("Meal", selection: $meal) {
                        ForEach(Meal.allCases) { meal in
                            Label(meal.name, systemImage: meal.symbol).tag(meal)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Label("Usual for \(meal.name)", systemImage: meal.symbol)
                }
            }
            .navigationTitle("Sated")
            .navigationDestination(for: WatchRoute.self) { route in
                switch route {
                case .confirm(let foods, let meal):
                    ConfirmView(foods: foods, meal: meal, onLogged: finish)
                case .say(let text):
                    SayItView(text: text, onLogged: finish)
                }
            }
        }
        .tint(store.accent)
        .onChange(of: scenePhase) { _, phase in
            // Coming back later in the day: show the meal it is now.
            guard phase == .active else { return }
            now = .now
            if path.isEmpty { meal = .suggested() }
        }
    }

    private func finish() {
        WKInterfaceDevice.current().play(.success)
        now = .now
        path.removeAll()
    }
}

/// Calories left as a ring, with protein underneath.
struct SummaryCard: View {
    var totals: WatchTotals
    var snapshot: WatchSnapshot
    var hasSnapshot: Bool
    var accent: Color

    private var left: Double { snapshot.goalCalories - totals.calories }

    var body: some View {
        HStack(spacing: 12) {
            Gauge(value: min(totals.calories / max(snapshot.goalCalories, 1), 1)) {
                Image(systemName: "flame.fill")
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(left < 0 ? .red : accent)

            VStack(alignment: .leading, spacing: 2) {
                if hasSnapshot {
                    Text(Int(abs(left).rounded()).formatted())
                        .font(.title2.bold())
                        .contentTransition(.numericText())
                    Text(left < 0 ? "kcal over" : "kcal left")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("\(Int(totals.protein.rounded())) of \(Int(snapshot.goalProtein.rounded())) g protein")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Open Sated on your iPhone to get started.")
                        .font(.footnote)
                }
            }
        }
        .animation(.snappy, value: totals)
        .accessibilityElement(children: .combine)
    }
}

/// "Greek yogurt / 1 cup · 150 kcal"
struct FoodRow: View {
    var food: WatchFood

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(food.name)
                .font(.headline)
                .lineLimit(2)
            Text("\(food.amountText) · \(Int(food.totalCalories.rounded())) kcal")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let place = food.placeName {
                Text(place)
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
        }
    }
}
