import Foundation
import Testing
@testable import Sated

/// A bundled-style food with its measures.
nonisolated private func usdaFood(_ id: String, _ name: String, serving: String, grams: Double, _ nutrients: Nutrients, portions: [FoodItem.Portion]? = nil, rank: Int? = nil) -> FoodItem {
    var item = FoodItem(id: id, name: name, serving: serving, grams: grams, nutrients: nutrients, source: .usda)
    item.portions = portions
    item.rank = rank
    return item
}

/// Estimating BigTable's planned meals from their recipes' ingredients.
struct RecipeEstimatorTests {
    let database = FoodDatabase(foods: [
        usdaFood("onion", "Onions, raw", serving: "1 slice", grams: 15, Nutrients(calories: 6, carbs: 1.4, fiber: 0.3),
             portions: [.init(label: "1 cup, chopped", grams: 160), .init(label: "1 whole", grams: 148)]),
        usdaFood("dip", "Onion dip, regular", serving: "1 tbsp", grams: 15, Nutrients(calories: 52, protein: 0.8, carbs: 1.6, fat: 4.6)),
        usdaFood("cheddar", "Cheese, Cheddar", serving: "1 slice", grams: 21, Nutrients(calories: 86, protein: 4.8, carbs: 0.5, fat: 7.1),
             portions: [.init(label: "1 cup, shredded", grams: 113)]),
        usdaFood("oil", "Olive oil", serving: "1 tbsp", grams: 14, Nutrients(calories: 126, fat: 14)),
        usdaFood("egg", "Egg, whole, raw", serving: "1 egg", grams: 50, Nutrients(calories: 72, protein: 6.3, carbs: 0.4, fat: 4.8)),
        usdaFood("creamed", "Egg, creamed", serving: "1 egg", grams: 145, Nutrients(calories: 215, protein: 9, carbs: 6, fat: 17)),
        usdaFood("chicken", "Chicken, broiler or fryers, breast, skinless, boneless, meat only, raw", serving: "4 oz", grams: 113,
             Nutrients(calories: 136, protein: 25.6, fat: 3)),
        usdaFood("salt", "Salt, table", serving: "1 tsp", grams: 6, Nutrients(), rank: 30),
    ])

    private func ingredient(_ name: String, _ amount: Double?, _ unit: String?) -> HearthMealPlan.Ingredient {
        HearthMealPlan.Ingredient(name: name, amount: amount, unit: unit)
    }

    @Test func cleansRecipeNamesIntoUSDAWords() {
        #expect(RecipeEstimator.queryWords(for: "Yellow onion, diced") == ["onions", "raw"])
        #expect(RecipeEstimator.queryWords(for: "shredded cheddar cheese (divided)") == ["cheese", "cheddar"])
        #expect(RecipeEstimator.queryWords(for: "Red bell pepper") == ["red", "peppers", "sweet"])
        #expect(RecipeEstimator.queryWords(for: "ground cumin") == ["cumin"])
        #expect(RecipeEstimator.queryWords(for: "ground beef") == ["beef", "ground"])
    }

    @Test func prefersIngredientsOverDishes() {
        #expect(RecipeEstimator.bestFood(for: "onion", in: database)?.food.id == "onion")
        #expect(RecipeEstimator.bestFood(for: "eggs", in: database)?.food.id == "egg")
        #expect(RecipeEstimator.bestFood(for: "boneless skinless chicken breasts", in: database)?.food.id == "chicken")
        #expect(RecipeEstimator.bestFood(for: "dragonfruit", in: database) == nil)
    }

    @Test func singularsAndPluralsMatch() {
        #expect(RecipeEstimator.sameWord("onion", "onions"))
        #expect(RecipeEstimator.sameWord("tomatoes", "tomato"))
        #expect(RecipeEstimator.sameWord("berries", "berry"))
        #expect(!RecipeEstimator.sameWord("fries", "fried"))
        #expect(RecipeEstimator.searchStem("potatoes") == "potato")
    }

    @Test func normalizesBigTablesUnits() {
        #expect(RecipeEstimator.normalizedUnit("Tablespoons") == "tbsp")
        #expect(RecipeEstimator.normalizedUnit("cloves") == "clove")
        #expect(RecipeEstimator.normalizedUnit("lbs") == "lb")
        #expect(RecipeEstimator.normalizedUnit("fl oz") == "fl oz")
        #expect(RecipeEstimator.normalizedUnit(nil) == "whole")
    }

    @Test func weighsWithTheFoodsOwnMeasures() throws {
        let cheddar = try #require(database.food(id: "cheddar"))
        let cup = try #require(RecipeEstimator.grams(amount: 1, unit: "cup", of: cheddar))
        #expect(abs(cup.grams - 113) < 0.01)
        #expect(cup.exact)

        let oil = try #require(database.food(id: "oil"))
        let twoTablespoons = try #require(RecipeEstimator.grams(amount: 2, unit: "tbsp", of: oil))
        #expect(abs(twoTablespoons.grams - 28) < 0.01)

        let chicken = try #require(database.food(id: "chicken"))
        let eightOunces = try #require(RecipeEstimator.grams(amount: 8, unit: "oz", of: chicken))
        #expect(abs(eightOunces.grams - 226.8) < 0.01)

        let egg = try #require(database.food(id: "egg"))
        let twoEggs = try #require(RecipeEstimator.grams(amount: 2, unit: nil, of: egg))
        #expect(twoEggs.grams == 100)
        #expect(twoEggs.exact)

        let onion = try #require(database.food(id: "onion"))
        #expect(RecipeEstimator.grams(amount: 1, unit: "whole", of: onion)?.grams == 148)
    }

    @Test func guessesWhenTheFoodHasNoMeasure() throws {
        // No volume measure for eggs here: a cup weighs about as much as a cup of water.
        let egg = try #require(database.food(id: "egg"))
        let cup = try #require(RecipeEstimator.grams(amount: 1, unit: "cup", of: egg))
        #expect(abs(cup.grams - 236.6) < 0.01)
        #expect(!cup.exact)
        // No amount: one, roughly.
        #expect(RecipeEstimator.grams(amount: nil, unit: "tbsp", of: database.food(id: "oil")!)?.exact == false)
    }

    @Test func estimatesOneServing() {
        let recipe = HearthMealPlan.Recipe(id: "r1", title: "Chicken and Onions", servings: 4, ingredients: [
            ingredient("chicken breast", 1, "lb"),
            ingredient("olive oil", 2, "tbsp"),
            ingredient("yellow onion", 1, "whole"),
            ingredient("salt and pepper", nil, nil),
        ])
        let estimate = RecipeEstimator.estimate([recipe], in: database)
        // 545.9 kcal of chicken + 252 of oil + 59.2 of onion, over four servings.
        #expect(abs(estimate.perServing.calories - 214.3) < 0.5)
        #expect(estimate.counted == 3)
        #expect(estimate.confident == 3)
        #expect(!estimate.isRough)
        #expect(estimate.ingredients.last?.quality == .skipped)
    }

    @Test func missingServingsMeansFour() {
        var recipe = HearthMealPlan.Recipe(id: "r1", title: "Oil", servings: nil, ingredients: [ingredient("olive oil", 4, "tbsp")])
        let unsaid = RecipeEstimator.estimate([recipe], in: database)
        #expect(unsaid.recipes.first?.servingsAssumed == true)
        #expect(unsaid.recipes.first?.servings == 4)
        recipe.servings = 4
        #expect(unsaid.perServing == RecipeEstimator.estimate([recipe], in: database).perServing)
        #expect(abs(unsaid.perServing.calories - 126) < 0.01)
    }

    @Test func sumsOneServingOfEachRecipe() {
        let main = HearthMealPlan.Recipe(id: "a", title: "Eggs", servings: 2, ingredients: [ingredient("eggs", 4, nil)])
        let side = HearthMealPlan.Recipe(id: "b", title: "Cheese", servings: 1, ingredients: [ingredient("cheddar", 1, "cup")])
        let estimate = RecipeEstimator.estimate([main, side], in: database)
        // Two eggs (144) and a cup of cheddar (113 g, 462.7 kcal).
        #expect(abs(estimate.perServing.calories - 606.7) < 0.5)
    }

    @Test func flagsAMostlyUnmatchedRecipeAsRough() {
        let recipe = HearthMealPlan.Recipe(id: "r", title: "Mystery", servings: 4, ingredients: [
            ingredient("dragonfruit glaze", 1, "cup"),
            ingredient("unicorn sprinkles", 2, "tbsp"),
            ingredient("olive oil", 1, "tbsp"),
        ])
        let estimate = RecipeEstimator.estimate([recipe], in: database)
        #expect(estimate.counted == 3)
        #expect(estimate.confident == 1)
        #expect(estimate.isRough)
        #expect(abs(estimate.perServing.calories - 31.5) < 0.01)
    }

    @Test func mapsSatedMealsToBigTableSlots() {
        #expect(BigTableMeals.slot(for: .breakfast) == "breakfast")
        #expect(BigTableMeals.slot(for: .lunch) == "lunch")
        #expect(BigTableMeals.slot(for: .dinner) == "dinner")
        #expect(BigTableMeals.slot(for: .snack) == nil)
    }
}
