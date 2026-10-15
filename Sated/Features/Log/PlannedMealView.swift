import SwiftData
import SwiftUI

/// A meal BigTable planned, with Sated's estimate of one serving, for Add Food.
struct PlannedPick: Identifiable {
    var meal: HearthMealPlan.Meal
    var estimate: MealEstimate

    var id: String { "\(meal.slot).\(meal.title)" }
}

/// "From BigTable: Sheet-Pan Fajitas · ≈ 540 kcal a serving", at the top of Add Food when
/// BigTable planned the selected meal. Tapping it picks servings before logging.
struct PlannedMealCard: View {
    var meal: HearthMealPlan.Meal
    var estimate: MealEstimate
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "fork.knife")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(BigTableMeals.color)
                    .frame(width: 44, height: 44)
                    .background(BigTableMeals.color.opacity(0.15), in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("From BigTable")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(meal.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 4)
        .accessibilityHint("Choose servings and log it")
    }

    /// "≈ 540 kcal a serving", or "Rough ≈ 540 kcal a serving" when few ingredients matched.
    private var detail: String {
        let calories = "≈ \(Int(estimate.perServing.calories.rounded())) kcal a serving"
        return estimate.isRough ? "Rough \(calories)" : calories
    }
}

/// Servings and meal for a planned meal, then Add. Logged as one entry named after the meal,
/// with the estimate per serving, like a restaurant estimate.
struct PlannedMealSheet: View {
    let pick: PlannedPick
    var onAdded: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var servings: Double = 1
    @State private var meal: Meal

    init(pick: PlannedPick, meal: Meal, onAdded: @escaping () -> Void) {
        self.pick = pick
        self.onAdded = onAdded
        _meal = State(initialValue: meal)
    }

    private var estimate: MealEstimate { pick.estimate }
    private var nutrients: Nutrients { estimate.perServing * servings }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $servings, in: 0.5...6, step: 0.5) {
                        LabeledContent("Servings") {
                            Text(servings.formatted(.number.precision(.fractionLength(0...2))))
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                                .monospacedDigit()
                        }
                    }
                    Picker("Meal", selection: $meal) {
                        ForEach(Meal.allCases) { Text($0.name).tag($0) }
                    }
                }
                Section {
                    NutritionSummary(nutrients: nutrients, approximate: true)
                } footer: {
                    Text(confidenceText)
                }
                ForEach(estimate.recipes) { recipe in
                    Section {
                        ForEach(recipe.ingredients.indices, id: \.self) { index in
                            IngredientMatchRow(item: recipe.ingredients[index])
                        }
                    } header: {
                        Text(recipe.title)
                    } footer: {
                        Text(servingsText(recipe))
                    }
                }
                if let url = pick.meal.link.flatMap({ URL(string: $0) }) {
                    Section {
                        Button("Open in BigTable", systemImage: "arrow.up.forward.app") { openURL(url) }
                    }
                }
            }
            .navigationTitle(pick.meal.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: add) {
                    Text("Add to \(meal.name) · ≈ \(Int(nutrients.calories.rounded())) kcal")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .animation(.snappy, value: servings)
        }
        .presentationDetents([.medium, .large])
    }

    /// How much to trust the numbers.
    private var confidenceText: String {
        let matched = "\(estimate.confident) of \(estimate.counted) ingredients"
        if estimate.isRough {
            return "Rough estimate: only \(matched) matched a food closely, so these numbers could be well off. Check them, or use Quick Add instead."
        }
        return "Estimated on your \(DeviceName.current) from BigTable's recipe: \(matched) matched USDA foods. Treat it as a close guess."
    }

    private func servingsText(_ recipe: MealEstimate.RecipePart) -> String {
        let count = recipe.servings.formatted(.number.precision(.fractionLength(0...1)))
        return recipe.servingsAssumed
            ? "BigTable didn't say how many this serves, so Sated assumed \(count) servings."
            : "Makes \(count) servings."
    }

    private func add() {
        let food = FoodItem(
            // The same meal logged again files under one Recent item.
            id: "bigtable.\(pick.meal.recipeIDs?.joined(separator: "+") ?? pick.meal.title.lowercased())",
            name: pick.meal.title,
            brand: "BigTable",
            serving: "1 serving",
            nutrients: estimate.perServing,
            source: .estimate
        )
        FoodLog.add(food, servings: servings, meal: meal, in: context)
        dismiss()
        onAdded()
    }
}

/// "1.5 lb chicken breast / Chicken, broiler or fryers, breast… ", or why it wasn't counted.
private struct IngredientMatchRow: View {
    var item: IngredientMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(amountText)
            Text(matchText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var amountText: String {
        let ingredient = item.ingredient
        let amount = ingredient.amount.map { $0.formatted(.number.precision(.fractionLength(0...2))) }
        return [amount, ingredient.unit, ingredient.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var matchText: String {
        switch item.quality {
        case .confident:
            return item.food?.name ?? ""
        case .rough:
            return "≈ \(item.food?.name ?? "") (rough match)"
        case .unmatched:
            return "No match, not counted"
        case .skipped:
            return "No amount, not counted"
        }
    }
}
