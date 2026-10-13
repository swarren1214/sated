import Foundation

/// A rough idea of what a restaurant serves, guessed from its name, so Estimate can offer
/// dishes that are likely on the menu. Wrong guesses cost nothing: search is always there.
nonisolated enum Cuisine: String, CaseIterable, Sendable {
    case mexican, italian, chinese, japanese, thai, indian, vietnamese, korean, mediterranean, cafe, american

    var name: String {
        switch self {
        case .cafe: "Café"
        default: rawValue.capitalized
        }
    }

    /// Words in a name that suggest the cuisine. Checked in `allCases` order.
    private var keywords: [String] {
        switch self {
        case .mexican: ["mexican", "taco", "tacos", "taqueria", "burrito", "burritos", "cantina", "tex", "mex", "tortilla", "salsa", "mexicana", "cocina"]
        case .italian: ["italian", "trattoria", "pizzeria", "pizza", "ristorante", "osteria", "pasta", "italiano", "cucina", "enoteca"]
        case .chinese: ["chinese", "china", "wok", "szechuan", "sichuan", "hunan", "dumpling", "dumplings", "dim", "panda", "canton", "mandarin"]
        case .japanese: ["japanese", "sushi", "ramen", "izakaya", "hibachi", "teriyaki", "udon", "tokyo", "sakura", "yakitori"]
        case .thai: ["thai", "siam", "bangkok"]
        case .indian: ["indian", "india", "tandoor", "tandoori", "masala", "curry", "biryani", "punjabi", "tikka"]
        case .vietnamese: ["vietnamese", "pho", "banh", "saigon", "viet"]
        case .korean: ["korean", "seoul", "bibimbap", "kimchi", "bulgogi"]
        case .mediterranean: ["mediterranean", "greek", "gyro", "gyros", "falafel", "kebab", "kabob", "shawarma", "lebanese", "pita", "hummus", "turkish"]
        case .cafe: ["cafe", "coffee", "bakery", "espresso", "brunch", "bagel", "bagels", "pancake", "donut", "doughnut", "roasters", "tea"]
        case .american: ["burger", "burgers", "grill", "diner", "pub", "tavern", "bbq", "barbecue", "smokehouse", "wings", "steakhouse", "steak", "saloon", "sandwich", "sandwiches", "deli", "chicken"]
        }
    }

    /// Searches for dishes commonly ordered at this kind of place.
    var dishes: [String] {
        switch self {
        case .mexican: ["burrito", "tacos", "quesadilla", "enchilada", "nachos", "tortilla chips"]
        case .italian: ["spaghetti with meat sauce", "lasagna", "fettuccine alfredo", "pizza", "chicken parmesan", "garlic bread"]
        case .chinese: ["general tso chicken", "fried rice", "lo mein", "orange chicken", "egg roll", "beef and broccoli"]
        case .japanese: ["sushi", "ramen", "chicken teriyaki", "miso soup", "tempura", "edamame"]
        case .thai: ["pad thai", "curry", "fried rice", "spring roll", "satay", "soup"]
        case .indian: ["chicken tikka masala", "butter chicken", "naan", "samosa", "biryani", "dal"]
        case .vietnamese: ["pho", "banh mi", "spring roll", "vermicelli", "fried rice", "soup"]
        case .korean: ["bibimbap", "bulgogi", "fried chicken", "kimchi", "fried rice", "dumpling"]
        case .mediterranean: ["gyro", "falafel", "hummus", "greek salad", "shawarma", "pita"]
        case .cafe: ["latte", "muffin", "bagel with cream cheese", "croissant", "breakfast sandwich", "scone"]
        case .american: ["cheeseburger", "french fries", "chicken wings", "grilled chicken sandwich", "caesar salad", "steak"]
        }
    }

    /// Everyday restaurant dishes, for a place whose cuisine can't be guessed.
    static let generalDishes = ["hamburger", "french fries", "grilled chicken", "caesar salad", "pasta", "steak"]

    /// The cuisine a place's name (or its Maps category) suggests, or nil.
    static func guess(name: String, kind: String? = nil) -> Cuisine? {
        let words = Set(
            name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
        )
        if let match = allCases.first(where: { !words.isDisjoint(with: $0.keywords) }) { return match }
        switch kind {
        case "Café", "Bakery": return .cafe
        case "Brewery", "Bar": return .american
        default: return nil
        }
    }
}
