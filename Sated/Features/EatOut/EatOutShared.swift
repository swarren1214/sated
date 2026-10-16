import CoreLocation
import SwiftUI

/// Screens in Add Food's eating-out flow.
nonisolated enum EatOutRoute: Hashable, Sendable {
    /// Search, You're Here, Your Spots and Nearby.
    case restaurants
    /// A place's menu, or Estimate when it doesn't publish one.
    case place(Place)
    /// Straight to Estimate.
    case estimate(Place)
}

/// Places to eat around the person, shared by Add Food's "You're at" card and Restaurants so
/// the location is looked up once, not on every screen.
@Observable
final class NearbyPlaces {
    static let shared = NearbyPlaces()

    enum Phase: Equatable {
        case idle, locating, loaded, denied, failed
    }

    private(set) var phase: Phase = .idle
    private(set) var location: CLLocation?
    private(set) var places: [Place] = []
    /// The place the person is at, when they're close enough to one.
    private(set) var here: Place?
    /// Which places have menus, by name. Missing means not known yet.
    private(set) var hasMenu: [String: Bool] = [:]
    /// The chain each place matched, by place name, for chain logos.
    private(set) var chains: [String: String] = [:]
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var loading: Task<Void, Never>?

    /// Looks again unless the last look was recent. `force` always looks again.
    func refresh(force: Bool = false) async {
        // Screenshot mode (Debug): the demo places stay; location is never asked for.
        if ScreenshotMode.isOn { return }
        if !force, let loadedAt, Date.now.timeIntervalSince(loadedAt) < 120, phase == .loaded { return }
        if let loading { return await loading.value }
        let task = Task { await load() }
        loading = task
        await task.value
        loading = nil
    }

    private func load() async {
        if phase != .loaded { phase = .locating }
        do {
            let location = try await Places.currentLocation()
            let found: [Place]
            do {
                found = try await Places.nearby(location)
            } catch {
                // Maps can fail on a flaky connection; once more after a moment.
                try await Task.sleep(for: .seconds(1))
                found = try await Places.nearby(location)
            }
            self.location = location
            places = Array(found.prefix(24))
            here = Places.here(in: found, accuracy: location.horizontalAccuracy)
            loadedAt = .now
            phase = .loaded
            await lookUpMenus(places.map(\.name))
        } catch PlacesError.denied {
            phase = .denied
        } catch is CancellationError {
            if phase == .locating { phase = .idle }
        } catch {
            if phase != .loaded { phase = .failed }
        }
    }

    /// Fills in the "Full menu" badges: saved answers at once, then the rest from the API.
    func lookUpMenus(_ names: [String]) async {
        for name in names where hasMenu[name] == nil {
            if let known = await RestaurantStore.shared.known(name) { note(name, known) }
        }
        let unknown = names.filter { hasMenu[$0] == nil }
        guard !unknown.isEmpty else { return }
        for (name, answer) in await RestaurantStore.shared.lookup(unknown) { note(name, answer) }
    }

    /// Records what's known about a place, from a lookup or an opened menu.
    func note(_ name: String, _ answer: LookupAnswer) {
        hasMenu[name] = answer.hasMenu
        if answer.hasMenu, let restaurant = answer.restaurant { chains[name] = restaurant }
    }
}

extension NearbyPlaces {
    /// Screenshot mode (Debug): demo places around a demo location, set by `ScreenshotSeed`.
    func showScreenshotPlaces(_ places: [Place], here: Place?, hasMenu: [String: Bool]) {
        self.places = places
        self.here = here
        self.hasMenu = hasMenu
        loadedAt = .now
        phase = .loaded
    }
}

/// A place's badge: its logo when Logo.dev has one (found by the place's website, or by the
/// chain it matched), otherwise its initials. The initials show at once and stay if anything
/// about the logo fails.
struct PlaceBadge: View {
    var place: Place
    var size: CGFloat = 40
    @State private var logo: UIImage?

    private var logoKey: LogoKey? {
        LogoKey(domain: place.domain, chain: NearbyPlaces.shared.chains[place.name])
    }

    var body: some View {
        let shape = Circle()
        ZStack {
            if let logo {
                // Edge to edge: Logo.dev's square logos fill the circle. White shows only
                // behind logos with a transparent background.
                Image(uiImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .background(Color.white)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .transition(.opacity)
            } else {
                Text(place.initials)
                    .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(
                        LinearGradient(colors: [Color(hex: 0x30C48D), Color(hex: 0x0E8A8A)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: shape
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: logoKey) {
            guard let key = logoKey else {
                logo = nil
                return
            }
            let image = await LogoStore.shared.image(for: key)
            withAnimation(.easeOut(duration: 0.2)) { logo = image }
        }
    }
}

/// "Full menu" for chains that publish nutrition, "Estimate" for everywhere else.
struct MenuBadge: View {
    var hasMenu: Bool

    var body: some View {
        Text(hasMenu ? "Full menu" : "Estimate")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(hasMenu ? AnyShapeStyle(Color(hex: 0x1E9E6A)) : AnyShapeStyle(.secondary))
            .background(hasMenu ? Color(hex: 0x1E9E6A).opacity(0.14) : Color.secondary.opacity(0.12), in: .capsule)
    }
}

/// A restaurant in a list: badge, name, details, and whether it has a menu.
struct PlaceRow: View {
    var place: Place
    var detail: String?
    var hasMenu: Bool?

    var body: some View {
        NavigationLink(value: EatOutRoute.place(place)) {
            HStack(spacing: 12) {
                PlaceBadge(place: place)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).lineLimit(1)
                    let text = detail ?? place.detail
                    if !text.isEmpty {
                        Text(text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let hasMenu { MenuBadge(hasMenu: hasMenu) }
            }
            .padding(.vertical, 2)
        }
    }
}

/// A place's name and details over its menu or estimate.
struct PlaceHeader: View {
    var place: Place
    var detail: String

    var body: some View {
        HStack(spacing: 14) {
            PlaceBadge(place: place, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.title3.bold())
                    .lineLimit(2)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A rounded search field inside a list, for screens pushed onto Add Food (whose own
/// search belongs to the tab).
struct InlineSearchField: View {
    var prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(Color(.tertiarySystemFill), in: .capsule)
    }
}
