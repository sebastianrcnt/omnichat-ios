import CoreLocation
import Foundation
import Testing
@testable import Strata

struct ShowPlacesArgumentsTests {
    @Test func placesDecodeLeniently() throws {
        let args = try ShowPlacesArguments.parse("""
        {"title": " Quiet cafes ", "places": [
          {"name": "포어플랜", "category": "카페,디저트", "rating": "4.85", "reviewCount": "1,618", "lat": 37.5482007, "lng": "127.0475587",
           "placeId": 1193971273, "note": "Quiet in the morning.", "quote": "독서실처럼 조용한 분위기"},
          {"name": "티 커피", "address": "", "lat": 0, "lng": 0}
        ]}
        """)
        #expect(args.title == "Quiet cafes")
        let first = try #require(args.places.first)
        #expect(first.rating == 4.85 && first.reviewCount == 1618 && first.lat == 37.5482007 && first.lng == 127.0475587)
        #expect(first.placeId == "1193971273", "a numeric id reads as text")
        let second = args.places[1]
        #expect(second.address == nil, "blank text is dropped")
        #expect(second.lat == nil && second.lng == nil, "0,0 is no location")
    }

    @Test func placesMayArriveAsAJSONString() throws {
        let args = try ShowPlacesArguments.parse(#"{"places": "[{\"name\": \"A\"}, {\"name\": \"B\"}]"}"#)
        #expect(args.places.map(\.name) == ["A", "B"])
    }

    @Test func badArgumentsSayWhatIsWrong() {
        #expect(throws: ShowPlacesArguments.Problem.notJSON) { try ShowPlacesArguments.parse("places") }
        #expect(throws: ShowPlacesArguments.Problem.noPlaces) { try ShowPlacesArguments.parse(#"{"places": []}"#) }
        #expect(throws: ShowPlacesArguments.Problem.noPlaces) { try ShowPlacesArguments.parse(#"{"title": "x"}"#) }
        #expect(throws: ShowPlacesArguments.Problem.self) { try ShowPlacesArguments.parse(#"{"places": [{"category": "카페"}]}"#) }
    }

    @Test func atMostTwentyPlaces() throws {
        let many = (1...30).map { #"{"name": "P\#($0)"}"# }.joined(separator: ",")
        #expect(try ShowPlacesArguments.parse(#"{"places": [\#(many)]}"#).places.count == 20)
    }
}

struct NaverMapLinkTests {
    private let place = MapPlace(number: 1, input: PlaceInput(name: "조연탄 합정점", lat: 37.5501633, lng: 126.9162, placeId: "2031793748"))

    @Test func appRoutesUseNaverMapPaths() throws {
        let walk = try #require(NaverMap.appRoute(.walk, to: place)).absoluteString
        #expect(walk == "nmap://route/walk?dlat=37.5501633&dlng=126.9162000&dname=%EC%A1%B0%EC%97%B0%ED%83%84%20%ED%95%A9%EC%A0%95%EC%A0%90&appname=cc.coolservices.strata")
        #expect(NaverMap.appRoute(.transit, to: place)!.absoluteString.hasPrefix("nmap://route/public?"))
        #expect(NaverMap.appRoute(.car, to: place)!.absoluteString.hasPrefix("nmap://route/car?"))
        #expect(NaverMap.appRoute(.bike, to: place)!.absoluteString.hasPrefix("nmap://route/bicycle?"))
    }

    @Test func namesAreEscaped() throws {
        let odd = MapPlace(number: 1, input: PlaceInput(name: "A&B=C+D/E,F", lat: 37.5, lng: 127))
        let url = try #require(NaverMap.appRoute(.walk, to: odd))
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "dname" }?.value
        #expect(name == "A&B=C+D/E,F")
        let web = try #require(NaverMap.webRoute(.car, to: odd)).absoluteString
        #expect(web == "https://map.naver.com/p/directions/-/127.0000000,37.5000000,A%26B%3DC%2BD%2FE%2CF,,/-/car")
    }

    @Test func placeLinks() {
        #expect(NaverMap.appPlace(place)!.absoluteString.hasPrefix("nmap://place?lat=37.5501633&lng=126.9162000&name="))
        #expect(NaverMap.webPlace(place)!.absoluteString == "https://map.naver.com/p/entry/place/2031793748")
        #expect(NaverMap.webRoute(.transit, to: place)!.absoluteString
                == "https://map.naver.com/p/directions/-/126.9162000,37.5501633,%EC%A1%B0%EC%97%B0%ED%83%84%20%ED%95%A9%EC%A0%95%EC%A0%90,2031793748,PLACE_POI/-/transit")
        let nowhere = MapPlace(number: 2, input: PlaceInput(name: "서관면옥", address: "서울 마포구"))
        #expect(NaverMap.appRoute(.walk, to: nowhere) == nil, "no route without coordinates")
        #expect(NaverMap.appPlace(nowhere)!.absoluteString.hasPrefix("nmap://search?query="))
        #expect(NaverMap.webRoute(.walk, to: nowhere) == NaverMap.webPlace(nowhere))
        #expect(NaverMap.webPlace(nowhere)!.absoluteString.hasPrefix("https://map.naver.com/p/search/"))
    }
}

struct MapTargetTests {
    private func at(_ lat: Double, _ lng: Double, name: String = "Spot") -> MapPlace {
        MapPlace(number: 1, input: PlaceInput(name: name, lat: lat, lng: lng))
    }

    @Test func koreanCoordinatesAreInKorea() {
        // Seoul, Busan (Haeundae), Jeju, Gangneung, Ulleungdo, Dokdo, Baengnyeongdo.
        for (lat, lng) in [(37.5665, 126.978), (35.1587, 129.1604), (33.4996, 126.5312), (37.7519, 128.8761),
                           (37.4844, 130.9057), (37.2426, 131.8669), (37.9592, 124.6653)] {
            #expect(MapPlace.isInKorea(lat: lat, lng: lng), "\(lat),\(lng)")
        }
    }

    @Test func foreignCoordinatesAreNot() {
        // Atlanta, Tokyo, Fukuoka, Tsushima, Shanghai, Beijing, Sydney.
        for (lat, lng) in [(33.749, -84.388), (35.6762, 139.6503), (33.5902, 130.4017), (34.4, 129.3),
                           (31.2304, 121.4737), (39.9042, 116.4074), (-33.8688, 151.2093)] {
            #expect(!MapPlace.isInKorea(lat: lat, lng: lng), "\(lat),\(lng)")
        }
    }

    @Test func withoutCoordinatesTheModelsHintsDecide() {
        #expect(MapPlace(number: 1, input: PlaceInput(name: "서관면옥", address: "서울 마포구")).isInKorea)
        #expect(MapPlace(number: 1, input: PlaceInput(name: "Cafe", placeId: "123")).isInKorea, "a Naver Place id")
        #expect(!MapPlace(number: 1, input: PlaceInput(name: "Ponce City Market", address: "675 Ponce De Leon Ave NE, Atlanta")).isInKorea)
        // Coordinates win over a Hangul name.
        #expect(!at(33.749, -84.388, name: "애틀랜타 한식당").isInKorea)
    }

    @Test func targetFollowsThePlaceAndGoogleMaps() {
        let seoul = at(37.5665, 126.978), atlanta = at(33.749, -84.388)
        #expect(MapTarget.for(seoul, googleMapsInstalled: true) == .naver)
        #expect(MapTarget.for(seoul, googleMapsInstalled: false) == .naver)
        #expect(MapTarget.for(atlanta, googleMapsInstalled: true) == .google)
        #expect(MapTarget.for(atlanta, googleMapsInstalled: false) == .apple)
    }
}

struct GoogleAndAppleMapLinkTests {
    private let place = MapPlace(number: 1, input: PlaceInput(name: "Ponce City Market", address: "675 Ponce De Leon Ave NE",
                                                              lat: 33.7724, lng: -84.3656))

    @Test func googleRoutesUseGoogleModes() throws {
        #expect(try #require(GoogleMaps.appRoute(.walk, to: place)).absoluteString
                == "comgooglemaps://?daddr=33.7724000,-84.3656000&directionsmode=walking")
        #expect(GoogleMaps.appRoute(.transit, to: place)!.absoluteString.hasSuffix("&directionsmode=transit"))
        #expect(GoogleMaps.appRoute(.car, to: place)!.absoluteString.hasSuffix("&directionsmode=driving"))
        #expect(GoogleMaps.appRoute(.bike, to: place)!.absoluteString.hasSuffix("&directionsmode=bicycling"))
    }

    @Test func googlePlaceSearchesByNameAroundThePin() throws {
        #expect(try #require(GoogleMaps.appPlace(place)).absoluteString
                == "comgooglemaps://?q=Ponce%20City%20Market%20675%20Ponce%20De%20Leon%20Ave%20NE&center=33.7724000,-84.3656000&zoom=16")
        let nowhere = MapPlace(number: 2, input: PlaceInput(name: "A&B+C"))
        #expect(GoogleMaps.appRoute(.walk, to: nowhere) == nil, "no route without coordinates")
        let url = try #require(GoogleMaps.appPlace(nowhere))
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value == "A&B+C")
    }

    @Test func appleRoutesUseAppleModes() throws {
        #expect(try #require(AppleMaps.route(.walk, to: place)).absoluteString
                == "https://maps.apple.com/directions?destination=33.7724000,-84.3656000&mode=walking")
        #expect(AppleMaps.route(.transit, to: place)!.absoluteString.hasSuffix("&mode=transit"))
        #expect(AppleMaps.route(.car, to: place)!.absoluteString.hasSuffix("&mode=driving"))
        #expect(AppleMaps.route(.bike, to: place)!.absoluteString.hasSuffix("&mode=cycling"))
    }

    @Test func applePlaceLinks() {
        #expect(AppleMaps.place(place)!.absoluteString
                == "https://maps.apple.com/place?coordinate=33.7724000,-84.3656000&name=Ponce%20City%20Market")
        let nowhere = MapPlace(number: 2, input: PlaceInput(name: "Ponce City Market", address: "Atlanta"))
        #expect(AppleMaps.place(nowhere)!.absoluteString == "https://maps.apple.com/search?query=Ponce%20City%20Market%20Atlanta")
        #expect(AppleMaps.route(.car, to: nowhere) == AppleMaps.place(nowhere), "no route without coordinates: the search")
    }
}

private struct FakeLocator: PlaceLocating {
    var found: [String: CLLocationCoordinate2D]
    func locate(_ place: MapPlace, near: CLLocationCoordinate2D?) async -> CLLocationCoordinate2D? { found[place.name] }
}

struct ShowPlacesToolTests {
    @Test func missingCoordinatesAreLookedUp() async throws {
        let tool = ShowPlacesTool(locator: FakeLocator(found: ["B": CLLocationCoordinate2D(latitude: 37.55, longitude: 126.92)]), near: nil)
        let out = await tool.run(arguments: #"{"title": "Dinner", "places": [{"name": "A", "lat": 37.5, "lng": 127}, {"name": "B"}, {"name": "C"}]}"#)
        #expect(!out.isError)
        let places = try #require(out.places).places
        #expect(places.map(\.number) == [1, 2, 3])
        #expect(places[0].locatedOnDevice == nil && places[1].lat == 37.55 && places[1].locatedOnDevice == true)
        #expect(!places[2].hasLocation)
        #expect(out.text.contains("3 places (2 on the map)") && out.text.contains("3. C: not found on the map"))
    }

    @Test func lookupsFallBackToTheAddress() {
        let place = MapPlace(number: 1, input: PlaceInput(name: "조연탄 합정점", address: "서울 마포구 양화로8길 13"))
        #expect(MapKitPlaceLocator.queries(for: place) == ["조연탄 합정점 서울 마포구 양화로8길 13", "서울 마포구 양화로8길 13"])
        #expect(MapKitPlaceLocator.queries(for: MapPlace(number: 1, input: PlaceInput(name: "A"))) == ["A"])
    }

    @Test func badArgumentsAreAnErrorForTheModel() async {
        let out = await ShowPlacesTool(locator: FakeLocator(found: [:]), near: nil).run(arguments: #"{"places": []}"#)
        #expect(out.isError && out.places == nil)
    }

    @Test func thePlacesStayWithTheCallRecord() throws {
        var record = ToolCallRecord(id: "c", name: ToolNames.showPlaces, arguments: #"{"title":"T","places":[]}"#, result: "ok", isError: false)
        record.places = PlaceCollection(title: "T", places: [MapPlace(number: 1, input: PlaceInput(name: "A", lat: 37.5, lng: 127))])
        let decoded = try JSONDecoder().decode(ToolCallRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.places == record.places)
        #expect(record.displayOnly.places == record.places)
        let cards = ActivityFeed.cards(calls: [FeedCall(record: record)], sources: [:])
        #expect(cards.first?.kind == .places && cards.first?.places == record.places)
    }

    @Test func locationIsRoundedForTheModel() {
        let text = CurrentLocationTool.text(lat: 37.548213, lng: 127.047559, accuracy: 35, area: "성수동2가")
        #expect(text == "Approximate location: lat 37.548, lng 127.048\nAccuracy: about 100 m\nArea: 성수동2가")
    }

    @Test func locationComesOnlyWithTheBrowserTools() {
        let names = { (b: Bool, l: Bool) in ToolDefinition.available(python: false, images: false, browser: b, location: l).map(\.function.name) }
        #expect(names(true, true).contains("current_location") && names(true, true).contains("show_places"))
        #expect(!names(true, false).contains("current_location"))
        #expect(!names(false, true).contains("current_location") && !names(false, true).contains("show_places"))
    }
}
