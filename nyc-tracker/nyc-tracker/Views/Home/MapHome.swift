import SwiftUI
import SwiftData
import MapKit

/// The map, showing either the user's own visits or their friends' — never both.
///
/// ## Two data sources, one pin set
///
/// Own visits come from SwiftData and are the only pins in `.mine`, which is
/// what keeps that mode useful offline. Friend visits come from
/// `visits_in_bounds` through `FriendVisitCache`, which is in-memory and never
/// writes to the local store. Switching to "all friends" or one friend drops
/// your own pins so the map is actually theirs.
///
/// `MapPlaceGrouping` still merges onto one annotation per place, joining on
/// `Place.remotePlaceID`, so four friends at the same restaurant is one pin.
struct MapHome: View {
    @Binding var openedVisit: Visit?
    /// Set from outside (e.g. "View on Map" in the write-up) to recenter the
    /// camera on a visit. Cleared once handled.
    @Binding var focusVisitID: Visit.ID?
    /// Live query from the expanded search bar in `HomeView`. Non-empty text
    /// filters logged pins; when nothing in the log matches, Apple Maps
    /// suggestions appear as their own pins.
    @Binding var searchQuery: String
    /// Set when the user asks to search Apple Maps despite having local matches.
    @Binding var includeAppleMapsSearch: Bool
    /// Written for `HomeView` so it knows when to offer the other-locations prompt.
    @Binding var hasLocalSearchMatches: Bool
    @Bindable var filter: EntryFilter
    /// Start the capture flow at a venue tapped on the map. Handled up in
    /// `ContentView` — photos are still required, so this only hands off the venue.
    var onLogVisit: (VenueCandidate) -> Void
    /// Save a venue tapped on the map as a want-to-try immediately.
    var onWantToTry: (VenueCandidate) -> Void
    private let userID: UUID

    @Environment(SocialGraph.self) private var graph
    @Environment(MapAudienceStore.self) private var audienceStore
    @Environment(FriendVisitCache.self) private var friendCache
    @Environment(WishlistStore.self) private var wishlist
    @Environment(AppRouter.self) private var router
    @Environment(FeedStore.self) private var feed
    @Environment(SocialStatsCache.self) private var socialStats

    /// The map's one sheet slot.
    ///
    /// A single enum rather than two `.sheet(item:)` modifiers on the same view:
    /// stacking sheet modifiers on one view is unreliable — the second can
    /// silently win — and a single slot also makes it impossible to ask for two
    /// at once.
    private enum MapSheet: Identifiable {
        /// A pin with visits behind it. Held as a key, not a group, so the sheet
        /// re-derives its contents if the underlying visits change.
        case place(PlaceKey)
        /// The signed-in user's own visit write-up. Held as an id so the sheet
        /// can re-fetch the SwiftData row rather than capturing a model object
        /// from a Map annotation tap — that path crashed the presenter.
        case ownVisit(UUID)
        /// A single friend's visit — full write-up, same shell as `.ownVisit`.
        case friendVisit(FriendVisit)
        /// A wishlist pin — somewhere with no visits yet.
        case wishlistPlace(PlaceSummary)
        /// An Apple Maps point of interest the user tapped directly on the
        /// base map — not one of our own pins. The candidate lives in
        /// `tappedVenue` so the sheet can appear on the tap and fill in
        /// address / POI id without remounting.
        case tappedFeature

        var id: String {
            switch self {
            case .place(.remote(let id)):     return "place-r-\(id.uuidString)"
            case .place(.local(let id)):      return "place-l-\(id.uuidString)"
            case .ownVisit(let id):           return "own-\(id.uuidString)"
            case .friendVisit(let visit):     return "fvisit-\(visit.id.uuidString)"
            case .wishlistPlace(let place):   return "wishlist-\(place.id.uuidString)"
            case .tappedFeature:              return "tapped-feature"
            }
        }
    }

    /// What to do once the tapped-feature sheet has actually finished
    /// dismissing. Held rather than acted on immediately: presenting the photo
    /// picker (or saving) while this view's own sheet is still animating away
    /// is the same race `ContentView` avoids for the search sheet — a second
    /// presentation stacked on a disappearing one can end up undismissable.
    private enum PendingVenueAction {
        case logVisit(VenueCandidate)
        case wantToTry(VenueCandidate)
    }

    /// Scoped to the signed-in user. The predicate is built in `init` because a
    /// `@Query` default can't reference an instance property.
    @Query private var visits: [Visit]

    init(
        userID: UUID,
        openedVisit: Binding<Visit?>,
        focusVisitID: Binding<Visit.ID?>,
        searchQuery: Binding<String>,
        includeAppleMapsSearch: Binding<Bool>,
        hasLocalSearchMatches: Binding<Bool>,
        filter: EntryFilter,
        onLogVisit: @escaping (VenueCandidate) -> Void,
        onWantToTry: @escaping (VenueCandidate) -> Void
    ) {
        _openedVisit = openedVisit
        _focusVisitID = focusVisitID
        _searchQuery = searchQuery
        _includeAppleMapsSearch = includeAppleMapsSearch
        _hasLocalSearchMatches = hasLocalSearchMatches
        self.filter = filter
        self.onLogVisit = onLogVisit
        self.onWantToTry = onWantToTry
        self.userID = userID
        _visits = Query(
            filter: LocalStore.visitsPredicate(for: userID),
            sort: [
                SortDescriptor(\Visit.visitedOn, order: .reverse),
                // Upload order breaks a tie. A user backfilling several
                // places to the same day would otherwise get an order
                // SwiftData is free to change between launches.
                SortDescriptor(\Visit.createdAt, order: .reverse)
            ]
        )
    }

    /// Commissioners' Plan of 1811: Manhattan avenues run ~29° east of true north.
    /// Heading the camera that way makes the "vertical" streets run up the screen.
    private static let manhattanGridHeading: Double = 29
    private static let nycCenter = CLLocationCoordinate2D(latitude: 40.7300, longitude: -73.9950)

    @State private var camera: MapCameraPosition = .camera(
        MapCamera(
            centerCoordinate: nycCenter,
            distance: 28_000,
            heading: manhattanGridHeading,
            pitch: 0
        )
    )

    @State private var visibleRegion: MKCoordinateRegion?
    /// The camera as of the last gesture, kept so the reset-orientation button
    /// can rebuild it with only the heading changed — a reset that also moved
    /// or zoomed the map would be a second, unasked-for change.
    @State private var lastCamera: MapCamera?
    @State private var presentedSheet: MapSheet?
    /// The Apple Maps POI currently selected on the base map, if any. Only
    /// ever set by a tap on the map itself — our own pins are plain buttons
    /// inside `Annotation`, not `Marker`s, so they never populate this.
    @State private var selectedFeature: MapFeature?
    @State private var tappedVenue: VenueCandidate?
    /// Drops a stale `MKMapItemRequest` if the user taps another POI before
    /// the previous lookup finishes.
    @State private var tappedFeatureToken = UUID()
    @State private var pendingVenueAction: PendingVenueAction?
    @State private var placeSearch = PlaceCompletionSearch()
    @State private var searchVenuePins: [VenueCandidate] = []
    @State private var searchResolveToken = UUID()
    @State private var appleSearchBounds: MKCoordinateRegion?

    /// Cap the completer bias so a city-wide map does not query the continent.
    private static let minAutoSearchSpan: Double = 0.01
    private static let maxAutoSearchSpan: Double = 0.28
    /// Radius for the explicit "Search other locations" expansion — wide enough
    /// to surface nearby Apple Maps matches without leaving the metro area.
    private static let expandedAppleSearchMeters: Double = 5_000

    private static var defaultSearchRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.7300, longitude: -73.9950),
            span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
        )
    }

    private var audience: MapAudience { audienceStore.audience }

    private var trimmedSearchQuery: String { VisitSearch.trimmed(searchQuery) }
    private var isSearchActive: Bool { !trimmedSearchQuery.isEmpty }

    // MARK: - Derived data

    private var ownVisits: [Visit] {
        guard audience == .mine else { return [] }
        return visits.filter(filter.matches)
    }

    private var friendVisits: [FriendVisit] {
        guard audience.requiresNetwork else { return [] }
        // `visits_in_bounds` with a nil user list includes the caller. Drop those
        // so "all friends" is actually friends-only.
        return friendCache.visits
            .filter { $0.userID != userID }
            .filter(filter.matches)
    }

    private var unfilteredPlaceGroups: [MapPlaceGroup] {
        MapPlaceGrouping.groups(ownVisits: ownVisits, friendVisits: friendVisits)
    }

    private var placeGroups: [MapPlaceGroup] {
        guard isSearchActive else { return unfilteredPlaceGroups }
        guard !includeAppleMapsSearch else { return [] }
        return unfilteredPlaceGroups.filter { VisitSearch.matches($0, query: trimmedSearchQuery) }
    }

    private var localSearchMatches: [MapPlaceGroup] {
        guard isSearchActive else { return [] }
        return unfilteredPlaceGroups.filter { VisitSearch.matches($0, query: trimmedSearchQuery) }
    }

    private var showsAppleMapsSearchPins: Bool {
        isSearchActive && (includeAppleMapsSearch || localSearchMatches.isEmpty)
    }

    private var searchCompletionSignature: String {
        placeSearch.results.map(\.title).joined(separator: "|")
    }

    private func group(for key: PlaceKey) -> MapPlaceGroup? {
        placeGroups.first { $0.key == key }
    }

    /// Unresolved wishlist places, minus any that already have a pin.
    ///
    /// The subtraction matters: once a wishlist item resolves, the same venue is
    /// also a real visit, and drawing both would put an "intention" pin directly
    /// on top of a "memory" pin at identical coordinates. Resolved items are
    /// excluded by `wishlist.active`; this also drops anything a visit pin
    /// already covers, which catches the moment between capturing a visit and
    /// the wishlist reloading.
    private var wishlistPins: [WishlistEntry] {
        guard audience == .mine, wishlist.showsOnMap, !isSearchActive else { return [] }
        let pinnedPlaceIDs = Set(placeGroups.compactMap { group -> UUID? in
            if case .remote(let id) = group.key { return id }
            return nil
        })
        return wishlist.active.filter { !pinnedPlaceIDs.contains($0.place.id) }
    }

    /// Everything except tilt.
    ///
    /// Tilt is the gesture that made pinch unreliable: it reads a two-finger
    /// drag, so a pinch whose fingers travelled further than they separated —
    /// most of them — was claimed as a tilt and the map lurched instead of
    /// zooming. Nothing here wants a tilted camera anyway (every `MapCamera` in
    /// this file is built at pitch 0, and `MapPitchToggle` is hidden), so it was
    /// costing a gesture and buying nothing. Rotation stays: a twist and a
    /// spread are different enough shapes to coexist, which is why Apple Maps
    /// keeps both.
    private static let interactions: MapInteractionModes = [.pan, .zoom, .rotate]

    var body: some View {
        Map(
            position: $camera,
            interactionModes: Self.interactions,
            selection: $selectedFeature
        ) {
            // Blue "you are here" dot + heading arrow.
            UserAnnotation()

            ForEach(placeGroups) { group in
                Annotation(
                    group.name,
                    coordinate: group.coordinate,
                    anchor: .center
                ) {
                    PlacePin(group: group) {
                        Haptics.tap()
                        open(group)
                    }
                }
            }

            ForEach(wishlistPins) { entry in
                Annotation(
                    entry.place.name,
                    coordinate: CLLocationCoordinate2D(
                        latitude: entry.place.latitude,
                        longitude: entry.place.longitude
                    ),
                    anchor: .center
                ) {
                    WishlistPin(entry: entry) {
                        Haptics.tap()
                        presentedSheet = .wishlistPlace(entry.place)
                    }
                }
            }

            if showsAppleMapsSearchPins {
                ForEach(searchVenuePins) { venue in
                    Annotation(venue.name, coordinate: venue.coordinate, anchor: .center) {
                        SearchVenuePin {
                            Haptics.tap()
                            tappedVenue = venue
                            presentedSheet = .tappedFeature
                        }
                    }
                }
            }
        }
        // Flat rather than realistic: a 3D camera makes pinch-zoom a change of
        // camera *distance* over terrain, which reads as sticky near the ground
        // and is what the tilt gesture hangs off. The pitch is pinned to 0
        // everywhere in this file, so the elevation was buying rendering cost
        // and gesture ambiguity and no visible depth. Apple Maps out of the box
        // is this same flat 2D camera.
        .mapStyle(.standard(elevation: .flat))
        // We show our own detail card (`PlaceActionSheet`) for a tapped POI
        // instead of Apple's built-in callout, so there is one place — not
        // two — that offers "Log a visit".
        .mapFeatureSelectionAccessory(nil)
        // Neighborhood and city labels are territorial features, not venues.
        // Without this, tapping "Williamsburg" opens the same log / want-to-try
        // card as tapping a restaurant pin on the base map.
        .mapFeatureSelectionDisabled { feature in
            feature.kind != .pointOfInterest
        }
        // An empty `.mapControls {}` still lets MapKit auto-show the compass
        // (this camera sits 29° off north) and a location button. Naming each
        // control and hiding it replaces those defaults. The blue
        // `UserAnnotation` dot is the only location chrome that stays.
        .mapControlVisibility(.hidden)
        .mapControls {
            MapUserLocationButton()
                .mapControlVisibility(.hidden)
            MapCompass()
                .mapControlVisibility(.hidden)
            MapPitchToggle()
                .mapControlVisibility(.hidden)
            MapScaleView()
                .mapControlVisibility(.hidden)
        }
        .task {
            // Request When-In-Use permission the first time the map appears.
            _ = await LocationProvider.shared.currentLocation()
        }
        // `.onEnd` rather than `.continuous`: a pan is one event on release
        // instead of one per frame, which is the first half of not hammering the
        // API. The second half is the 350ms debounce inside `FriendVisitCache`,
        // which coalesces several quick gestures into one request.
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
            lastCamera = context.camera
            requestFriendVisits(for: context.region)
        }
        .onChange(of: selectedFeature) { _, newValue in
            resolveTappedFeature(newValue)
        }
        .onChange(of: searchQuery) { _, newValue in
            handleSearchQueryChange(newValue)
            syncLocalSearchMatchBinding()
        }
        .onChange(of: includeAppleMapsSearch) { _, included in
            guard included, isSearchActive else { return }
            beginAppleMapsSearch(expanded: true)
        }
        .onChange(of: unfilteredPlaceGroups.count) { _, _ in
            syncLocalSearchMatchBinding()
        }
        .onChange(of: audience) { _, _ in
            syncLocalSearchMatchBinding()
        }
        .onAppear {
            syncLocalSearchMatchBinding()
        }
        .task(id: searchCompletionSignature) {
            guard showsAppleMapsSearchPins else { return }
            resolveSearchCompletions(placeSearch.results)
        }
        .safeAreaInset(edge: .top) {
            // Reserve room for the floating controls above.
            Color.clear.frame(height: 52)
        }
        .overlay(alignment: .top) { statusStrip }
        .overlay(alignment: .bottomTrailing) { resetHeadingButton }
        .overlay(alignment: .center) { audienceEmptyState }
        .animation(.snappy, value: presentedSheet?.id)
        .animation(.snappy, value: lastCamera?.heading)
        .animation(.snappy, value: placeGroups.map(\.id))
        .animation(.snappy, value: searchVenuePins.map(\.id))
        // Switching audience invalidates the fetched set immediately, so a mode
        // change never leaves the previous mode's pins on screen while the new
        // request is in flight.
        .onChange(of: audience) { _, newValue in
            presentedSheet = nil
            if newValue.requiresNetwork {
                friendCache.invalidateCoverage()
                if let visibleRegion { requestFriendVisits(for: visibleRegion) }
            } else {
                friendCache.clearResults()
            }
        }
        // Unfriending while looking at that friend's map: the selection resets to
        // "mine" and the pins clear, rather than leaving orphaned pins for
        // someone who is no longer a friend.
        .onChange(of: graph.friendIDs) { _, ids in
            let didReset = audienceStore.reconcile(
                against: ids,
                hasLoadedGraph: graph.hasLoaded
            )
            if didReset {
                presentedSheet = nil
                friendCache.clearResults()
            } else if audience.requiresNetwork {
                // Still a valid mode, but the friend set changed — refetch so an
                // unfriended person's pins leave "all friends".
                friendCache.invalidateCoverage()
                if let visibleRegion { requestFriendVisits(for: visibleRegion) }
            }
        }
        .task(id: focusVisitID) {
            guard let id = focusVisitID else { return }
            defer { focusVisitID = nil }
            guard let visit = visits.first(where: { $0.id == id }), let place = visit.place else {
                return
            }
            withAnimation(.easeInOut(duration: 0.6)) {
                camera = .camera(MapCamera(
                    centerCoordinate: place.coordinate,
                    distance: 900,
                    heading: Self.manhattanGridHeading,
                    pitch: 0
                ))
            }
            // Pan only — the write-up the user just left shouldn't reopen.
        }
        .sheet(item: $presentedSheet, onDismiss: handleSheetDismissed) { sheet in
            mapSheet(sheet)
                .environment(graph)
                .environment(friendCache)
                .environment(feed)
                .environment(socialStats)
                .environment(router)
                .environment(wishlist)
        }
    }

    @ViewBuilder
    private func mapSheet(_ sheet: MapSheet) -> some View {
        switch sheet {
        case .wishlistPlace(let place):
            RecommendedPlaceSheet(place: place)

        case .ownVisit(let id):
            if let visit = visits.first(where: { $0.id == id }) {
                NavigationStack {
                    ReadOnlyWriteUpView(
                        visit: visit,
                        onDismiss: { presentedSheet = nil },
                        onShowOnMap: { presentedSheet = nil }
                    )
                    .flatModalToolbarBackground()
                }
                .flatModalBackground()
            } else {
                MissingPlaceSheet()
            }

        case .friendVisit(let visit):
            NavigationStack {
                FriendVisitWriteUpView(
                    visit: visit,
                    onDismiss: { presentedSheet = nil },
                    onShowOnMap: { presentedSheet = nil }
                )
                .flatModalToolbarBackground()
            }
            .flatModalBackground()

        case .place(let key):
            if let group = group(for: key) {
                PlaceDetailSheet(group: group) { visit in
                    presentedSheet = nil
                    openedVisit = visit
                }
            } else {
                // The place stopped existing under us — an unfriend, or a
                // filter change that excluded it. Say so rather than showing
                // a blank sheet.
                MissingPlaceSheet()
            }

        case .tappedFeature:
            TappedFeatureActionSheet(
                venue: $tappedVenue,
                onLogVisit: { venue in
                    pendingVenueAction = .logVisit(venue)
                    presentedSheet = nil
                },
                onWantToTry: { venue in
                    pendingVenueAction = .wantToTry(venue)
                    presentedSheet = nil
                }
            )
        }
    }

    /// Show the card on the same turn as the tap. `MapFeature` already has
    /// name, category, and coordinate — enough for the sheet. Address and the
    /// Apple POI identifier come from `MKMapItemRequest` and fill in after,
    /// without remounting. The feature stays selected so MapKit can finish
    /// growing the place icon instead of being cleared mid-animation.
    private func resolveTappedFeature(_ feature: MapFeature?) {
        guard let feature else { return }
        guard feature.kind == .pointOfInterest else {
            selectedFeature = nil
            return
        }
        let token = UUID()
        tappedFeatureToken = token
        tappedVenue = VenueCandidate(feature: feature)
        presentedSheet = .tappedFeature

        Task {
            guard let item = try? await MKMapItemRequest(feature: feature).mapItem,
                  tappedFeatureToken == token
            else { return }
            tappedVenue = .from(mapItem: item)
        }
    }

    /// Runs once the tapped-feature sheet has actually finished animating
    /// away — the photo picker cannot open until the sheet has landed.
    private func handleSheetDismissed() {
        selectedFeature = nil
        tappedVenue = nil
        guard let action = pendingVenueAction else { return }
        pendingVenueAction = nil
        switch action {
        case .logVisit(let venue):   onLogVisit(venue)
        case .wantToTry(let venue):  onWantToTry(venue)
        }
    }

    /// Own map: the write-up for the latest visit. A single friend visit: their
    /// visit details. Several people at one pin: the place sheet.
    ///
    /// Presented from this view's sheet, not `openedVisit` on the parent — a
    /// Map annotation setting an ancestor's sheet during the tap gesture
    /// crashed the presenter.
    private func open(_ group: MapPlaceGroup) {
        if audience == .mine, let visit = group.ownVisits.first {
            presentedSheet = .ownVisit(visit.id)
        } else if group.friendVisits.count == 1, let visit = group.friendVisits.first {
            presentedSheet = .friendVisit(visit)
        } else {
            presentedSheet = .place(group.key)
        }
    }

    // MARK: - Fetching

    private func requestFriendVisits(for region: MKCoordinateRegion) {
        guard audience.requiresNetwork else { return }
        friendCache.request(bounds: GeoBounds(region: region), audience: audience)
    }

    // MARK: - Map search

    private func handleSearchQueryChange(_ query: String) {
        let trimmed = VisitSearch.trimmed(query)
        searchVenuePins = []
        appleSearchBounds = nil

        guard !trimmed.isEmpty else {
            placeSearch.update(query: "")
            return
        }

        if includeAppleMapsSearch {
            beginAppleMapsSearch()
            return
        }

        let matching = localSearchMatches
        if !matching.isEmpty {
            placeSearch.update(query: "")
            fitCamera(to: matching.map(\.coordinate))
            return
        }

        beginAppleMapsSearch(zoomOutIfTight: true)
    }

    private func clampedSearchRegion(from region: MKCoordinateRegion) -> MKCoordinateRegion {
        var copy = region
        copy.span.latitudeDelta = min(
            max(copy.span.latitudeDelta, Self.minAutoSearchSpan),
            Self.maxAutoSearchSpan
        )
        copy.span.longitudeDelta = min(
            max(copy.span.longitudeDelta, Self.minAutoSearchSpan),
            Self.maxAutoSearchSpan
        )
        return copy
    }

    private func expandedAppleSearchRegion(around center: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: center,
            latitudinalMeters: Self.expandedAppleSearchMeters * 2,
            longitudinalMeters: Self.expandedAppleSearchMeters * 2
        )
    }

    private func appleMapsSearchCenter() -> CLLocationCoordinate2D {
        visibleRegion?.center
            ?? localSearchMatches.first?.coordinate
            ?? Self.defaultSearchRegion.center
    }

    private func currentSearchRegion() -> MKCoordinateRegion {
        clampedSearchRegion(from: visibleRegion ?? Self.defaultSearchRegion)
    }

    private func contains(_ coordinate: CLLocationCoordinate2D, in region: MKCoordinateRegion) -> Bool {
        let latHalf = region.span.latitudeDelta / 2
        let lngHalf = region.span.longitudeDelta / 2
        return abs(coordinate.latitude - region.center.latitude) <= latHalf
            && abs(coordinate.longitude - region.center.longitude) <= lngHalf
    }

    private func beginAppleMapsSearch(expanded: Bool = false, zoomOutIfTight: Bool = false) {
        searchVenuePins = []

        let wideRegion = expandedAppleSearchRegion(around: appleMapsSearchCenter())
        let region: MKCoordinateRegion
        if expanded || (zoomOutIfTight && isViewportTighter(than: wideRegion)) {
            region = wideRegion
            zoomCamera(to: region)
        } else {
            region = currentSearchRegion()
        }

        appleSearchBounds = region
        placeSearch.setRegion(region)
        placeSearch.update(query: trimmedSearchQuery)
    }

    /// True when the map is zoomed in closer than the Apple Maps search disc.
    private func isViewportTighter(than region: MKCoordinateRegion) -> Bool {
        guard let visible = visibleRegion else { return true }
        return visible.span.latitudeDelta < region.span.latitudeDelta
            || visible.span.longitudeDelta < region.span.longitudeDelta
    }

    private func zoomCamera(to region: MKCoordinateRegion) {
        withAnimation(.smooth(duration: 1.0)) {
            camera = .region(region)
        }
    }

    private func syncLocalSearchMatchBinding() {
        let matches = !localSearchMatches.isEmpty
        if hasLocalSearchMatches != matches {
            hasLocalSearchMatches = matches
        }
    }

    private func resolveSearchCompletions(_ completions: [MKLocalSearchCompletion]) {
        let bounds = appleSearchBounds ?? currentSearchRegion()
        let token = UUID()
        searchResolveToken = token
        let top = Array(completions.prefix(5))

        Task {
            var resolved: [VenueCandidate] = []
            for completion in top {
                guard searchResolveToken == token else { return }
                guard let candidate = await PlaceCompletionSearch.resolve(completion, in: bounds),
                      contains(candidate.coordinate, in: bounds)
                else { continue }
                resolved.append(candidate)
            }
            guard searchResolveToken == token else { return }
            searchVenuePins = resolved
        }
    }

    private func fitCamera(to coordinates: [CLLocationCoordinate2D]) {
        guard let first = coordinates.first else { return }

        if coordinates.count == 1 {
            withAnimation(.easeInOut(duration: 0.5)) {
                camera = .camera(MapCamera(
                    centerCoordinate: searchFitCenter(
                        first,
                        headingDegrees: Self.manhattanGridHeading
                    ),
                    distance: 1_200,
                    heading: Self.manhattanGridHeading,
                    pitch: 0
                ))
            }
            return
        }

        var minLat = first.latitude
        var maxLat = first.latitude
        var minLng = first.longitude
        var maxLng = first.longitude
        for coordinate in coordinates.dropFirst() {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLng = min(minLng, coordinate.longitude)
            maxLng = max(maxLng, coordinate.longitude)
        }

        let latDelta = max((maxLat - minLat) * 1.5, 0.008)
        let lngDelta = max((maxLng - minLng) * 1.5, 0.008)
        let center = searchFitCenter(
            CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLng + maxLng) / 2
            ),
            headingDegrees: 0,
            spanLatitude: latDelta
        )
        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lngDelta)
        )

        withAnimation(.easeInOut(duration: 0.5)) {
            camera = .region(region)
        }
    }

    /// Shift the camera center slightly along screen-down so matched pins sit
    /// higher — clearing the floating search bar. Uses map heading so a rotated
    /// grid does not drift the pin sideways.
    private func searchFitCenter(
        _ coordinate: CLLocationCoordinate2D,
        headingDegrees: Double,
        spanLatitude: Double? = nil
    ) -> CLLocationCoordinate2D {
        let heading = headingDegrees * .pi / 180
        let latitudeRadians = coordinate.latitude * .pi / 180
        let offsetMeters = spanLatitude.map { $0 * 111_320 * 0.08 } ?? 100
        let metersNorth = -offsetMeters * cos(heading)
        let metersEast = -offsetMeters * sin(heading)

        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + metersNorth / 111_320,
            longitude: coordinate.longitude + metersEast / (111_320 * cos(latitudeRadians))
        )
    }

    // MARK: - Orientation

    /// How far the camera can drift from the grid before the map counts as
    /// rotated. A degree of slack: a two-finger pinch nudges the heading by a
    /// fraction of a degree, and a button that appears every time you zoom is
    /// worse than no button.
    private static let headingSlack: Double = 1

    /// Shortest distance from the grid heading, so a camera at 28° reads as 1°
    /// off rather than 359°.
    private func degreesOffGrid(_ heading: Double) -> Double {
        let delta = abs(heading - Self.manhattanGridHeading)
            .truncatingRemainder(dividingBy: 360)
        return delta > 180 ? 360 - delta : delta
    }

    /// Rotate back to the street grid.
    ///
    /// Only on screen once the map is actually rotated — the camera starts on
    /// the grid, so a permanent control would spend most of its life saying
    /// "nothing to do" while covering the map. This is what Apple's `MapCompass`
    /// would otherwise do, and the reason it isn't that: the compass snaps to
    /// true north, and north is the one orientation this map deliberately isn't
    /// in. The needle points at the grid rather than at north for the same
    /// reason — it shows where a tap will take you.
    @ViewBuilder
    private var resetHeadingButton: some View {
        if let lastCamera, degreesOffGrid(lastCamera.heading) > Self.headingSlack {
            Button {
                Haptics.tap()
                withAnimation(.easeInOut(duration: 0.35)) {
                    camera = .camera(MapCamera(
                        centerCoordinate: lastCamera.centerCoordinate,
                        distance: lastCamera.distance,
                        heading: Self.manhattanGridHeading,
                        pitch: 0
                    ))
                }
            } label: {
                Image(systemName: "location.north.line.fill")
                    .font(.subheadline.weight(.semibold))
                    .rotationEffect(.degrees(Self.manhattanGridHeading - lastCamera.heading))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Align the map to the street grid")
            .padding(.trailing, 16)
            // Clears the floating dock, which cancels the home-indicator inset
            // and sits `bottomPadding` above the physical screen bottom.
            .padding(.bottom, BottomNavBar.barHeight + BottomNavBar.bottomPadding + 12)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    // MARK: - Status

    /// Non-blocking status. Sits above the map and never covers it modally — a
    /// spinner that freezes the map while a fetch is in flight is worse than
    /// slightly stale pins, because panning is how you ask for the next fetch.
    @ViewBuilder
    private var statusStrip: some View {
        VStack(spacing: 6) {
            if audience.requiresNetwork, let failure = friendCache.failure {
                statusPill(
                    symbol: failure == .offline ? "wifi.slash" : "exclamationmark.triangle",
                    text: failure.message,
                    tint: .orange
                ) {
                    guard let visibleRegion else { return }
                    Task { await friendCache.reload(bounds: GeoBounds(region: visibleRegion), audience: audience) }
                }
            } else if audience.requiresNetwork && friendCache.isLoading {
                statusPill(symbol: nil, text: "Loading friends' places…", tint: .secondary, action: nil)
            } else if audience.requiresNetwork && friendCache.isTruncated {
                statusPill(
                    symbol: "line.3.horizontal.decrease.circle",
                    text: "Showing the most recent. Zoom in for more.",
                    tint: .secondary,
                    action: nil
                )
            }
        }
        // Clears the floating toggle/filter/search row (8 top inset + 52 toggle,
        // plus breathing room).
        .padding(.top, 112)
        .padding(.horizontal, 16)
        .animation(.snappy, value: friendCache.isLoading)
        .animation(.snappy, value: friendCache.failure)
    }

    @ViewBuilder
    private func statusPill(
        symbol: String?,
        text: String,
        tint: Color,
        action: (() -> Void)?
    ) -> some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).font(.caption.weight(.semibold))
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(text)
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.leading)
            if action != nil {
                Text("Retry")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .onTapGesture { action?() }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// "All friends" with no friends is not an empty map, it's a missing
    /// prerequisite — so it points at the place you'd go to fix it.
    @ViewBuilder
    private var audienceEmptyState: some View {
        if audience == .allFriends, graph.hasLoaded, graph.friends.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "person.2.slash")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No friends yet")
                    .font(.headline)
                Text("Add friends to see where they've been.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Haptics.tap()
                    router.activeTab = .friends
                } label: {
                    Label("Add friends", systemImage: "person.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 8)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.glassProminent)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .transition(.opacity)
        } else if case .friend(let id) = audience,
                  graph.hasLoaded,
                  friendCache.visits.filter({ $0.userID != userID }).isEmpty,
                  !friendCache.isLoading,
                  friendCache.failure == nil {
            // A real friend who simply hasn't logged anything in view. Named, so
            // it doesn't read as a loading failure.
            let name = graph.friend(withID: id)?.person.shortName ?? "They"
            Text("\(name) hasn't logged anywhere around here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(16)
                .frame(maxWidth: 300)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .transition(.opacity)
        } else if audience == .allFriends,
                  graph.hasLoaded,
                  !graph.friends.isEmpty,
                  friendCache.visits.filter({ $0.userID != userID }).isEmpty,
                  !friendCache.isLoading,
                  friendCache.failure == nil {
            Text("None of your friends have logged anywhere around here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(16)
                .frame(maxWidth: 300)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .transition(.opacity)
        }
    }
}

// MARK: - Pins

private extension View {
    /// A pin's tap target — a tap gesture over a circle, deliberately not a
    /// `Button`.
    ///
    /// A button has to track the press for the life of the touch in order to
    /// draw a pressed state, so a finger that lands on a pin as a pinch begins
    /// is already spoken for and MapKit is left watching a one-finger drag. A
    /// `TapGesture` releases the touch the moment it moves, so the pinch
    /// survives. The circular shape keeps the target on the pin rather than the
    /// corners of its bounding box, which belong to the map.
    func mapPinTapTarget(_ action: @escaping () -> Void) -> some View {
        frame(width: 40, height: 40)
            .contentShape(Circle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }
}

/// One place. Own-only pins take the accent colour; anything with a friend in it
/// takes that friend's palette colour, so "whose is that" is answerable without
/// tapping.
private struct PlacePin: View {
    let group: MapPlaceGroup
    var onTap: () -> Void

    private var tint: Color {
        if group.isOwnOnly { return .accentColor }
        guard let first = group.friendIDs.first else { return .accentColor }
        // Mixed pins (you + a friend, or several friends) take the first
        // friend's colour and wear a count badge; trying to blend several
        // colours produces mud.
        return FriendPalette.color(for: first)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Circle()
                    .fill(tint)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
            // A white ring on your own pins is the second, colour-blind-safe
            // channel for "this one is mine".
            .overlay {
                if group.hasOwnVisit {
                    Circle().strokeBorder(.white, lineWidth: 2.5)
                }
            }

            if group.friendIDs.count > 1 {
                Text("\(group.friendIDs.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(Color.black.opacity(0.75)))
                    .offset(x: 5, y: -4)
            }
        }
        .mapPinTapTarget(onTap)
        .accessibilityLabel(accessibilityLabel)
    }

    private var symbol: String {
        if group.isWantToTryOnly { return "bookmark.fill" }
        switch group.category {
        case .restaurant: return "fork.knife"
        case .bar:        return "wineglass.fill"
        case .cafe:       return "cup.and.saucer.fill"
        case .bakery:     return "birthday.cake.fill"
        case .other:      return "mappin"
        }
    }

    private var accessibilityLabel: String {
        var parts = [group.name]
        if group.hasOwnVisit { parts.append("your visit") }
        if !group.friendIDs.isEmpty {
            parts.append(pluralized(group.friendIDs.count, "friend"))
        }
        return parts.joined(separator: ", ")
    }
}

/// A place from Apple Maps that matched the search but isn't in the user's log
/// yet. Hollow and neutral so it reads as "new" rather than "yours".
private struct SearchVenuePin: View {
    var onTap: () -> Void

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            Circle()
                .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1.5)
            Image(systemName: "mappin")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 32, height: 32)
        .mapPinTapTarget(onTap)
        .accessibilityLabel("New place from Apple Maps")
    }
}

/// Somewhere the user means to go.
///
/// Deliberately unlike a visit pin: hollow rather than filled, dashed rather
/// than solid, and a bookmark rather than a category glyph. A wishlist pin is an
/// intention, not a memory, and the map is unreadable if the two look alike —
/// the whole value of glancing at it is knowing which places you've actually
/// been to.
private struct WishlistPin: View {
    let entry: WishlistEntry
    var onTap: () -> Void

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(uiColor: .systemBackground).opacity(0.92))
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            Circle()
                .strokeBorder(
                    Color.blue,
                    style: StrokeStyle(lineWidth: 2, dash: [3, 2.5])
                )
            Image(systemName: "bookmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.blue)
        }
        .frame(width: 28, height: 28)
        .mapPinTapTarget(onTap)
        .accessibilityLabel(
            entry.recommenders.isEmpty
                ? "\(entry.place.name), on your wishlist"
                : "\(entry.place.name), on your wishlist, recommended by \(entry.recommenders.attributionText ?? "a friend")"
        )
    }
}

/// `MapFeature` is a SwiftUI type, so this stays next to the map rather than
/// on `VenueCandidate` in `LocationResolver` (which only imports MapKit).
private extension VenueCandidate {
    /// Enough to show a card on the same turn as a map tap. Address and the
    /// Apple POI identifier arrive a moment later via `from(mapItem:)`.
    init(feature: MapFeature) {
        self.init(
            id: "feature-\(feature.coordinate.latitude)-\(feature.coordinate.longitude)",
            name: feature.title ?? "Unknown",
            category: PlaceCategory.from(poi: feature.pointOfInterestCategory),
            coordinate: feature.coordinate,
            address: nil,
            externalPOIId: nil
        )
    }
}

/// Reads `tappedVenue` live so the card can appear on the tap and pick up
/// address / POI id when `MKMapItemRequest` finishes, without remounting.
private struct TappedFeatureActionSheet: View {
    @Binding var venue: VenueCandidate?
    var onLogVisit: (VenueCandidate) -> Void
    var onWantToTry: (VenueCandidate) -> Void

    var body: some View {
        if let candidate = venue {
            PlaceActionSheet(
                candidate: candidate,
                onLogVisit: { if let venue { onLogVisit(venue) } },
                onWantToTry: { if let venue { onWantToTry(venue) } }
            )
        } else {
            MissingPlaceSheet()
        }
    }
}

/// Shown when the selected place vanishes while its sheet is open.
private struct MissingPlaceSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("This place is no longer shown")
                .font(.headline)
            Text("It may have been filtered out, or you're no longer friends with the person who logged it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .buttonStyle(.glass)
                .padding(.top, 4)
        }
        .padding(32)
        .presentationDetents([.medium])
    }
}
