import Foundation
import SwiftData

/// Finds the food behind each thing someone said, best source first:
///
/// 1. **The restaurant's menu**, when they named a place ("Chick-fil-A grilled chicken sandwich").
///    Menus come from the Hearth API through `RestaurantStore`, which keeps a copy on the device
///    for a day, so a place they eat at often answers instantly. The size they said picks the
///    serving ("a regular waffle fries" is the medium), and "three packets" is three servings.
/// 2. **What they've logged before**: at that place, or a barcode, label or quick-add food that
///    isn't in the database ("my Fairlife shake").
/// 3. **The bundled database**, with the generic name. When they named a place but this is all
///    that matched, the food is marked approximate so the Watch and Say It point it out.
///
/// Every number comes from one of these; the model never makes one up.
enum SpokenFoodMatcher {
    /// Where menus come from. Tests pass their own.
    nonisolated struct MenuSource: Sendable {
        var menu: @Sendable (String) async -> RestaurantMenu?

        static let live = MenuSource { name in
            try? await RestaurantStore.shared.menu(for: name).menu
        }

        static let none = MenuSource { _ in nil }
    }

    /// How long to wait for menus before matching without them. A slow request still finishes
    /// in the background and is saved, so the next time is instant.
    static let menuWait: Duration = .seconds(5)

    /// A place they named, as found.
    struct Place {
        var ref: PlaceRef
        var menu: RestaurantMenu?
    }

    static func match(_ items: [ParsedFood], database: FoodDatabase, context: ModelContext?, menus: MenuSource) async -> [VoiceItem] {
        let history = context.map { recentEntries(in: $0) } ?? []

        // "Chick-fil-A sandwich, waffle fries and a sauce": the place carries to the foods after it.
        var carried = ""
        let sources: [(item: ParsedFood, place: String, inherited: Bool)] = items.map { item in
            let said = item.restaurant.trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty { carried = said; return (item, said, false) }
            return (item, carried, !carried.isEmpty)
        }

        let names = Array(Set(sources.map(\.place).filter { !$0.isEmpty }))
        let places = await findPlaces(names, history: history, menus: menus)

        return sources.map { source in
            let place = source.place.isEmpty ? nil : places[source.place]
            return match(source.item, place: place, inherited: source.inherited, history: history, database: database)
        }
    }

    // MARK: One food

    static func match(_ item: ParsedFood, place: Place?, inherited: Bool, history: [FoodEntry], database: FoodDatabase) -> VoiceItem {
        let spoken = MealParser.describe(item)
        let said = item.name.isEmpty ? item.food : item.name

        if let place {
            let brands = [place.ref.name, item.restaurant, place.menu?.restaurant].compactMap { $0 }
            let words = searchWords(said, removing: brands)

            // 1. The menu.
            if let menu = place.menu, menu.hasMenu, let found = bestMenuItem(for: words, in: menu),
               let picked = serving(for: item, in: found.item) {
                let food = found.item.food(serving: picked.serving, restaurant: menu.restaurant ?? place.ref.name)
                return VoiceItem(spoken: spoken, food: food, servings: picked.servings, place: place.ref, isApproximate: !found.isClose)
            }

            // 2. What they've had there before.
            let here = history.filter { isAt($0, place.ref) }
            if let entry = bestEntry(for: words, in: here) {
                let servings = item.quantity == 1 ? entry.servings : max(item.quantity, 0.25)
                return VoiceItem(spoken: spoken, food: EatingOutHistory.food(from: entry), servings: servings, place: place.ref)
            }
        }

        // 2. A food from a barcode, label or quick add, which the database won't have.
        let own = history.filter { ownSources.contains($0.source) }
        if let entry = bestEntry(for: searchWords(said, removing: []), in: own, includingBrand: true) {
            let servings = item.quantity == 1 ? entry.servings : max(item.quantity, 0.25)
            return VoiceItem(spoken: spoken, food: EatingOutHistory.food(from: entry), servings: servings)
        }

        // 3. The database. A food from a place they named that's only matched generically is a guess.
        let generic = item.food.isEmpty ? said : item.food
        let found = database.search(generic, limit: 1).first ?? database.search(said, limit: 1).first
        return VoiceItem(
            spoken: spoken,
            food: found,
            servings: found.map { MealParser.servings(for: item, food: $0) } ?? max(item.quantity, 0.25),
            isApproximate: found != nil && place != nil && !inherited
        )
    }

    /// Foods that came from somewhere other than the bundled database.
    static let ownSources: Set<FoodSource> = [.openFoodFacts, .label, .quickAdd]

    // MARK: Places and menus

    /// Each place said, matched to one they've logged at when the names agree ("chick fil a" is
    /// their "Chick-fil-A"), with its menu. Menus are asked for all at once.
    static func findPlaces(_ names: [String], history: [FoodEntry], menus: MenuSource) async -> [String: Place] {
        guard !names.isEmpty else { return [:] }
        var known: [String: PlaceRef] = [:]
        for entry in history {
            guard let place = entry.place else { continue }
            let key = squashed(place.name)
            if known[key] == nil { known[key] = place }
        }
        var refs: [String: PlaceRef] = [:]
        for name in names {
            refs[name] = known[squashed(name)] ?? PlaceRef(id: name, name: name)
        }
        let asks = names.map { ($0, refs[$0]?.name ?? $0) }
        let source = menus
        let fetched = await first(within: menuWait) {
            await withTaskGroup(of: (String, RestaurantMenu?).self) { group in
                for (name, asked) in asks {
                    group.addTask { (name, await source.menu(asked)) }
                }
                var found: [String: RestaurantMenu] = [:]
                for await (name, menu) in group { found[name] = menu }
                return found
            }
        } ?? [:]
        var places: [String: Place] = [:]
        for name in names {
            var ref = refs[name] ?? PlaceRef(id: name, name: name)
            let menu = fetched[name]
            // A place they haven't logged at takes the chain's spelling ("Chick-fil-A").
            if known[squashed(name)] == nil, let chain = menu?.restaurant { ref = PlaceRef(id: chain, name: chain) }
            places[name] = Place(ref: ref, menu: menu)
        }
        return places
    }

    struct MenuMatch {
        var item: MenuItem
        /// Every word said is in the item's name, with little else in it.
        var isClose: Bool
    }

    /// The menu item that best fits what was said: the most spoken words found, then the fewest
    /// words they didn't say ("grilled chicken sandwich" is the Grilled Chicken Sandwich, not the
    /// Grilled Chicken Club Sandwich). At least half the words must be found.
    static func bestMenuItem(for words: [String], in menu: RestaurantMenu) -> MenuMatch? {
        guard !words.isEmpty else { return nil }
        let brands = [menu.restaurant, menu.query].compactMap { $0 }
        var best: (item: MenuItem, coverage: Double, extras: Int)?
        for item in menu.items where item.defaultServing != nil {
            let candidate = searchWords(item.name, removing: brands)
            guard let result = fit(words, candidate), result.coverage >= 0.5 else { continue }
            let coverage = result.coverage, extras = result.extras
            if let current = best {
                let better = coverage > current.coverage
                    || (coverage == current.coverage && extras < current.extras)
                    || (coverage == current.coverage && extras == current.extras && item.name.count < current.item.name.count)
                guard better else { continue }
            }
            best = (item, coverage, extras)
        }
        return best.map { MenuMatch(item: $0.item, isClose: $0.coverage == 1 && $0.extras <= 2) }
    }

    static let sizeWords: [String: [String]] = [
        "small": ["small"],
        "medium": ["medium", "regular"],
        "regular": ["regular", "medium"],
        "large": ["large"],
        "kids": ["kids", "kid", "child", "small"],
    ]

    /// Words that name a count-sized serving: "8 count", "12 pc", "6 nuggets".
    static let countWords: Set<String> = ["count", "ct", "pc", "pcs", "piece", "pieces", "nugget", "nuggets", "strip", "strips", "wing", "wings"]

    /// The serving for what was said and how many of it. A size picks the matching serving
    /// ("regular" is medium); "an 8 count" picks the 8-count serving once rather than eight of
    /// them; a weight is converted; anything else counts servings.
    static func serving(for item: ParsedFood, in menuItem: MenuItem) -> (serving: MenuServing, servings: Double)? {
        guard let fallback = menuItem.defaultServing else { return nil }
        let quantity = max(item.quantity, 0.25)

        if quantity > 1, quantity == quantity.rounded() {
            let number = String(Int(quantity))
            if let sized = menuItem.servings.first(where: { serving in
                let words = FoodDatabase.words(serving.description)
                return words.contains(number) && words.contains(where: countWords.contains)
            }) {
                return (sized, 1)
            }
        }

        var size = item.size.lowercased().trimmingCharacters(in: .whitespaces)
        if size.isEmpty {
            size = FoodDatabase.words(item.name).first(where: { sizeWords[$0] != nil }) ?? ""
        }
        var chosen = fallback
        if let wanted = sizeWords[size] {
            // Try each wanted word in order, so "regular" prefers a Regular serving to a Medium one.
            for word in wanted {
                if let match = menuItem.servings.first(where: { FoodDatabase.words($0.description).contains(word) }) {
                    chosen = match
                    break
                }
            }
        }

        let grams: Double? = switch item.unit {
        case "g", "gram": quantity
        case "oz", "ounce": quantity * 28.35
        case "lb", "pound": quantity * 453.6
        default: nil
        }
        if let grams, let servingGrams = chosen.grams, servingGrams > 0 {
            return (chosen, max((grams / servingGrams * 4).rounded() / 4, 0.25))
        }
        return (chosen, quantity)
    }

    // MARK: The person's log

    static func recentEntries(in context: ModelContext) -> [FoodEntry] {
        let start = Calendar.current.date(byAdding: .day, value: -EatingOutHistory.window, to: .now) ?? .distantPast
        var descriptor = FetchDescriptor<FoodEntry>(
            predicate: #Predicate { $0.date >= start },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 1_000
        return (try? context.fetch(descriptor)) ?? []
    }

    static func isAt(_ entry: FoodEntry, _ place: PlaceRef) -> Bool {
        if let id = entry.placeID, id == place.id { return true }
        return entry.placeName.map { squashed($0) == squashed(place.name) } ?? false
    }

    /// The newest entry whose name has every word said and at most one more.
    static func bestEntry(for words: [String], in entries: [FoodEntry], includingBrand: Bool = false) -> FoodEntry? {
        guard !words.isEmpty else { return nil }
        return entries.first { entry in
            let name = includingBrand ? "\(entry.brand ?? "") \(entry.name)" : entry.name
            guard let result = fit(words, searchWords(name, removing: [])) else { return false }
            return result.coverage == 1 && result.extras <= 1
        }
    }

    // MARK: Words

    /// Words that don't say which food it is.
    static let fillerWords: Set<String> = [
        "a", "an", "the", "of", "with", "and", "my", "some", "order", "side", "packet", "packets",
        "serving", "servings", "piece", "pieces", "small", "medium", "large", "regular", "kids", "kid",
        "s", "w", "size",
    ]

    static let spellings: [String: String] = [
        "bbq": "barbecue", "barbeque": "barbecue", "fry": "fries",
        "sammich": "sandwich", "sando": "sandwich", "chikn": "chicken",
    ]

    /// The words that identify a food, with a brand's name taken out where it appears
    /// ("Chick-fil-A sauce" at Chick-fil-A is "sauce").
    static func searchWords(_ text: String, removing brands: [String]) -> [String] {
        var words = FoodDatabase.words(text).map { spellings[$0] ?? $0 }
        for brand in brands {
            let brandWords = FoodDatabase.words(brand)
            guard !brandWords.isEmpty else { continue }
            if let range = phrase(brandWords, in: words) {
                words.removeSubrange(range)
            }
            let joined = brandWords.joined()
            words.removeAll { $0 == joined }
        }
        return words.filter { !fillerWords.contains($0) }
    }

    private static func phrase(_ needle: [String], in words: [String]) -> Range<Int>? {
        guard needle.count <= words.count else { return nil }
        for start in 0...(words.count - needle.count) where Array(words[start..<start + needle.count]) == needle {
            return start..<start + needle.count
        }
        return nil
    }

    /// How much of what was said a name covers (0–1), and how many of its words weren't said.
    static func fit(_ said: [String], _ name: [String]) -> (coverage: Double, extras: Int)? {
        guard !said.isEmpty, !name.isEmpty else { return nil }
        let found = said.filter { word in name.contains { RecipeEstimator.sameWord($0, word) } }.count
        let extras = name.filter { word in !said.contains { RecipeEstimator.sameWord($0, word) } }.count
        return (Double(found) / Double(said.count), extras)
    }

    /// A place name without spaces or punctuation: "Chick fil A", "chick-fil-a" and "Chickfila" agree.
    static func squashed(_ name: String) -> String {
        RestaurantStore.key(name).replacingOccurrences(of: " ", with: "")
    }

    // MARK: Waiting

    /// The work's answer, or nil if it takes longer than `limit`. The work keeps running.
    static func first<T: Sendable>(within limit: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce(continuation)
            Task { once.resume(await work()) }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(nil)
            }
        }
    }
}

/// Resumes a continuation the first time only.
nonisolated private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
