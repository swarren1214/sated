import CoreLocation
import MapKit

/// A place to eat, from Apple Maps or from the person's own log.
nonisolated struct Place: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// "Restaurant", "Café", "Bakery", "Brewery"
    var kind: String?
    var latitude: Double?
    var longitude: Double?
    /// From the person, in meters, when their location is known.
    var distance: Double?
    /// The place's own website domain ("chipotle.com"), from Apple Maps, for its logo.
    var domain: String?

    var ref: PlaceRef { PlaceRef(id: id, name: name) }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(id: String, name: String, kind: String? = nil, latitude: Double? = nil, longitude: Double? = nil, distance: Double? = nil, domain: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.latitude = latitude
        self.longitude = longitude
        self.distance = distance
        self.domain = domain
    }

    /// Hosts that serve many businesses (social pages, ordering and site builders). Their logo
    /// would be theirs, not the restaurant's, so a place whose website is on one gets no logo.
    static let sharedHosts: Set<String> = [
        "facebook.com", "instagram.com", "twitter.com", "x.com", "tiktok.com", "yelp.com", "google.com",
        "business.site", "linktr.ee", "linkin.bio", "square.site", "squareup.com", "toasttab.com", "clover.com",
        "doordash.com", "ubereats.com", "grubhub.com", "seamless.com", "postmates.com", "order.online",
        "menufy.com", "popmenu.com", "chownow.com", "slicelife.com", "beyondmenu.com", "wixsite.com", "wix.com",
        "squarespace.com", "weebly.com", "godaddysites.com", "wordpress.com", "blogspot.com", "carrd.co",
        "opentable.com", "resy.com", "tripadvisor.com", "apple.com", "spoton.com", "bentobox.com",
    ]

    /// The registrable domain of a website ("locations.chipotle.com" → "chipotle.com",
    /// "order.wagamama.co.uk" → "wagamama.co.uk"), or nil for shared hosts and addresses.
    static func domain(from url: URL?) -> String? {
        guard var host = url?.host()?.lowercased(), host.contains("."), !host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        // "co.uk", "com.au": a short second level under a two-letter country code takes three labels.
        let secondLevel = labels[labels.count - 2]
        let keep = labels.count >= 3 && labels.last!.count == 2 && ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or"].contains(secondLevel) ? 3 : 2
        let domain = labels.suffix(keep).joined(separator: ".")
        return sharedHosts.contains(domain) ? nil : domain
    }

    init(_ ref: PlaceRef) {
        self.init(id: ref.id, name: ref.name)
    }

    /// "Mexican · 0.1 mi", as much as is known.
    var detail: String {
        [Cuisine.guess(name: name, kind: kind)?.name ?? kind, distanceText].compactMap { $0 }.joined(separator: " · ")
    }

    var distanceText: String? {
        distance.map { Measurement(value: $0, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)) }
    }

    /// Two letters for the place's badge: "CV" for Casa Verde.
    var initials: String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { !["the", "and", "of"].contains($0.lowercased()) }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}

nonisolated enum PlacesError: Error, Equatable {
    case denied
    case unavailable
}

/// Places to eat near the person, from Apple Maps. Location is asked for only while an
/// eating-out screen is open, once, and never stored.
enum Places {
    /// Restaurants, cafés, bakeries and breweries: places that serve food.
    static let filter = MKPointOfInterestFilter(including: [.restaurant, .cafe, .bakery, .brewery, .winery, .nightlife])
    /// How far "Nearby" reaches.
    static let nearbyRadius: CLLocationDistance = 800
    /// How close counts as being at a place. Generous, since indoors GPS drifts.
    static let hereRadius: CLLocationDistance = 75

    static var authorization: CLAuthorizationStatus { CLLocationManager().authorizationStatus }
    static var isAuthorized: Bool { [.authorizedWhenInUse, .authorizedAlways].contains(authorization) }

    /// The person's location, asking permission first if it hasn't been asked yet. Waits up to
    /// `timeout` for a good fix, then settles for the best one so far.
    static func currentLocation(timeout: Duration = .seconds(8)) async throws -> CLLocation {
        if [.denied, .restricted].contains(authorization) { throw PlacesError.denied }
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }

        return try await withThrowingTaskGroup(of: CLLocation?.self) { group in
            let best = BestLocation()
            group.addTask {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                        throw PlacesError.denied
                    }
                    await best.setAsking(update.authorizationRequestInProgress)
                    guard let location = update.location, location.horizontalAccuracy >= 0,
                          location.timestamp.timeIntervalSinceNow > -120 else { continue }
                    await best.offer(location)
                    if location.horizontalAccuracy <= 65 { return location }
                }
                return nil
            }
            group.addTask {
                // The clock doesn't run while the permission alert is up.
                let step = Duration.milliseconds(250)
                var waited = Duration.zero
                while waited < timeout {
                    try await Task.sleep(for: step)
                    if !(await best.asking) { waited += step }
                }
                return nil
            }
            defer { group.cancelAll() }
            // Whichever finishes first: a good fix, or the timeout (then the best so far).
            if let first = try await group.next(), let location = first { return location }
            if let location = await best.location { return location }
            throw PlacesError.unavailable
        }
    }

    private actor BestLocation {
        var location: CLLocation?
        var asking = false
        func setAsking(_ value: Bool) { asking = value }
        func offer(_ new: CLLocation) {
            if location == nil || new.horizontalAccuracy < location!.horizontalAccuracy { location = new }
        }
    }

    /// Places to eat within `nearbyRadius`, nearest first.
    static func nearby(_ location: CLLocation) async throws -> [Place] {
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: nearbyRadius)
        request.pointOfInterestFilter = filter
        let response = try await MKLocalSearch(request: request).start()
        return places(response.mapItems, from: location)
    }

    /// Places to eat matching what the person typed, near them when their location is known.
    static func search(_ text: String, near location: CLLocation?) async throws -> [Place] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = .pointOfInterest
        request.pointOfInterestFilter = filter
        if let location {
            request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        }
        let response = try await MKLocalSearch(request: request).start()
        return places(response.mapItems, from: location)
    }

    /// The place the person is at: the nearest one, if it's within reach of their location.
    static func here(in places: [Place], accuracy: CLLocationAccuracy) -> Place? {
        let reach = min(max(hereRadius, accuracy), 150)
        return places.filter { ($0.distance ?? .infinity) <= reach }.min { ($0.distance ?? 0) < ($1.distance ?? 0) }
    }

    private static func places(_ items: [MKMapItem], from location: CLLocation?) -> [Place] {
        var seen = Set<String>()
        let all = items.compactMap { item -> Place? in
            guard let name = item.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            let itemLocation = item.location
            let id = item.identifier?.rawValue
                ?? "\(name)@\(String(format: "%.4f,%.4f", itemLocation.coordinate.latitude, itemLocation.coordinate.longitude))"
            guard seen.insert(id).inserted else { return nil }
            return Place(
                id: id,
                name: name,
                kind: kind(item.pointOfInterestCategory),
                latitude: itemLocation.coordinate.latitude,
                longitude: itemLocation.coordinate.longitude,
                distance: location.map { itemLocation.distance(from: $0) },
                domain: Place.domain(from: item.url)
            )
        }
        return all.sorted { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }
    }

    private static func kind(_ category: MKPointOfInterestCategory?) -> String? {
        switch category {
        case .restaurant?: "Restaurant"
        case .cafe?: "Café"
        case .bakery?: "Bakery"
        case .brewery?: "Brewery"
        case .winery?: "Winery"
        case .nightlife?: "Bar"
        default: nil
        }
    }
}
