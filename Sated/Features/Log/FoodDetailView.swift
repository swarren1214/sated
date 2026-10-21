import SwiftData
import SwiftUI

/// A food's nutrition, with the measure ("1 cup", "1 slice", "100 g"), amount and meal to
/// choose before adding it.
struct FoodDetailView: View {
    let food: FoodItem
    var onAdded: () -> Void = {}
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var servings: Double = 1
    @State private var meal: Meal
    /// The measure picked; nil is the food's own serving.
    @State private var measure: FoodItem.Portion?

    init(food: FoodItem, meal: Meal, onAdded: @escaping () -> Void = {}) {
        self.food = food
        self.onAdded = onAdded
        _meal = State(initialValue: meal)
    }

    /// The food as it will be logged: measured the way the person chose.
    private var chosen: FoodItem { measure.map(food.measured(by:)) ?? food }
    private var nutrients: Nutrients { chosen.nutrients * servings }
    private var goals: Goals { Goals.load() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(food.name)
                        .font(.title.bold())
                    Text([food.brand, sourceText].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    if food.measures.count > 1 {
                        Picker("Serving", selection: $measure) {
                            ForEach(food.measures) { portion in
                                Text(portion.text).tag(portion.label == food.serving ? nil : Optional(portion))
                            }
                        }
                        .tint(.primary)
                        .padding(.vertical, 6)
                    } else {
                        LabeledContent("Serving", value: food.servingText)
                            .padding(.vertical, 14)
                    }
                    Divider()
                    Stepper(value: $servings, in: 0.25...20, step: 0.25) {
                        LabeledContent("Servings") {
                            Text(servings.formatted(.number.precision(.fractionLength(0...2))))
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.vertical, 8)
                    Divider()
                    Picker("Meal", selection: $meal) {
                        ForEach(Meal.allCases) { Text($0.name).tag($0) }
                    }
                    .tint(.primary)
                    .padding(.vertical, 6)
                }
                .padding(.horizontal, 16)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))

                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(Text(Int(nutrients.calories.rounded()).formatted()).font(.largeTitle.bold())) \(Text("kcal").foregroundStyle(.secondary))")
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Spacer()
                            Text("\(Int((nutrients.calories / max(goals.calories, 1) * 100).rounded()))% of daily goal")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Grid(horizontalSpacing: 12) {
                            GridRow {
                                ForEach(Macro.allCases) { macro in
                                    MacroColumn(macro: macro, value: macro.value(in: nutrients), goal: macro.goal(in: goals))
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 100)
            .animation(.snappy, value: servings)
            .animation(.snappy, value: measure)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                FoodLog.add(chosen, servings: servings, meal: meal, in: context)
                dismiss()
                onAdded()
            } label: {
                Text("Add to \(meal.name) · \(Int(nutrients.calories.rounded())) kcal")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var sourceText: String {
        switch food.source {
        case .usda: "USDA FoodData Central"
        case .openFoodFacts: "Open Food Facts"
        case .label: "From the label"
        case .voice: "From voice"
        case .quickAdd: "Quick Add"
        case .restaurant: "Restaurant menu"
        case .estimate: "Estimate"
        }
    }
}

private struct MacroColumn: View {
    var macro: Macro
    var value: Double
    var goal: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(macro.name).font(.footnote).foregroundStyle(.secondary)
            Text("\(Grams.text(value)) \(Text("g").font(.footnote).foregroundStyle(.secondary))")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(macro.color).frame(width: proxy.size.width * min(goal > 0 ? value / goal : 0, 1))
                }
            }
            .frame(height: 4)
            Text("\(Int((goal > 0 ? value / goal * 100 : 0).rounded()))% of goal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        FoodDetailView(food: FoodDatabase.shared.foods.first!, meal: .dinner)
    }
    .previewEnvironment()
}
