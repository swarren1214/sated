import SwiftUI

/// A planned meal's picture, as in Caloma: the recipe's photo from BigTable, or the restaurant's
/// logo on white when eating out. Without either (or while it loads, or offline), BigTable's
/// fork and knife on its red.
struct PlannedMealArtwork: View {
    var meal: HearthMealPlan.Meal
    var cornerRadius: CGFloat = 12

    var body: some View {
        Group {
            if let url = meal.artworkURL {
                AsyncImage(url: url, transaction: Transaction(animation: .smooth(duration: 0.25))) { phase in
                    switch phase {
                    case .success(let image):
                        if meal.isDineOut {
                            logo(image)
                        } else {
                            image.resizable().scaledToFill()
                        }
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        // A photo scaled to fill is larger than its frame; this keeps it inside.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    /// Logos are small and square: centered on white, with room around them.
    private func logo(_ image: Image) -> some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height) * 0.62
            ZStack {
                Color.white
                image.resizable().interpolation(.high).scaledToFit()
                    .frame(width: side, height: side)
                    .clipShape(.rect(cornerRadius: side * 0.18, style: .continuous))
            }
        }
    }

    private var placeholder: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [BigTableMeals.color.mix(with: .white, by: 0.12), BigTableMeals.color.mix(with: .black, by: 0.25)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: meal.symbol)
                    .font(.system(size: max(min(proxy.size.width, proxy.size.height) * 0.36, 10), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

extension HearthMealPlan.Meal {
    var isDineOut: Bool { kind == "dineOut" }

    var symbol: String { isDineOut ? "takeoutbag.and.cup.and.straw" : "fork.knife" }

    /// The restaurant for eating out, else the meal's name.
    var displayTitle: String { isDineOut ? (placeName ?? title) : title }

    /// The recipe's photo, or the restaurant's logo when eating out. Only https.
    var artworkURL: URL? {
        let raw = isDineOut ? logoURL : imageURL
        guard let raw, let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }

    var openURL: URL? { link.flatMap(URL.init(string:)) }

    /// How this meal is filed in Sated's log, so logging it again finds the last servings and
    /// lands under one Recent item.
    var foodID: String {
        let ids = recipeIDs ?? []
        return "bigtable.\(ids.isEmpty ? title.lowercased() : ids.joined(separator: "+"))"
    }

    /// Whether this planned meal is already in the day's log: the same BigTable meal, or a meal
    /// at the restaurant BigTable planned.
    func isLogged(in entries: [FoodEntry]) -> Bool {
        if let place = restaurant {
            let name = HearthNames.normalized(place.name)
            return entries.contains { HearthNames.normalized($0.placeName ?? "") == name }
        }
        let id = foodID
        return entries.contains { $0.foodID == id }
    }

    /// The restaurant to open in Eat Out, when eating out somewhere named.
    var restaurant: Place? {
        guard isDineOut else { return nil }
        let name = (placeName ?? title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return Place(id: "bigtable.\(name.lowercased())", name: name, kind: "Restaurant")
    }
}
