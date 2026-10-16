import SwiftData
import SwiftUI

/// Log calories and macros by hand, for restaurant meals and anything not in the database.
struct QuickAddView: View {
    let meal: Meal
    var onAdded: () -> Void = {}
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var calories: Double?
    @State private var protein: Double?
    @State private var carbs: Double?
    @State private var fat: Double?
    @State private var fiber: Double?
    @State private var chosenMeal: Meal

    init(meal: Meal, onAdded: @escaping () -> Void = {}) {
        self.meal = meal
        self.onAdded = onAdded
        _chosenMeal = State(initialValue: meal)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Lunch out"))
                    Picker("Meal", selection: $chosenMeal) {
                        ForEach(Meal.allCases) { Text($0.name).tag($0) }
                    }
                }
                Section("Nutrition") {
                    field("Calories", unit: "kcal", value: $calories)
                    field("Protein", unit: "g", value: $protein)
                    field("Carbs", unit: "g", value: $carbs)
                    field("Fat", unit: "g", value: $fat)
                    field("Fiber", unit: "g", value: $fiber)
                }
            }
            .navigationTitle("Quick Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton("Add") { add() }
                        .disabled(calories == nil)
                }
            }
        }
    }

    private func field(_ title: String, unit: String, value: Binding<Double?>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("0", value: value, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let food = FoodItem(
            id: "quick.\(UUID().uuidString)",
            name: trimmed.isEmpty ? "Quick Add" : trimmed,
            serving: "1 serving",
            nutrients: Nutrients(calories: calories ?? 0, protein: protein ?? 0, carbs: carbs ?? 0, fat: fat ?? 0, fiber: fiber ?? 0),
            source: .quickAdd
        )
        FoodLog.add(food, servings: 1, meal: chosenMeal, in: context)
        dismiss()
        onAdded()
    }
}
