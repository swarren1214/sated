import SwiftUI

/// Review before logging: the foods, the total, which meal. Double Tap logs.
struct ConfirmView: View {
    @Environment(WatchStore.self) private var store
    @State private var foods: [WatchFood]
    @State private var meal: Meal
    private let unmatched: [String]
    /// Foods that are the closest match rather than the item named.
    private let approximate: Set<String>
    /// 1 when they said it was yesterday.
    private let daysAgo: Int
    private let onLogged: () -> Void

    init(foods: [WatchFood], meal: Meal, unmatched: [String] = [], approximate: Set<String> = [], daysAgo: Int = 0, onLogged: @escaping () -> Void) {
        _foods = State(initialValue: foods)
        _meal = State(initialValue: meal)
        self.unmatched = unmatched
        self.approximate = approximate
        self.daysAgo = daysAgo
        self.onLogged = onLogged
    }

    private var calories: Double { foods.reduce(0) { $0 + $1.totalCalories } }
    private var protein: Double { foods.reduce(0) { $0 + $1.totalProtein } }

    /// Now, or this time yesterday.
    private var date: Date {
        guard daysAgo > 0 else { return .now }
        return Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
    }

    private func note(for food: WatchFood) -> String? {
        approximate.contains(food.id) ? "Closest match" : nil
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(calories.rounded()).formatted()) kcal")
                        .font(.title3.bold())
                        .contentTransition(.numericText())
                    Text("\(Int(protein.rounded())) g protein")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if daysAgo == 1 {
                        Text("Yesterday")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .animation(.snappy, value: calories)
                .listRowBackground(Color.clear)
            }

            if foods.count == 1 {
                Section {
                    FoodRow(food: foods[0], note: note(for: foods[0]))
                    Stepper(value: $foods[0].servings, in: 0.25...20, step: 0.25) {
                        Text("\(foods[0].servings.formatted(.number.precision(.fractionLength(0...2)))) ×")
                    }
                }
            } else {
                Section {
                    ForEach($foods) { $food in
                        NavigationLink {
                            AmountView(food: $food)
                        } label: {
                            FoodRow(food: food, note: note(for: food))
                        }
                    }
                    .onDelete { foods.remove(atOffsets: $0) }
                } footer: {
                    Text("Tap one to change how much. Swipe left to remove one.")
                }
            }

            if !unmatched.isEmpty {
                Section("Not Found") {
                    ForEach(unmatched, id: \.self) { spoken in
                        Text(spoken)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Picker("Meal", selection: $meal) {
                    ForEach(Meal.allCases) { meal in
                        Label(meal.name, systemImage: meal.symbol).tag(meal)
                    }
                }
                .pickerStyle(.navigationLink)

                Button {
                    store.log(foods, meal: meal, date: date)
                    onLogged()
                } label: {
                    Label("Log", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .handGestureShortcut(.primaryAction)
                .disabled(foods.isEmpty)
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(meal.name)
    }
}

/// One food's amount, from the review list.
private struct AmountView: View {
    @Binding var food: WatchFood

    var body: some View {
        List {
            FoodRow(food: food)
            Stepper(value: $food.servings, in: 0.25...20, step: 0.25) {
                Text("\(food.servings.formatted(.number.precision(.fractionLength(0...2)))) ×")
            }
        }
        .navigationTitle("Amount")
    }
}
