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
        #expect(bundled.foods.count > 50)
        #expect(bundled.food(id: "usda.large-egg")?.calories == 72)
    }

    @Test func spokenWeightsBecomeServings() {
        let chicken = database.food(id: "a")!
        let sixOunces = ParsedFood(food: "chicken breast", quantity: 6, unit: "oz")
        #expect(MealParser.servings(for: sixOunces, food: chicken) == 1)
        let twoEggs = ParsedFood(food: "egg", quantity: 2, unit: "egg")
        #expect(MealParser.servings(for: twoEggs, food: database.food(id: "c")!) == 2)
    }
}
