import MapKit
import SwiftData
import SwiftUI

/// Eating Out: the place the person is at, places they've logged before, places nearby, and
/// a search for anywhere else. Places come from Apple Maps; whether each has a menu comes
/// from the Hearth API.
struct RestaurantsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var nearby = NearbyPlaces.shared
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var searching = false
    @State private var searchFailed = false
    @State private var spots: [Spot] = []
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        List {
            Section {
                InlineSearchField(prompt: "Search restaurants", text: $query)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                browse
            } else {
                searchResults
            }

            Section {} footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Places from Apple Maps. Your location is used only while you're looking for a place, and isn't saved. “Full menu” chains publish their nutrition; everywhere else, Sated helps you estimate.")
                    Link("Logos provided by Logo.dev", destination: URL(string: "https://logo.dev")!)
                        .font(.footnote.weight(.semibold))
                }
            }
        }
        .readableWidth(820)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Eating Out")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            spots = EatingOutHistory.spots(in: context)
            await nearby.refresh()
        }
        .refreshable { await nearby.refresh(force: true) }
        .task(id: query) { await search() }
    }

    @ViewBuilder private var browse: some View {
        if nearby.phase == .loaded, !nearby.places.isEmpty {
            Section {
                Map(position: $camera) {
                    UserAnnotation()
                    ForEach(nearby.places.prefix(12)) { place in
                        if let coordinate = place.coordinate {
                            Marker(place.name, systemImage: "fork.knife", coordinate: coordinate)
                                .tint(nearby.hasMenu[place.name] == true ? Color(hex: 0x1E9E6A) : .gray)
                        }
                    }
                }
                .mapControlVisibility(.hidden)
                .frame(height: 170)
                .clipShape(.rect(cornerRadius: 22))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .accessibilityHidden(true)
            }
        }

        if let here = nearby.here {
            Section("You're Here") {
                PlaceRow(place: here, hasMenu: nearby.hasMenu[here.name])
            }
        }

        if !spots.isEmpty {
            Section("Your Spots") {
                ForEach(spots) { spot in
                    let place = nearbyPlace(for: spot.place)
                    PlaceRow(place: place, detail: spot.detail, hasMenu: nearby.hasMenu[place.name])
                }
            }
            .task { await nearby.lookUpMenus(spots.map(\.place.name)) }
        }

        Section("Nearby") {
            switch nearby.phase {
            case .idle, .locating:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finding places near you…").foregroundStyle(.secondary)
                }
            case .denied:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Location is off for Sated, so it can't show places near you. You can still search.")
                        .foregroundStyle(.secondary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                .padding(.vertical, 4)
            case .failed:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Couldn't find places near you right now.")
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await nearby.refresh(force: true) } }
                }
                .padding(.vertical, 4)
            case .loaded:
                let others = nearby.places.filter { $0.id != nearby.here?.id }
                if others.isEmpty {
                    Text("No restaurants nearby. Try searching.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(others) { place in
                        PlaceRow(place: place, hasMenu: nearby.hasMenu[place.name])
                    }
                }
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        Section("Results") {
            if searching && results.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching…").foregroundStyle(.secondary)
                }
            } else if searchFailed {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Search isn't working right now.")
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await search(debounce: false) } }
                }
                .padding(.vertical, 4)
            } else if results.isEmpty {
                Text("No places found.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(results) { place in
                    PlaceRow(place: place, hasMenu: nearby.hasMenu[place.name])
                }
            }
        }
    }

    /// The saved spot, with distance and map details when it's also nearby.
    private func nearbyPlace(for ref: PlaceRef) -> Place {
        nearby.places.first { $0.id == ref.id || RestaurantStore.key($0.name) == RestaurantStore.key(ref.name) } ?? Place(ref)
    }

    private func search(debounce: Bool = true) async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            searchFailed = false
            return
        }
        if debounce {
            // Wait for a pause in typing; a new keystroke cancels this.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
        }
        searching = true
        defer { searching = false }
        do {
            let found = try await Places.search(text, near: nearby.location)
            guard !Task.isCancelled else { return }
            results = Array(found.prefix(20))
            searchFailed = false
            await nearby.lookUpMenus(results.map(\.name))
        } catch {
            guard !Task.isCancelled else { return }
            // MapKit's "no results" is an error too.
            if (error as? MKError)?.code == .placemarkNotFound {
                results = []
                searchFailed = false
            } else {
                searchFailed = true
            }
        }
    }
}

#Preview {
    NavigationStack {
        RestaurantsView()
    }
    .previewEnvironment()
}
