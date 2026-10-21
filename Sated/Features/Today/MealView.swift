import SwiftData
import SwiftUI

/// One meal's entries: change servings, move to another meal, or delete.
struct MealView: View {
    let meal: Meal
    let day: Date
    @Query private var entries: [FoodEntry]
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @State private var editing: FoodEntry?

    init(meal: Meal, day: Date) {
        self.meal = meal
        self.day = day
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        let raw = meal.rawValue
        _entries = Query(filter: #Predicate<FoodEntry> { $0.date >= day && $0.date < end && $0.mealRaw == raw }, sort: \.date)
    }

    private var totals: Nutrients { entries.reduce(.zero) { $0 + $1.nutrients } }

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    Button { editing = entry } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).foregroundStyle(.primary)
                                Text(entry.amountText).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(Int(entry.nutrients.calories.rounded())) kcal").monospacedDigit()
                                Text("\(Grams.text(entry.nutrients.protein)) g protein")
                                    .font(.footnote)
                                    .foregroundStyle(Macro.protein.color)
                                    .monospacedDigit()
                            }
                        }
                        .foregroundStyle(.primary)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    // Icon only: the trash can says Delete on its own.
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            FoodLog.delete(entry, in: context)
                        } label: {
                            Image(systemName: "trash")
                                .accessibilityLabel("Delete")
                        }
                        // The app's accent tint would otherwise override the destructive red.
                        .tint(.red)
                    }
                }
            } footer: {
                Text(totals.summary)
            }
        }
        .refreshable { await CloudRefresh.refresh() }
        .navigationTitle(meal.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Food", systemImage: "plus") { router.addFood(to: meal) }
            }
        }
        .sheet(item: $editing) { entry in
            EntryEditor(entry: entry)
                .presentationDetents([.medium])
        }
    }
}

/// Change an entry's servings or meal.
struct EntryEditor: View {
    let entry: FoodEntry
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var servings: Double
    @State private var meal: Meal

    init(entry: FoodEntry) {
        self.entry = entry
        _servings = State(initialValue: entry.servings)
        _meal = State(initialValue: entry.meal)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $servings, in: 0.25...20, step: 0.25) {
                        LabeledContent("Servings", value: servings.formatted(.number.precision(.fractionLength(0...2))))
                    }
                    Picker("Meal", selection: $meal) {
                        ForEach(Meal.allCases) { Text($0.name).tag($0) }
                    }
                    .tint(.primary)
                } footer: {
                    Text("\(entry.servingLabel) per serving · \((entry.perServing * servings).summary)")
                }
                Section {
                    Button("Delete Entry", role: .destructive) {
                        // Close the sheet first so it never draws a deleted entry.
                        let entry = entry
                        let context = context
                        dismiss()
                        Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            FoodLog.delete(entry, in: context)
                        }
                    }
                }
            }
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton("Save") {
                        FoodLog.update(entry, servings: servings, meal: meal, in: context)
                        dismiss()
                    }
                }
            }
        }
    }
}
