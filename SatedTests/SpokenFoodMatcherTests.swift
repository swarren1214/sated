import Foundation
import Testing
@testable import Sated

/// Matching spoken foods to a restaurant's menu. The menu below is made up for the tests;
/// its numbers aren't any chain's real nutrition.
@MainActor
struct SpokenFoodMatcherTests {
    func serving(_ id: String, _ description: String, calories: Double, isDefault: Bool = false) -> MenuServing {
        MenuServing(id: id, description: description, grams: nil, calories: calories, protein: 10, carbs: 10, fat: 5, fiber: 1, isDefault: isDefault)
    }

    var menu: RestaurantMenu {
        RestaurantMenu(
            query: "Chick-fil-A",
            restaurant: "Chick-fil-A",
            hasMenu: true,
            items: [
                MenuItem(id: "1", name: "Grilled Chicken Club Sandwich", category: "Entrees", servings: [serving("1a", "1 sandwich", calories: 500, isDefault: true)]),
                MenuItem(id: "2", name: "Grilled Chicken Sandwich", category: "Entrees", servings: [serving("2a", "1 sandwich", calories: 400, isDefault: true)]),
                MenuItem(id: "3", name: "Waffle Potato Fries", category: "Sides", servings: [
                    serving("3s", "1 small", calories: 300),
                    serving("3m", "1 medium", calories: 400, isDefault: true),
                    serving("3l", "1 large", calories: 500),
                ]),
                // The server strips the chain's name, so "Chick-fil-A Sauce" arrives as "Sauce".
                MenuItem(id: "4", name: "Sauce", category: "Sauces", servings: [serving("4a", "1 packet", calories: 140, isDefault: true)]),
                MenuItem(id: "5", name: "Honey Roasted BBQ Sauce", category: "Sauces", servings: [serving("5a", "1 packet", calories: 60, isDefault: true)]),
                MenuItem(id: "6", name: "Nuggets", category: "Entrees", servings: [
                    serving("6a", "8 count", calories: 250, isDefault: true),
                    serving("6b", "12 count", calories: 380),
                ]),
            ],
            fetchedAt: "2026-10-23T00:00:00Z",
            stale: false,
            attribution: "Powered by fatsecret"
        )
    }

    let database = FoodDatabase(foods: [
        FoodItem(id: "u1", name: "Chicken sandwich", serving: "1 sandwich", nutrients: Nutrients(calories: 450, protein: 25, carbs: 40, fat: 20, fiber: 2), source: .usda),
        FoodItem(id: "u2", name: "Banana", serving: "1 medium", nutrients: Nutrients(calories: 105, protein: 1, carbs: 27, fat: 0, fiber: 3), source: .usda),
    ])

    func food(_ name: String, restaurant: String = "", generic: String = "", quantity: Double = 1, unit: String = "serving", size: String = "") -> ParsedFood {
        ParsedFood(restaurant: restaurant, name: name, food: generic.isEmpty ? name : generic, quantity: quantity, unit: unit, size: size)
    }

    var place: SpokenFoodMatcher.Place {
        SpokenFoodMatcher.Place(ref: PlaceRef(id: "Chick-fil-A", name: "Chick-fil-A"), menu: menu)
    }

    func match(_ item: ParsedFood, place: SpokenFoodMatcher.Place?) -> VoiceItem {
        SpokenFoodMatcher.match(item, place: place, inherited: false, history: [], database: database)
    }

    @Test func picksTheExactItemOverOneWithMoreWords() {
        let item = match(food("grilled chicken sandwich", restaurant: "Chick-fil-A", generic: "chicken sandwich"), place: place)
        #expect(item.food?.name == "Grilled Chicken Sandwich")
        #expect(item.food?.brand == "Chick-fil-A")
        #expect(item.food?.source == .restaurant)
        #expect(item.place?.name == "Chick-fil-A")
        #expect(!item.isApproximate)
    }

    @Test func regularIsTheMedium() {
        let item = match(food("waffle fries", restaurant: "Chick-fil-A", size: "regular"), place: place)
        #expect(item.food?.name == "Waffle Potato Fries")
        #expect(item.food?.calories == 400)
        #expect(item.servings == 1)
    }

    @Test func largeIsTheLarge() {
        let item = match(food("waffle fries", restaurant: "Chick-fil-A", size: "large"), place: place)
        #expect(item.food?.calories == 500)
    }

    @Test func theChainsOwnSauce() {
        let item = match(food("Chick-fil-A sauce", restaurant: "Chick-fil-A", unit: "packet"), place: place)
        #expect(item.food?.name == "Sauce")
    }

    @Test func threePacketsIsThreeServings() {
        let item = match(food("honey roasted BBQ sauce", restaurant: "Chick-fil-A", quantity: 3, unit: "packet"), place: place)
        #expect(item.food?.name == "Honey Roasted BBQ Sauce")
        #expect(item.servings == 3)
    }

    @Test func anEightCountIsOneServing() {
        let eight = match(food("nuggets", restaurant: "Chick-fil-A", quantity: 8, unit: "nugget"), place: place)
        #expect(eight.food?.calories == 250)
        #expect(eight.servings == 1)
        let twelve = match(food("nuggets", restaurant: "Chick-fil-A", quantity: 12, unit: "piece"), place: place)
        #expect(twelve.food?.calories == 380)
        #expect(twelve.servings == 1)
    }

    @Test func offTheMenuFallsBackAndSaysSo() {
        let item = match(food("spicy deluxe", restaurant: "Chick-fil-A", generic: "chicken sandwich"), place: place)
        #expect(item.food?.name == "Chicken sandwich")
        #expect(item.isApproximate)
    }

    @Test func noPlaceUsesTheDatabase() {
        let item = match(food("banana"), place: nil)
        #expect(item.food?.name == "Banana")
        #expect(!item.isApproximate)
    }

    @Test func thePlaceCarriesToTheFoodsAfterIt() async {
        let menu = self.menu
        let items = await SpokenFoodMatcher.match(
            [
                food("grilled chicken sandwich", restaurant: "Chick fil A"),
                food("waffle fries", size: "regular"),
                food("Chick-fil-A sauce", quantity: 1, unit: "packet"),
                food("honey roasted barbecue sauce", quantity: 3, unit: "packet"),
            ],
            database: database,
            context: nil,
            menus: SpokenFoodMatcher.MenuSource { _ in menu }
        )
        #expect(items.map { $0.food?.name } == ["Grilled Chicken Sandwich", "Waffle Potato Fries", "Sauce", "Honey Roasted BBQ Sauce"])
        #expect(items.map(\.servings) == [1, 1, 1, 3])
        #expect(items.allSatisfy { $0.place?.name == "Chick-fil-A" })
        #expect(items.allSatisfy { !$0.isApproximate })
    }

    @Test func aSlowMenuDoesntHoldUpTheAnswer() async {
        let start = ContinuousClock.now
        let result: Int? = await SpokenFoodMatcher.first(within: .milliseconds(100)) {
            try? await Task.sleep(for: .seconds(5))
            return 1
        }
        #expect(result == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func searchWordsDropTheBrand() {
        #expect(SpokenFoodMatcher.searchWords("Chick-fil-A sauce", removing: ["Chick-fil-A"]) == ["sauce"])
        #expect(SpokenFoodMatcher.searchWords("a regular waffle fries", removing: []) == ["waffle", "fries"])
        #expect(SpokenFoodMatcher.searchWords("BBQ sauce", removing: []) == ["barbecue", "sauce"])
        #expect(SpokenFoodMatcher.squashed("Chick fil A") == SpokenFoodMatcher.squashed("Chick-fil-A"))
    }
}
