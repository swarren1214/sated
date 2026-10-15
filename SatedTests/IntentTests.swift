import Foundation
import Testing
@testable import Sated

struct IntentTests {
    func status(calories: Double, protein: Double) -> TodayStatus {
        TodayStatus(calories: calories, protein: protein, goalCalories: 2400, goalProtein: 180)
    }

    func food(_ name: String, servings: Double = 1, calories: Double) -> WatchFood {
        WatchFood(
            id: name, foodID: nil, name: name, serving: "1 serving", servings: servings,
            calories: calories, protein: 0, carbs: 0, fat: 0, fiber: 0, source: "usda"
        )
    }

    @Test func spokenUnderGoal() {
        #expect(status(calories: 1160, protein: 118).spoken
            == "You have 1,240 calories left today, and 62 grams of protein to go.")
    }

    @Test func spokenOverGoal() {
        #expect(status(calories: 2550, protein: 120).spoken
            == "You're 150 calories over today, and 60 grams of protein to go.")
    }

    @Test func spokenProteinMet() {
        #expect(status(calories: 2000, protein: 190).spoken
            == "You have 400 calories left today, and you've hit your protein goal.")
    }

    @Test func spokenSingular() {
        #expect(status(calories: 2399, protein: 179).spoken
            == "You have 1 calorie left today, and 1 gram of protein to go.")
    }

    @Test func confirmationListsFoodsAndTotal() {
        let foods = [food("Large egg", servings: 2, calories: 72), food("Sourdough bread", calories: 146)]
        let text = SpokenFoods.confirmation(foods, meal: .breakfast)
        #expect(text.hasPrefix("Log Large egg (2)"))
        #expect(text.contains("Sourdough bread"))
        #expect(text.hasSuffix("290 calories, to breakfast?"))
    }

    @Test func confirmationMentionsWhatWasntFound() {
        let text = SpokenFoods.confirmation([food("Coffee", calories: 2)], meal: .snack, unmatched: ["mystery cake"])
        #expect(text.hasSuffix("I couldn't find mystery cake."))
    }
}
