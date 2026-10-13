import Foundation
import Testing
@testable import Sated

struct OpenFoodFactsTests {
    @Test func usesPerServingValues() throws {
        let json = """
        {"status":1,"product":{"product_name":"Chocolate Chip Protein Bar","brands":"Acme, Acme Foods","serving_size":"1 bar (60 g)","serving_quantity":"60",
        "nutriments":{"energy-kcal_serving":190,"proteins_serving":21,"carbohydrates_serving":22,"fat_serving":8,"fiber_serving":14,"energy-kcal_100g":317}}}
        """
        let food = try OpenFoodFacts.parse(Data(json.utf8), barcode: "081234567892")
        #expect(food.name == "Chocolate Chip Protein Bar")
        #expect(food.brand == "Acme")
        #expect(food.serving == "1 bar (60 g)")
        #expect(food.calories == 190)
        #expect(food.fiber == 14)
        #expect(food.id == "off.081234567892")
    }

    @Test func scalesPer100gToTheServing() throws {
        let json = """
        {"status":1,"product":{"product_name":"Granola","serving_size":"40 g","serving_quantity":40,
        "nutriments":{"energy-kcal_100g":450,"proteins_100g":10,"carbohydrates_100g":65,"fat_100g":17.5,"fiber_100g":7.5}}}
        """
        let food = try OpenFoodFacts.parse(Data(json.utf8), barcode: "1")
        #expect(food.calories == 180)
        #expect(food.protein == 4)
        #expect(food.fat == 7)
    }

    @Test func fallsBackTo100g() throws {
        let json = """
        {"status":1,"product":{"product_name":"Rice","nutriments":{"energy-kcal_100g":"130","proteins_100g":"2,7"}}}
        """
        let food = try OpenFoodFacts.parse(Data(json.utf8), barcode: "2")
        #expect(food.serving == "100 g")
        #expect(food.calories == 130)
        #expect(food.protein == 2.7)
    }

    @Test func missingProductThrows() {
        let json = #"{"status":0,"status_verbose":"product not found"}"#
        #expect(throws: OpenFoodFacts.LookupError.self) {
            try OpenFoodFacts.parse(Data(json.utf8), barcode: "3")
        }
    }

    @Test func productWithoutCaloriesThrows() {
        let json = #"{"status":1,"product":{"product_name":"Mystery","nutriments":{}}}"#
        #expect(throws: OpenFoodFacts.LookupError.self) {
            try OpenFoodFacts.parse(Data(json.utf8), barcode: "4")
        }
    }
}

struct FoodDatabaseTests {
    let database = FoodDatabase(foods: [
        FoodItem(id: "a", name: "Chicken breast, grilled", serving: "6 oz", grams: 170, nutrients: Nutrients(calories: 281, protein: 52.7, fat: 6.1), source: .usda),
        FoodItem(id: "b", name: "Chickpeas, cooked", serving: "1/2 cup", grams: 82, nutrients: Nutrients(calories: 135, protein: 7.3, carbs: 22.5, fat: 2.1, fiber: 6.2), source: .usda),
        FoodItem(id: "c", name: "Large egg", serving: "1 egg", grams: 50, nutrients: Nutrients(calories: 72, protein: 6.3, fat: 4.8), source: .usda),
    ])

    @Test func searchMatchesEveryWord() {
        #expect(database.search("chick breast").map(\.id) == ["a"])
        #expect(Set(database.search("chick").map(\.id)) == ["a", "b"])
        #expect(database.search("").isEmpty)
    }

    @Test func searchIgnoresCaseAndAccents() {
        #expect(database.search("EGG").first?.id == "c")
    }

    @Test func bundledFoodsLoad() {
        // Tests run inside the app, so the main bundle is Sated's.
        let bundled = FoodDatabase(bundle: .main)
        #expect(bundled.foods.count > 5_000)
        #expect(!bundled.search("banana").isEmpty)
        #expect(!bundled.search("pizza pepperoni").isEmpty)
        #expect(bundled.foods.allSatisfy { $0.calories >= 0 && ($0.grams ?? 1) > 0 })
    }

    @Test func mainWordOutranksPassingMention() {
        let database = FoodDatabase(foods: [
            FoodItem(id: "bread", name: "Bread, banana", serving: "1 slice", grams: 60, nutrients: Nutrients(calories: 196), source: .usda),
            FoodItem(id: "banana", name: "Banana, raw", serving: "1 medium", grams: 118, nutrients: Nutrients(calories: 105), source: .usda),
        ])
        #expect(database.search("banana").first?.id == "banana")
    }

    @Test func synonymsFindUSDANames() {
        let database = FoodDatabase(foods: [
            FoodItem(id: "fries", name: "Potato, french fries, from frozen, baked", serving: "1 cup", grams: 50, nutrients: Nutrients(calories: 150), source: .usda),
        ])
        #expect(database.search("fries").first?.id == "fries")
    }

    @Test func measuresRescaleByWeight() {
        var rice = FoodItem(id: "r", name: "Rice, white, cooked", serving: "1 cup", grams: 158, nutrients: Nutrients(calories: 205, protein: 4.3, carbs: 44.5, fat: 0.4, fiber: 0.6), source: .usda)
        rice.portions = [.init(label: "1/2 cup", grams: 79)]
        #expect(rice.measures.map(\.label) == ["1 cup", "1/2 cup", "1 oz", "100 g"])
        let half = rice.measured(by: rice.measures[1])
        #expect(half.serving == "1/2 cup")
        #expect(abs(half.calories - 102.5) < 0.01)
        #expect(rice.measured(by: rice.measures[0]) == rice)
    }

    @Test func spokenWeightsBecomeServings() {
        let chicken = database.food(id: "a")!
        let sixOunces = ParsedFood(food: "chicken breast", quantity: 6, unit: "oz")
        #expect(MealParser.servings(for: sixOunces, food: chicken) == 1)
        let twoEggs = ParsedFood(food: "egg", quantity: 2, unit: "egg")
        #expect(MealParser.servings(for: twoEggs, food: database.food(id: "c")!) == 2)
    }

    @Test func spokenMeasuresUseTheFoodsPortions() {
        var pizza = FoodItem(id: "p", name: "Pizza, cheese", serving: "1 piece, medium pizza", grams: 100, nutrients: Nutrients(calories: 270), source: .usda)
        pizza.portions = [.init(label: "1 personal size pizza", grams: 240)]
        #expect(MealParser.servings(for: ParsedFood(food: "pizza", quantity: 3, unit: "slices"), food: pizza) == 3)
        var rice = FoodItem(id: "r", name: "Rice, white, cooked", serving: "1/2 cup", grams: 79, nutrients: Nutrients(calories: 102), source: .usda)
        rice.portions = [.init(label: "1 cup, cooked", grams: 158)]
        #expect(MealParser.servings(for: ParsedFood(food: "rice", quantity: 2, unit: "cup"), food: rice) == 4)
    }
}
