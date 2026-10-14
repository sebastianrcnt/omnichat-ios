import SwiftUI
import MapKit
#if canImport(UIKit)
import UIKit
#endif

// The map card `show_places` puts in the chat: numbered pins over a small map, the picks as cards underneath. The map
// opens full screen with the same pins and cards; a pin or card opens the place, with the model's note and quote and
// Naver Map directions.

/// Opens a Naver Map link: the app when it is installed, otherwise the website (always the website on a Mac).
enum NaverMapOpener {
    @MainActor
    static func open(app: URL?, web: URL?, openURL: OpenURLAction) {
        #if canImport(UIKit)
        if let app, UIApplication.shared.canOpenURL(app) {
            UIApplication.shared.open(app)
            return
        }
        #endif
        if let web { openURL(web) }
    }

    @MainActor
    static func openPlace(_ place: MapPlace, openURL: OpenURLAction) {
        open(app: NaverMap.appPlace(place), web: NaverMap.webPlace(place), openURL: openURL)
    }

    @MainActor
    static func route(_ mode: NaverMap.Mode, to place: MapPlace, openURL: OpenURLAction) {
        open(app: NaverMap.appRoute(mode, to: place), web: NaverMap.webRoute(mode, to: place), openURL: openURL)
    }
}

extension MapPlace {
    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// "카페,디저트 · ★ 4.9 (1,618)".
    var subtitle: String {
        var parts: [String] = []
        if let category, !category.isEmpty { parts.append(category) }
        if let rating {
            let stars = "★ " + rating.formatted(.number.precision(.fractionLength(0...2)))
            parts.append(reviewCount.map { stars + " (\($0.formatted()))" } ?? stars)
        } else if let reviewCount {
            parts.append(String(localized: "\(reviewCount.formatted()) reviews"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Pins

/// A numbered pin.
struct PlacePin: View {
    @Environment(\.theme) private var theme
    let number: Int
    var selected = false

    var body: some View {
        Text(verbatim: "\(number)")
            .font(DS.Typography.chipInline.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(theme.onAccent)
            .frame(width: selected ? 30 : 24, height: selected ? 30 : 24)
            .background(theme.accent, in: Circle())
            .overlay { Circle().strokeBorder(Color.white, lineWidth: 2) }
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .animation(DS.Motion.snappy, value: selected)
            .accessibilityHidden(true)
    }
}

/// The places with coordinates as pins on a map.
struct PlacesMap: View {
    let places: [MapPlace]
    var selected: Int?
    var interactive = false
    var onSelect: (MapPlace) -> Void = { _ in }
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position, interactionModes: interactive ? .all : []) {
            ForEach(places.filter(\.hasLocation)) { place in
                Annotation(place.name, coordinate: place.coordinate!, anchor: .center) {
                    PlacePin(number: place.number, selected: selected == place.number)
                        .onTapGesture { onSelect(place) }
                }
                .annotationTitles(interactive ? .automatic : .hidden)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }
}

// MARK: - Place cards

/// One pick: number, name, category and rating, the model's note and the review it quoted.
struct PlaceCard: View {
    @Environment(\.theme) private var theme
    let place: MapPlace
    var width: CGFloat = 248

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs + 2) {
            HStack(spacing: DS.Spacing.sm) {
                PlacePin(number: place.number).scaleEffect(0.85)
                Text(place.name)
                    .font(DS.Typography.feedEmphasis)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }
            if !place.subtitle.isEmpty {
                Text(place.subtitle).font(DS.Typography.feedMeta).foregroundStyle(theme.textSecondary).lineLimit(1)
            }
            if let note = place.note {
                Text(note).font(DS.Typography.feed).foregroundStyle(theme.textPrimary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let quote = place.quote {
                PlaceQuote(text: quote, lineLimit: 2)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.md)
        .frame(width: width, alignment: .topLeading)
        .frame(minHeight: 120, alignment: .topLeading)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.cardRow + 2, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.cardRow + 2, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A review excerpt with the quote bar.
struct PlaceQuote: View {
    @Environment(\.theme) private var theme
    let text: String
    var lineLimit: Int?

    var body: some View {
        Text(verbatim: "“\(text)”")
            .font(DS.Typography.feed)
            .italic()
            .foregroundStyle(theme.textSecondary)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, DS.Spacing.sm + 2)
            .overlay(alignment: .leading) { Rectangle().fill(theme.accent.opacity(0.6)).frame(width: 2) }
    }
}

/// The cards side by side, scrolling sideways.
struct PlaceCardStrip: View {
    let places: [MapPlace]
    var cardWidth: CGFloat = 248
    let onSelect: (MapPlace) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                ForEach(places) { place in
                    Button { onSelect(place) } label: { PlaceCard(place: place, width: cardWidth) }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Shows the place and directions"))
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
    }
}

// MARK: - The card in the chat

/// The `show_places` card in the feed. Never folds: it is the result, not a step.
struct PlacesFeedCard: View {
    @Environment(\.theme) private var theme
    let card: FeedCard
    var onDetails: () -> Void
    @State private var showMap = false
    @State private var detail: MapPlace?

    static let mapHeight: CGFloat = 190

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let places = card.places?.places, !card.isRunning {
                if places.contains(where: \.hasLocation) {
                    Button { showMap = true } label: {
                        PlacesMap(places: places)
                            .allowsHitTesting(false)
                            .frame(height: Self.mapHeight)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.cardRow + 2, style: .continuous))
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                                    .frame(width: 30, height: 30)
                                    .glassEffect(.regular, in: Circle())
                                    .padding(DS.Spacing.sm)
                            }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .accessibilityLabel(Text("Map of \(places.count) places"))
                    .accessibilityHint(Text("Opens the map full screen"))
                }
                PlaceCardStrip(places: places) { detail = $0 }
                    .contentMargins(.horizontal, 10, for: .scrollContent)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(theme.separator, lineWidth: 1)
        }
        .contextMenu {
            Button("Show Timeline", systemImage: "list.bullet.below.rectangle", action: onDetails)
        }
        .placesMapPresentation(isPresented: $showMap, collection: card.places)
        .sheet(item: $detail) { PlaceDetailSheet(place: $0) }
    }

    private var title: String {
        if card.isRunning { return String(localized: "Finding places on the map…") }
        if card.isError { return String(localized: "Couldn't show the places") }
        if let title = card.places?.title { return title }
        let n = card.places?.places.count ?? 0
        return n == 1 ? String(localized: "1 place") : String(localized: "\(n) places")
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "map")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 18)
            Text(title)
                .font(DS.Typography.feedEmphasis)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: DS.Spacing.sm)
            if card.isRunning {
                ProgressView().controlSize(.mini)
            } else if let places = card.places?.places, places.count > 1 {
                Text(places.count == 1 ? String(localized: "1 place") : String(localized: "\(places.count) places"))
                    .font(DS.Typography.feedMeta).foregroundStyle(theme.textTertiary)
                    .opacity(card.places?.title == nil ? 0 : 1)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
    }
}

// MARK: - Full-screen map

extension View {
    /// The full-screen map: a cover on a phone, a sheet on a Mac.
    func placesMapPresentation(isPresented: Binding<Bool>, collection: PlaceCollection?) -> some View {
        fullScreenCoverOrSheet(isPresented: isPresented) { if let collection { PlacesMapSheet(collection: collection) } }
    }
}

/// The map edge to edge with the pins, the cards along the bottom; a pin or a card opens the place.
struct PlacesMapSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let collection: PlaceCollection
    @State private var selected: Int?
    @State private var detail: MapPlace?

    var body: some View {
        ZStack(alignment: .top) {
            PlacesMap(places: collection.places, selected: selected, interactive: true) { open($0) }
                .ignoresSafeArea()
            HStack {
                GlassIconButton(systemName: "xmark", label: "Close") { dismiss() }
                Spacer()
                if let title = collection.title {
                    Text(title)
                        .font(DS.Typography.uiEmphasis)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .padding(.horizontal, DS.Spacing.lg)
                        .frame(height: DS.IconSize.controlDiameter)
                        .glassEffect(.regular, in: Capsule())
                }
                Spacer()
                Color.clear.frame(width: DS.IconSize.controlDiameter, height: DS.IconSize.controlDiameter)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.top, DS.Spacing.sm)
        }
        .safeAreaInset(edge: .bottom) {
            PlaceCardStrip(places: collection.places, cardWidth: 272) { open($0) }
                .contentMargins(.horizontal, DS.Spacing.lg, for: .scrollContent)
                .padding(.vertical, DS.Spacing.md)
                .background(theme.background.opacity(0.92))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: DS.Radius.lg, topTrailingRadius: DS.Radius.lg))
        }
        .background(theme.background.ignoresSafeArea())
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 820, minHeight: 520, idealHeight: 680)
        .background { Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) }
        #endif
        .sheet(item: $detail) { PlaceDetailSheet(place: $0) }
        .inAppLinks()
    }

    private func open(_ place: MapPlace) {
        selected = place.number
        detail = place
    }
}

// MARK: - One place

/// A place: what it is, why the model picked it, the review it quoted, and the ways to get there.
struct PlaceDetailSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    let place: MapPlace

    var body: some View {
        SheetScaffold(title: "Place") {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                HStack(spacing: DS.Spacing.sm) {
                    PlacePin(number: place.number)
                    Text(place.name).font(DS.Typography.largeTitle).foregroundStyle(theme.textPrimary)
                }
                if !place.subtitle.isEmpty {
                    Text(place.subtitle).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                }
                if let address = place.address {
                    Label { Text(address) } icon: { Image(systemName: "mappin.and.ellipse") }
                        .font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                        .textSelection(.enabled)
                }
            }
            if place.note != nil || place.quote != nil {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    if let note = place.note {
                        Text(note).font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let quote = place.quote { PlaceQuote(text: quote) }
                }
                .padding(DS.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
            }
            if place.hasLocation {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text("Directions").font(DS.Typography.sectionHeader).foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, DS.Spacing.xs)
                    HStack(spacing: DS.Spacing.sm) {
                        ForEach(NaverMap.Mode.allCases) { mode in
                            Button { NaverMapOpener.route(mode, to: place, openURL: openURL) } label: {
                                VStack(spacing: DS.Spacing.xs) {
                                    Image(systemName: mode.systemImage).font(.system(size: DS.IconSize.md))
                                    Text(mode.label).font(DS.Typography.uiCaption)
                                }
                                .foregroundStyle(theme.textPrimary)
                                .frame(maxWidth: .infinity, minHeight: 60)
                                .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
                                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Directions by \(mode.label)"))
                        }
                    }
                }
            }
            Button { NaverMapOpener.openPlace(place, openURL: openURL) } label: {
                Label("Open in Naver Map", systemImage: "map.fill")
                    .font(DS.Typography.uiEmphasis)
                    .foregroundStyle(theme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: DS.Radius.md))
                    .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
            }
            .buttonStyle(.plain)
            if place.locatedOnDevice == true {
                Text("Placed on the map by name; the pin may be approximate.")
                    .font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Previews

#Preview("Dark · Purple") { placesPreview.previewStyle(.dark) }
#Preview("Light · Purple") { placesPreview.previewStyle(.light) }
#Preview("Dark · Orange") { placesPreview.previewStyle(.dark, accent: Color(hex: "#F97316")) }

@MainActor private var placesPreview: some View {
    var card = FeedCard(id: "p", kind: .places)
    card.places = PlaceCollection(title: "Quiet cafes in Seongsu", places: [
        MapPlace(number: 1, input: PlaceInput(name: "포어플랜", category: "카페,디저트", rating: 4.85, reviewCount: 689,
                                              address: "서울 성동구 왕십리로14길 30-11", lat: 37.5482, lng: 127.0476, placeId: "1193971273",
                                              note: "Library-quiet in the morning, outlets at every table.",
                                              quote: "아침 시간이라 그런지 전체적으로 독서실처럼 조용한 분위기")),
        MapPlace(number: 2, input: PlaceInput(name: "서울북카페 센버스", category: "북카페", rating: 5, reviewCount: 886,
                                              lat: 37.5446, lng: 127.0557, note: "A book cafe with soft classical music.")),
        MapPlace(number: 3, input: PlaceInput(name: "티 커피", category: "카페", rating: 4.98, reviewCount: 327, lat: 37.5465, lng: 127.0436)),
    ])
    return ScrollView {
        PlacesFeedCard(card: card, onDetails: {}).padding()
    }
}
