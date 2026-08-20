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
    @Bindable var filter: EntryFilter
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
        /// A single friend's visit — Explore-style, no save/send chrome.
        case friendVisit(FriendVisit)
        /// A wishlist pin — somewhere with no visits yet.
        case wishlistPlace(PlaceSummary)

        var id: String {
            switch self {
            case .place(.remote(let id)):     return "place-r-\(id.uuidString)"
            case .place(.local(let id)):      return "place-l-\(id.uuidString)"
            case .ownVisit(let id):           return "own-\(id.uuidString)"
            case .friendVisit(let visit):     return "fvisit-\(visit.id.uuidString)"
            case .wishlistPlace(let place):   return "wishlist-\(place.id.uuidString)"
            }
        }
    }

    /// Scoped to the signed-in user. The predicate is built in `init` because a
    /// `@Query` default can't reference an instance property.
    @Query private var visits: [Visit]

    init(
        userID: UUID,
        openedVisit: Binding<Visit?>,
        focusVisitID: Binding<Visit.ID?>,
        filter: EntryFilter
    ) {
        _openedVisit = openedVisit
        _focusVisitID = focusVisitID
        self.filter = filter
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
    @State private var presentedSheet: MapSheet?

    private var audience: MapAudience { audienceStore.audience }

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

    private var placeGroups: [MapPlaceGroup] {
        MapPlaceGrouping.groups(ownVisits: ownVisits, friendVisits: friendVisits)
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
        guard audience == .mine, wishlist.showsOnMap else { return [] }
        let pinnedPlaceIDs = Set(placeGroups.compactMap { group -> UUID? in
            if case .remote(let id) = group.key { return id }
            return nil
        })
        return wishlist.active.filter { !pinnedPlaceIDs.contains($0.place.id) }
    }

    var body: some View {
        Map(position: $camera) {
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
        }
        .mapStyle(.standard(elevation: .realistic))
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
            requestFriendVisits(for: context.region)
        }
        .safeAreaInset(edge: .top) {
            // Reserve room for the floating controls above.
            Color.clear.frame(height: 52)
        }
        .overlay(alignment: .top) { statusStrip }
        .overlay(alignment: .center) { audienceEmptyState }
        .animation(.snappy, value: presentedSheet?.id)
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
        .sheet(item: $presentedSheet) { sheet in
            mapSheet(sheet)
                .environment(graph)
                .environment(friendCache)
                .environment(feed)
                .environment(socialStats)
                .environment(router)
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
                    .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
                    .toolbarBackgroundVisibility(.visible, for: .navigationBar)
                }
                .presentationBackground(Color(uiColor: .systemBackground))
            } else {
                MissingPlaceSheet()
            }

        case .friendVisit(let visit):
            FriendVisitDetailSheet(visit: visit)

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
        Button(action: onTap) {
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
        }
        .buttonStyle(.plain)
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
        Button(action: onTap) {
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
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            entry.recommenders.isEmpty
                ? "\(entry.place.name), on your wishlist"
                : "\(entry.place.name), on your wishlist, recommended by \(entry.recommenders.attributionText ?? "a friend")"
        )
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
