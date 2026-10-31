import Foundation
import CoreLocation
import os
import MapKit

// `show_places`: the model's picks on a map card in the chat, and `current_location`: roughly where the user is. Places
// without coordinates are looked up with MapKit on the device; directions hand off to the Naver Map app (or its website).

/// One place as `show_places` takes it. Numbers may arrive as strings ("4.5", "1,234") and are read leniently.
struct PlaceInput: Codable, Sendable, Equatable {
    var name: String
    var category: String?
    var rating: Double?
    var reviewCount: Int?
    var address: String?
    var lat: Double?
    var lng: Double?
    var placeId: String?
    var note: String?
    var quote: String?

    init(name: String, category: String? = nil, rating: Double? = nil, reviewCount: Int? = nil, address: String? = nil,
         lat: Double? = nil, lng: Double? = nil, placeId: String? = nil, note: String? = nil, quote: String? = nil) {
        self.name = name
        self.category = category
        self.rating = rating
        self.reviewCount = reviewCount
        self.address = address
        self.lat = lat
        self.lng = lng
        self.placeId = placeId
        self.note = note
        self.quote = quote
    }

    private enum Keys: String, CodingKey { case name, category, rating, reviewCount, address, lat, lng, placeId, note, quote }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func text(_ key: Keys) -> String? {
            if let s = try? c.decodeIfPresent(String.self, forKey: key) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            if let n = try? c.decodeIfPresent(Double.self, forKey: key) { return n == n.rounded() ? (Int(exactly: n).map(String.init) ?? String(n)) : String(n) }
            return nil
        }
        func number(_ key: Keys) -> Double? {
            if let n = try? c.decodeIfPresent(Double.self, forKey: key) { return n }
            guard let s = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
            return Double(s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces))
        }
        guard let name = text(.name) else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "each place needs a name")
        }
        self.name = name
        category = text(.category)
        rating = number(.rating)
        reviewCount = number(.reviewCount).flatMap { Int(exactly: $0.rounded(.down)) } // a huge or NaN count is dropped
        address = text(.address)
        lat = number(.lat)
        lng = number(.lng)
        placeId = text(.placeId)
        note = text(.note)
        quote = text(.quote)
        if let lat, let lng, !Self.isValid(lat: lat, lng: lng) { self.lat = nil; self.lng = nil }
    }

    static func isValid(lat: Double, lng: Double) -> Bool {
        (-90...90).contains(lat) && (-180...180).contains(lng) && !(lat == 0 && lng == 0)
    }
}

/// The arguments of a `show_places` call.
struct ShowPlacesArguments: Decodable, Sendable, Equatable {
    var title: String?
    var places: [PlaceInput]

    static let maxPlaces = 20

    enum Problem: Error, LocalizedError, Equatable {
        case notJSON, noPlaces, badPlace(String)
        var errorDescription: String? {
            switch self {
            case .notJSON: "The arguments must be a JSON object with a places array."
            case .noPlaces: "places is empty: pass at least one place with a name."
            case .badPlace(let m): "A place could not be read: \(m)"
            }
        }
    }

    private enum Keys: String, CodingKey { case title, places }

    init(title: String? = nil, places: [PlaceInput]) {
        self.title = title
        self.places = places
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        title = (try? c.decodeIfPresent(String.self, forKey: .title))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if title?.isEmpty == true { title = nil }
        // Some models send the array as a JSON string.
        if let raw = try? c.decode(String.self, forKey: .places) {
            places = try JSONDecoder().decode([PlaceInput].self, from: Data(raw.utf8))
        } else {
            places = try c.decode([PlaceInput].self, forKey: .places)
        }
    }

    static func parse(_ arguments: String) throws -> ShowPlacesArguments {
        guard let data = arguments.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw Problem.notJSON
        }
        let parsed: ShowPlacesArguments
        do { parsed = try JSONDecoder().decode(ShowPlacesArguments.self, from: data) }
        catch let DecodingError.dataCorrupted(context) { throw Problem.badPlace(context.debugDescription) }
        catch let DecodingError.keyNotFound(key, _) { throw key.stringValue == "places" ? Problem.noPlaces : Problem.badPlace("missing \(key.stringValue)") }
        catch { throw Problem.badPlace("each place must be an object with a name.") }
        guard !parsed.places.isEmpty else { throw Problem.noPlaces }
        return ShowPlacesArguments(title: parsed.title, places: Array(parsed.places.prefix(maxPlaces)))
    }
}

/// A place on the map card: what the model gave, plus where it is.
struct MapPlace: Codable, Sendable, Hashable, Identifiable {
    /// 1-based, the number on its pin.
    var number: Int
    var name: String
    var category: String?
    var rating: Double?
    var reviewCount: Int?
    var address: String?
    var lat: Double?
    var lng: Double?
    var placeId: String?
    var note: String?
    var quote: String?
    /// The coordinates came from a MapKit lookup, not from the model.
    var locatedOnDevice: Bool?

    var id: Int { number }
    var hasLocation: Bool { lat != nil && lng != nil }

    init(number: Int, input: PlaceInput) {
        self.number = number
        name = input.name
        category = input.category
        rating = input.rating
        reviewCount = input.reviewCount
        address = input.address
        lat = input.lat
        lng = input.lng
        placeId = input.placeId
        note = input.note
        quote = input.quote
    }
}

/// What a `show_places` call put on the map (kept with the call for the chat; never sent to the API).
struct PlaceCollection: Codable, Sendable, Hashable {
    var title: String?
    var places: [MapPlace]
}

// MARK: - Map links

/// How to get to a place: the directions buttons on its sheet.
enum RouteMode: String, CaseIterable, Identifiable, Sendable {
    case walk, transit, car, bike
    var id: String { rawValue }

    var label: String {
        switch self {
        case .walk: String(localized: "Walk")
        case .transit: String(localized: "Transit")
        case .car: String(localized: "Car")
        case .bike: String(localized: "Bike")
        }
    }

    var systemImage: String {
        switch self {
        case .walk: "figure.walk"
        case .transit: "tram.fill"
        case .car: "car.fill"
        case .bike: "bicycle"
        }
    }
}

/// The maps a place opens in: Naver Map in Korea; abroad, where Naver knows little, Google Maps when it is installed and
/// Apple Maps otherwise.
enum MapTarget: Sendable, Equatable {
    case naver, google, apple

    static func `for`(_ place: MapPlace, googleMapsInstalled: Bool) -> MapTarget {
        if place.isInKorea { return .naver }
        return googleMapsInstalled ? .google : .apple
    }

    var name: String {
        switch self {
        case .naver: String(localized: "Naver Map")
        case .google: String(localized: "Google Maps")
        case .apple: String(localized: "Apple Maps")
        }
    }
}

extension MapPlace {
    /// South Korea, roughly: a box from Jeju to the DMZ and from Baengnyeong to Dokdo, less the corner of it that holds
    /// Tsushima and northern Kyushu (Fukuoka). North of the DMZ is left in; nobody plans a cafe trip there.
    static func isInKorea(lat: Double, lng: Double) -> Bool {
        guard (33.0...38.7).contains(lat), (124.5...132.0).contains(lng) else { return false }
        return !(lat < 35.0 && lng > 129.1)
    }

    /// Whether the place is in Korea: by its coordinates, or without them by what the model gave (a Naver Place id, or
    /// a name or address in Hangul), since a place without coordinates opens as a search for its name.
    var isInKorea: Bool {
        if let lat, let lng { return Self.isInKorea(lat: lat, lng: lng) }
        return placeId != nil || [name, address ?? ""].contains(where: SearchEngines.containsHangul)
    }
}

enum NaverMap {
    static let appName = "cc.coolservices.strata"

    private static func query(_ items: [(String, String)]) -> String { MapLinkQuery.encode(items) }

    private static func coordinate(_ value: Double) -> String { String(format: "%.7f", value) }

    /// The `nmap://route/<path>` of a mode.
    private static func appPath(_ mode: RouteMode) -> String {
        switch mode {
        case .walk: "walk"
        case .transit: "public"
        case .car: "car"
        case .bike: "bicycle"
        }
    }

    /// Directions in the Naver Map app, from the current location.
    static func appRoute(_ mode: RouteMode, to place: MapPlace) -> URL? {
        guard let lat = place.lat, let lng = place.lng else { return nil }
        return URL(string: "nmap://route/\(appPath(mode))?" + query([("dlat", coordinate(lat)), ("dlng", coordinate(lng)),
                                                                   ("dname", place.name), ("appname", appName)]))
    }

    /// The place in the Naver Map app: its pin, or a search for its name when it has no coordinates.
    static func appPlace(_ place: MapPlace) -> URL? {
        guard let lat = place.lat, let lng = place.lng else {
            return URL(string: "nmap://search?" + query([("query", place.name), ("appname", appName)]))
        }
        return URL(string: "nmap://place?" + query([("lat", coordinate(lat)), ("lng", coordinate(lng)), ("name", place.name),
                                                   ("appname", appName)]))
    }

    /// A path segment: everything but unreserved characters percent-encoded (a name may hold `,` or `/`).
    private static func segment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

    /// Directions on map.naver.com (the fallback without the app).
    static func webRoute(_ mode: RouteMode, to place: MapPlace) -> URL? {
        guard let lat = place.lat, let lng = place.lng else { return webPlace(place) }
        let id = place.placeId.map(segment) ?? ""
        let goal = [coordinate(lng), coordinate(lat), segment(place.name), id, place.placeId == nil ? "" : "PLACE_POI"].joined(separator: ",")
        return URL(string: "https://map.naver.com/p/directions/-/\(goal)/-/\(mode.rawValue)")
    }

    /// The place on map.naver.com: its page when the id is known, otherwise a search for its name.
    static func webPlace(_ place: MapPlace) -> URL? {
        if let id = place.placeId, id.allSatisfy(\.isNumber) { return URL(string: "https://map.naver.com/p/entry/place/\(id)") }
        let q = [place.name, place.address].compactMap { $0 }.joined(separator: " ")
        return URL(string: "https://map.naver.com/p/search/\(segment(q))")
    }
}

/// The Google Maps app (`comgooglemaps://`), for places abroad.
enum GoogleMaps {
    static let probe = URL(string: "comgooglemaps://")!

    private static func directionsMode(_ mode: RouteMode) -> String {
        switch mode {
        case .walk: "walking"
        case .transit: "transit"
        case .car: "driving"
        case .bike: "bicycling"
        }
    }

    /// Directions from the current location.
    static func appRoute(_ mode: RouteMode, to place: MapPlace) -> URL? {
        guard let lat = place.lat, let lng = place.lng else { return nil }
        return URL(string: "comgooglemaps://?" + MapLinkQuery.encode([("daddr", MapLinkQuery.coordinate(lat, lng)),
                                                                     ("directionsmode", directionsMode(mode))]))
    }

    /// A search for the place: by name around its coordinates, so the result is the place itself rather than a bare pin.
    static func appPlace(_ place: MapPlace) -> URL? {
        let q = [place.name, place.address].compactMap { $0 }.joined(separator: " ")
        guard let lat = place.lat, let lng = place.lng else { return URL(string: "comgooglemaps://?" + MapLinkQuery.encode([("q", q)])) }
        return URL(string: "comgooglemaps://?" + MapLinkQuery.encode([("q", q), ("center", MapLinkQuery.coordinate(lat, lng)), ("zoom", "16")]))
    }
}

/// Apple Maps links (maps.apple.com opens the Maps app on iPhone and Mac), for places abroad without Google Maps.
enum AppleMaps {
    private static func mode(_ mode: RouteMode) -> String {
        switch mode {
        case .walk: "walking"
        case .transit: "transit"
        case .car: "driving"
        case .bike: "cycling"
        }
    }

    /// Directions from the current location.
    static func route(_ mode: RouteMode, to place: MapPlace) -> URL? {
        guard let lat = place.lat, let lng = place.lng else { return self.place(place) }
        return URL(string: "https://maps.apple.com/directions?" + MapLinkQuery.encode([("destination", MapLinkQuery.coordinate(lat, lng)),
                                                                                       ("mode", self.mode(mode))]))
    }

    /// The place's pin with its name, or a search for its name when it has no coordinates.
    static func place(_ place: MapPlace) -> URL? {
        guard let lat = place.lat, let lng = place.lng else {
            let q = [place.name, place.address].compactMap { $0 }.joined(separator: " ")
            return URL(string: "https://maps.apple.com/search?" + MapLinkQuery.encode([("query", q)]))
        }
        return URL(string: "https://maps.apple.com/place?" + MapLinkQuery.encode([("coordinate", MapLinkQuery.coordinate(lat, lng)),
                                                                                  ("name", place.name)]))
    }
}

/// Query strings for the Google and Apple links.
enum MapLinkQuery {
    static func encode(_ items: [(String, String)]) -> String {
        var comps = URLComponents()
        comps.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        // `+` would read as a space; `&` and `=` are already escaped by URLComponents.
        return (comps.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }

    /// "33.7490000,-84.3880000".
    static func coordinate(_ lat: Double, _ lng: Double) -> String { String(format: "%.7f,%.7f", lat, lng) }
}

// MARK: - Lookup

/// Finds coordinates for a place by name (and address) with MapKit.
protocol PlaceLocating: Sendable {
    func locate(_ place: MapPlace, near: CLLocationCoordinate2D?) async -> CLLocationCoordinate2D?
}

struct MapKitPlaceLocator: PlaceLocating {
    /// South Korea, when nothing better is known.
    static let korea = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 36.4, longitude: 127.8),
                                          span: MKCoordinateSpan(latitudeDelta: 6, longitudeDelta: 6))

    /// Name and address first, then the address alone: Apple Maps knows few Korean places by name, but finds street
    /// addresses (the pin is then the address, shown as approximate).
    static func queries(for place: MapPlace) -> [String] {
        var out = [[place.name, place.address].compactMap { $0 }.joined(separator: " ")]
        if let address = place.address { out.append(address) }
        return out
    }

    func locate(_ place: MapPlace, near: CLLocationCoordinate2D?) async -> CLLocationCoordinate2D? {
        for query in Self.queries(for: place) {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = near.map { MKCoordinateRegion(center: $0, span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)) } ?? Self.korea
            guard let response = try? await MKLocalSearch(request: request).start(), let item = response.mapItems.first else { continue }
            let c = item.location.coordinate
            if PlaceInput.isValid(lat: c.latitude, lng: c.longitude) { return c }
        }
        return nil
    }
}

/// `show_places`: resolves missing coordinates, and returns a short summary for the model with the places for the card.
struct ShowPlacesTool {
    var locator: any PlaceLocating = MapKitPlaceLocator()
    /// Where the user is, when `current_location` found out this session.
    var near: CLLocationCoordinate2D? = LocationProvider.lastKnown
    var lookupLimit: Duration = .seconds(8)

    func run(arguments: String) async -> ToolOutput {
        let parsed: ShowPlacesArguments
        do { parsed = try ShowPlacesArguments.parse(arguments) }
        catch { return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true) }
        var places = parsed.places.enumerated().map { MapPlace(number: $0.offset + 1, input: $0.element) }
        // The places already placed are the best hint where the others are.
        let known = places.compactMap { p in p.lat.flatMap { lat in p.lng.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) } } }
        let hint = near ?? known.first
        let missing = places.indices.filter { !places[$0].hasLocation }
        if !missing.isEmpty {
            let locator = locator
            let limit = lookupLimit
            let snapshot = places
            let found = await withTaskGroup(of: (Int, CLLocationCoordinate2D?).self) { group in
                for i in missing {
                    let place = snapshot[i]
                    group.addTask {
                        let coordinate = try? await Deadline.run(limit) { await locator.locate(place, near: hint) }
                        return (i, coordinate ?? nil)
                    }
                }
                var out: [Int: CLLocationCoordinate2D] = [:]
                for await (i, c) in group { if let c { out[i] = c } }
                return out
            }
            for (i, c) in found {
                places[i].lat = c.latitude
                places[i].lng = c.longitude
                places[i].locatedOnDevice = true
            }
        }
        let collection = PlaceCollection(title: parsed.title, places: places)
        return ToolOutput(text: Self.summary(collection), places: collection)
    }

    /// What the model reads: the card is shown, and which places could not be put on the map.
    static func summary(_ collection: PlaceCollection) -> String {
        let placed = collection.places.filter(\.hasLocation).count
        var lines = ["Shown to the user as a map card with \(collection.places.count) place\(collection.places.count == 1 ? "" : "s") (\(placed) on the map). Each card has Naver Map directions; do not repeat the list in full."]
        for p in collection.places {
            let where_ = p.hasLocation ? (p.locatedOnDevice == true ? "located by name" : "pinned") : "not found on the map, listed only"
            lines.append("\(p.number). \(p.name): \(where_)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Current location

/// Roughly where the user is, asked for When In Use on first use.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    /// The last position found this session (for MapKit lookups near the user).
    /// The last fix, read by `show_places` from any executor while `current_location` writes it: behind a lock.
    nonisolated static var lastKnown: CLLocationCoordinate2D? {
        get { lastKnownLock.withLock { $0 } }
        set { lastKnownLock.withLock { $0 = newValue } }
    }
    private nonisolated static let lastKnownLock = OSAllocatedUnfairLock<CLLocationCoordinate2D?>(initialState: nil)

    private let manager = CLLocationManager()
    /// Callers waiting for the permission answer or a fix, by call. A cancelled call leaves at once (`leave`).
    private var authorization: [UUID: CheckedContinuation<CLAuthorizationStatus, Never>] = [:]
    private var fixes: [UUID: CheckedContinuation<CLLocation, Error>] = [:]
    /// Calls cancelled before their continuation was stored.
    private var leftEarly: Set<UUID> = []

    enum Failure: Error, LocalizedError {
        case denied, restricted, unavailable(String)
        var errorDescription: String? {
            switch self {
            case .denied: "The user has not allowed OmniChat to use their location. Ask them where they are (an area or a station) instead, or tell them they can allow it in Settings."
            case .restricted: "Location access is restricted on this device. Ask the user where they are instead."
            case .unavailable(let m): "The location could not be found (\(m)). Ask the user where they are instead."
            }
        }
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentLocation() async throws -> CLLocation {
        var status = manager.authorizationStatus
        if status == .notDetermined {
            let id = UUID()
            status = await withTaskCancellationHandler {
                await withCheckedContinuation { cont in
                    if leftEarly.remove(id) != nil { cont.resume(returning: .notDetermined); return }
                    authorization[id] = cont
                    manager.requestWhenInUseAuthorization()
                }
            } onCancel: {
                Task { @MainActor in self.leave(id) }
            }
        }
        switch status {
        case .denied: throw Failure.denied
        case .restricted: throw Failure.restricted
        default: break
        }
        // Stopped (or timed out) while the permission prompt was up: don't start a fix nobody waits for.
        try Task.checkCancellation()
        let id = UUID()
        let location = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CLLocation, Error>) in
                if leftEarly.remove(id) != nil { cont.resume(throwing: CancellationError()); return }
                fixes[id] = cont
                manager.requestLocation()
            }
        } onCancel: {
            Task { @MainActor in self.leave(id) }
        }
        Self.lastKnown = location.coordinate
        return location
    }

    /// A cancelled call stops waiting: the permission wait gives back "not determined" (the caller then sees the
    /// cancellation), a fix wait throws. Before the wait began, it is remembered so the wait ends as it starts.
    private func leave(_ id: UUID) {
        if let cont = authorization.removeValue(forKey: id) { cont.resume(returning: .notDetermined) }
        else if let cont = fixes.removeValue(forKey: id) { cont.resume(throwing: CancellationError()) }
        else { leftEarly.insert(id) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined else { return }
            let waiting = authorization.values
            authorization = [:]
            for cont in waiting { cont.resume(returning: status) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in
            let waiting = fixes.values
            fixes = [:]
            for cont in waiting { cont.resume(returning: last) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            let waiting = fixes.values
            fixes = [:]
            for cont in waiting { cont.resume(throwing: Failure.unavailable(message)) }
        }
    }
}

/// `current_location()`: approximate coordinates and the area's name.
struct CurrentLocationTool {
    var timeout: Duration = .seconds(30)

    @MainActor
    func run() async -> ToolOutput {
        do {
            let location = try await Deadline.run(timeout, timeoutError: LocationProvider.Failure.unavailable("timed out")) {
                try await LocationProvider.shared.currentLocation()
            }
            let area = await Self.areaName(location)
            return ToolOutput(text: Self.text(lat: location.coordinate.latitude, lng: location.coordinate.longitude,
                                              accuracy: location.horizontalAccuracy, area: area))
        } catch is CancellationError {
            return ToolOutput(text: "Error: cancelled.", isError: true)
        } catch {
            return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    /// Coordinates rounded to about 100 m: enough to search nearby, no more precise than that.
    static func text(lat: Double, lng: Double, accuracy: Double, area: String?) -> String {
        var lines = [String(format: "Approximate location: lat %.3f, lng %.3f", lat, lng)]
        if accuracy > 0 { lines.append("Accuracy: about \(Int(max(100, accuracy).rounded())) m") }
        if let area, !area.isEmpty { lines.append("Area: \(area)") }
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func areaName(_ location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else { return nil }
        if let short = item.address?.shortAddress, !short.isEmpty { return short }
        return item.addressRepresentations?.cityWithContext
    }
}
