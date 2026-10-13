import Foundation
import Testing
@testable import Sated

struct RetryPolicyTests {
    @Test func retriesTransientFailuresTwice() {
        #expect(RetryPolicy.delay(before: 2, after: .unavailable, jitter: 1) == .milliseconds(600))
        #expect(RetryPolicy.delay(before: 3, after: .timedOut, jitter: 1) == .milliseconds(1200))
        #expect(RetryPolicy.delay(before: 4, after: .unavailable, jitter: 1) == nil)
    }

    @Test func neverRetriesWhatWontChange() {
        #expect(RetryPolicy.delay(before: 2, after: .offline) == nil)
        #expect(RetryPolicy.delay(before: 2, after: .notConfigured) == nil)
        #expect(RetryPolicy.delay(before: 2, after: .badResponse) == nil)
        #expect(RetryPolicy.delay(before: 2, after: .refused(code: "VALIDATION_ERROR", status: 400)) == nil)
    }

    @Test func honorsShortRetryAfterOnly() {
        #expect(RetryPolicy.delay(before: 2, after: .rateLimited(retryAfter: 3)) == .seconds(3))
        #expect(RetryPolicy.delay(before: 2, after: .rateLimited(retryAfter: 60)) == nil)
    }

    @Test func mapsTheAPIsErrors() {
        #expect(APIClient.error(status: 503, code: "PROVIDER_NOT_CONFIGURED", retryAfter: nil) == .notConfigured)
        #expect(APIClient.error(status: 503, code: "PROVIDER_QUOTA_EXCEEDED", retryAfter: nil) == .rateLimited(retryAfter: 60))
        #expect(APIClient.error(status: 503, code: "QUOTA_UNAVAILABLE", retryAfter: nil) == .unavailable)
        #expect(APIClient.error(status: 502, code: "PROVIDER_ERROR", retryAfter: nil) == .unavailable)
        #expect(APIClient.error(status: 504, code: "PROVIDER_TIMEOUT", retryAfter: nil) == .timedOut)
        #expect(APIClient.error(status: 429, code: "RATE_LIMITED", retryAfter: 5) == .rateLimited(retryAfter: 5))
        #expect(APIClient.error(status: 401, code: "INVALID_TOKEN", retryAfter: nil) == .refused(code: "UNAUTHORIZED", status: 401))
        #expect(APIClient.error(status: 400, code: "VALIDATION_ERROR", retryAfter: nil) == .refused(code: "VALIDATION_ERROR", status: 400))
    }

    @Test func mapsSessionErrors() {
        #expect(APIError(sessionError: LifestyleAPI.ClientError.rejected("Anonymous sign-ins are disabled")) == .notConfigured)
        #expect(APIError(sessionError: LifestyleAPI.ClientError.rateLimited) == .rateLimited(retryAfter: nil))
        #expect(APIError(sessionError: LifestyleAPI.ClientError.service("HTTP 500")) == .unavailable)
        #expect(APIError(sessionError: URLError(.notConnectedToInternet)) == .offline)
        #expect(APIError(sessionError: APIError.timedOut) == .timedOut)
    }

    @Test func mapsConnectionErrors() {
        #expect(APIError(urlError: URLError(.notConnectedToInternet)) == .offline)
        #expect(APIError(urlError: URLError(.timedOut)) == .timedOut)
        #expect(APIError(urlError: URLError(.networkConnectionLost)) == .unavailable)
        #expect(APIError(urlError: URLError(.cannotFindHost)) == .unavailable)
    }
}

struct RestaurantMenuTests {
    static let json = """
    {"query":"Chipotle Mexican Grill","restaurant":"Chipotle","hasMenu":true,
     "items":[
      {"id":"fatsecret:1","name":"Chicken Burrito Bowl","category":"Bowls","servings":[
        {"id":"fatsecret:1:10","description":"1 bowl","grams":340,"calories":655,"protein":50,"carbs":62,"fat":22,"fiber":9,"isDefault":true}]},
      {"id":"fatsecret:2","name":"Chips","category":"Sides","servings":[
        {"id":"fatsecret:2:20","description":"1 regular","grams":null,"calories":540,"protein":7,"carbs":73,"fat":25,"fiber":null,"isDefault":false},
        {"id":"fatsecret:2:21","description":"1 large","grams":null,"calories":810,"protein":11,"carbs":110,"fat":38,"fiber":null,"isDefault":true}]},
      {"id":"fatsecret:3","name":"Steak Bowl","category":"Bowls","servings":[]}],
     "fetchedAt":"2026-10-12T18:04:05.123Z","stale":false,"attribution":"Powered by fatsecret"}
    """

    @Test func decodesTheAPIsMenu() throws {
        let menu = try JSONDecoder().decode(RestaurantMenu.self, from: Data(Self.json.utf8))
        #expect(menu.restaurant == "Chipotle")
        #expect(menu.items.count == 3)
        #expect(menu.categories == ["Bowls", "Sides"])
        #expect(menu.fetchedDate != nil)
        #expect(menu.items[1].defaultServing?.id == "fatsecret:2:21")
        #expect(menu.items[2].defaultServing == nil)
        #expect(menu.items[2].listDetail == "No nutrition listed")
    }

    @Test func menuItemsLogWithTheirServing() throws {
        let menu = try JSONDecoder().decode(RestaurantMenu.self, from: Data(Self.json.utf8))
        let bowl = menu.items[0]
        let food = bowl.food(serving: bowl.servings[0], restaurant: "Chipotle")
        #expect(food.id == "fatsecret:1:10")
        #expect(food.brand == "Chipotle")
        #expect(food.source == .restaurant)
        #expect(food.calories == 655)
        #expect(food.servingText == "1 bowl (340 g)")
        // Missing nutrients count as zero.
        #expect(menu.items[1].servings[0].nutrients.fiber == 0)
    }

    @Test func noMenuDecodes() throws {
        let json = """
        {"query":"Luigi's","restaurant":null,"hasMenu":false,"items":[],"fetchedAt":"2026-10-12T18:04:05.000Z","stale":false,"attribution":"Powered by fatsecret"}
        """
        let menu = try JSONDecoder().decode(RestaurantMenu.self, from: Data(json.utf8))
        #expect(menu.hasMenu == false)
        #expect(menu.restaurant == nil)
    }

    @Test func lookupKeepsUnknownAnswers() throws {
        let json = #"{"items":[{"name":"A","restaurant":"A","hasMenu":true},{"name":"B","restaurant":null,"hasMenu":null}]}"#
        let lookup = try JSONDecoder().decode(RestaurantLookup.self, from: Data(json.utf8))
        #expect(lookup.items[0].hasMenu == true)
        #expect(lookup.items[1].hasMenu == nil)
    }
}

struct RestaurantStoreTests {
    @Test func keysFoldNamesLikeTheServer() {
        #expect(RestaurantStore.key("Chipotle Mexican Grill") == "chipotle mexican grill")
        #expect(RestaurantStore.key("  CHIPOTLE   Mexican-Grill ") == "chipotle mexican grill")
        #expect(RestaurantStore.key("Café Rio") == "cafe rio")
        #expect(RestaurantStore.key("Raising Cane’s") == "raising canes")
        #expect(RestaurantStore.key("Ben & Jerry's") == "ben and jerrys")
    }

    @Test func apiNamesAreOneTrimmedLine() {
        #expect(RestaurantStore.apiName("  Joe's\nDiner ") == "Joe's Diner")
        #expect(RestaurantStore.apiName(String(repeating: "a", count: 200)).count == 120)
    }

    @Test func refreshesOldOrStaleMenus() throws {
        var menu = try JSONDecoder().decode(RestaurantMenu.self, from: Data(RestaurantMenuTests.json.utf8))
        let now = Date.now
        #expect(!RestaurantStore.needsRefresh(MenuResult(menu: menu, savedAt: now.addingTimeInterval(-3600)), now: now))
        #expect(RestaurantStore.needsRefresh(MenuResult(menu: menu, savedAt: now.addingTimeInterval(-7 * 3600)), now: now))
        menu.stale = true
        #expect(RestaurantStore.needsRefresh(MenuResult(menu: menu, savedAt: now), now: now))
    }
}

struct EatingOutTests {
    @Test func guessesCuisineFromTheName() {
        #expect(Cuisine.guess(name: "Casa Verde Mexican Grill") == .mexican)
        #expect(Cuisine.guess(name: "Luigi's Trattoria") == .italian)
        #expect(Cuisine.guess(name: "Pho 99") == .vietnamese)
        #expect(Cuisine.guess(name: "Seoul Fried Chicken") == .korean)
        #expect(Cuisine.guess(name: "Blue Door", kind: "Café") == .cafe)
        #expect(Cuisine.guess(name: "Blue Door") == nil)
    }

    @Test func hereIsTheNearestPlaceInReach() {
        let places = [
            Place(id: "a", name: "Far", distance: 300),
            Place(id: "b", name: "Next door", distance: 60),
            Place(id: "c", name: "Here", distance: 20),
        ]
        #expect(Places.here(in: places, accuracy: 10)?.id == "c")
        #expect(Places.here(in: [places[0]], accuracy: 10) == nil)
        // A rough fix widens the reach, but never past 150 m.
        #expect(Places.here(in: [Place(id: "d", name: "D", distance: 140)], accuracy: 500)?.id == "d")
    }

    @Test func initialsSkipFillerWords() {
        #expect(Place(id: "1", name: "Casa Verde Mexican Grill").initials == "CV")
        #expect(Place(id: "2", name: "The Cheesecake Factory").initials == "CF")
    }

    @Test func plateTotalsScaleByQuantity() {
        let serving = MenuServing(id: "s", description: "1 taco", calories: 170, protein: 8, carbs: 15, fat: 9, isDefault: true)
        let line = PlateLine(item: MenuItem(id: "i", name: "Taco", servings: [serving]), serving: serving, quantity: 3)
        #expect(line.nutrients.calories == 510)
        #expect(line.nutrients.protein == 24)
    }
}
