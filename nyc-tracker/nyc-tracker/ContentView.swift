//
//  ContentView.swift
//  nyc-tracker
//

import SwiftUI
import SwiftData
import PhotosUI

struct ContentView: View {
    /// The signed-in user every query below is scoped to. Passed explicitly from
    /// `RootView` rather than read from the environment because the scoped
    /// `@Query` declarations need it in `init`, before the environment is
    /// available.
    let userID: UUID

    @Environment(SocialGraph.self) private var graph
    @Environment(ChatStore.self) private var chat
    @Environment(SyncEngine.self) private var sync
    @Environment(\.modelContext) private var modelContext

    /// Owns the active tab and home mode. An observable rather than `@State`
    /// because "View on map" on a friend's profile has to change the tab from
    /// several levels down a navigation stack.
    @State private var router = AppRouter()

    /// Which friends' places the map is showing. Persisted per user, so it
    /// survives launches, and created here so it dies with the signed-in user.
    @State private var mapAudience = MapAudienceStore()

    /// Friend visits for the map. In-memory only — deliberately NOT SwiftData,
    /// which is the signed-in user's own mirror.
    @State private var friendVisits = FriendVisitCache()

    /// The wishlist. Server-backed rather than mirrored: a wishlist item is a
    /// pointer someone else can create while the app is closed, not something
    /// the user authored offline.
    @State private var wishlist = WishlistStore()

    /// The explore feed's pagination state.
    @State private var feed = FeedStore()

    /// Short-TTL cache for the server-side aggregates ("3 friends have been
    /// here", places in common, the gap list).
    @State private var socialStats = SocialStatsCache()

    @State private var openedVisit: Visit?
    @State private var mapFocusVisitID: Visit.ID?

    @State private var captureCoordinator = CaptureCoordinator()
    @State private var filter = EntryFilter()

    /// Bindings that drive the "log a visit" and "want to try" entry points.
    @State private var showPhotosPicker = false
    @State private var pickerSelection: [PhotosPickerItem] = []

    /// The "+" menu's one sheet slot.
    ///
    /// A single enum rather than a `Bool` per destination, for the reason
    /// `MapHome.MapSheet` spells out: two `.sheet(isPresented:)` modifiers on one
    /// view is the arrangement where the second can silently win, and one slot
    /// also makes it impossible to ask for both at once.
    private enum EntrySheet: String, Identifiable {
        case wantToTry
        case placeSearch

        var id: String { rawValue }
    }

    @State private var entrySheet: EntrySheet?

    /// A venue picked out of Apple Maps that is on its way into the capture
    /// flow. Held here rather than passed straight through because the photo
    /// picker has to open first, and it cannot open until the search sheet has
    /// finished dismissing.
    @State private var pendingVenue: VenueCandidate?

    private let enricher: EnricherProtocol = FoundationModelsEnricher()

    /// The map is a full-bleed canvas under the glass. Other pages stay full
    /// height too; they only add bottom safe-area padding so the last row can
    /// scroll clear of the dock. Chat hides the dock, so it needs no clearance.
    private var showsFullBleedMap: Bool {
        router.activeTab == .home && router.homeMode == .map
    }

    private var showsBottomBar: Bool {
        !router.hidesBottomBar
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch router.activeTab {
                case .home:
                    HomeView(
                        userID: userID,
                        mode: Binding(
                            get: { router.homeMode },
                            set: { router.homeMode = $0 }
                        ),
                        openedVisit: $openedVisit,
                        focusVisitID: $mapFocusVisitID,
                        filter: filter
                    )
                case .discover:
                    DiscoverView()
                case .friends:
                    FriendsView(userID: userID)
                case .profile:
                    ProfileView(userID: userID, openedVisit: $openedVisit, filter: filter)
                }
            }
            // Inset scroll/list content so the last row can clear the dock, but
            // keep each page full-bleed so the glass sits on the page instead of
            // a solid strip behind the bar.
            .safeAreaPadding(.bottom, (showsFullBleedMap || !showsBottomBar) ? 0 : BottomNavBar.contentClearance)

            if showsBottomBar {
                BottomNavBar(
                    activeTab: router.activeTab,
                    // Incoming friend requests plus unread messages.
                    friendsBadgeCount: graph.incoming.count + chat.unreadCount,
                    onMap: { router.showMap() },
                    onDiscover: { router.activeTab = .discover },
                    onFriends: { router.activeTab = .friends },
                    onLogVisit: {
                        pickerSelection = []
                        showPhotosPicker = true
                    },
                    onWantToTry: { entrySheet = .wantToTry },
                    onFindPlace: { entrySheet = .placeSearch },
                    onProfile: { router.activeTab = .profile }
                )
                // Slide the bar itself, not the full-height container below —
                // a move transition travels the height of the view it's on.
                .transition(.move(edge: .bottom).combined(with: .opacity))
                // Pin the dock to the physical bottom while a text field is
                // focused. `.ignoresSafeArea(.keyboard)` only helps a view that
                // wants the extra room, and the bar is content-sized, so on its
                // own it kept riding up with the ZStack as the keyboard shrank
                // it. The full-height container is what actually claims the
                // space under the keyboard; the bar bottom-aligns inside it.
                // Empty space in that frame isn't hit-testable, so the page
                // underneath still takes taps, and pages keep their own keyboard
                // avoidance because only this branch ignores the inset.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(.keyboard, edges: .bottom)
            }
        }
        .animation(.smooth(duration: 0.28), value: showsBottomBar)
        .environment(router)
        .environment(mapAudience)
        .environment(friendVisits)
        .environment(wishlist)
        .environment(feed)
        .environment(socialStats)
        // All per-user. Configured here — inside the subtree that `RootView`
        // rebuilds on `profile.id` — so none of them can carry one account's
        // state into the next.
        .task(id: userID) {
            graph.configure(userID: userID)
            chat.configure(userID: userID)
            mapAudience.configure(userID: userID)
            wishlist.configure(userID: userID)
            feed.configure(userID: userID)
        }
        // Every aggregate in the cache is scoped to the friend set, so a
        // friendship change makes all of them suspect at once.
        .onChange(of: graph.friendIDs) { _, _ in
            socialStats.invalidateAll()
            feed.refresh()
        }
        // Wishlist resolution happens in a Postgres trigger, which fires when the
        // visit reaches the server — not when it is captured. So the signal to
        // re-read the wishlist is "a sync completed", not "a capture finished".
        // Refreshing at capture time would ask before the trigger had run and
        // show the item still unresolved.
        .onChange(of: sync.lastSyncedAt) { _, _ in
            wishlist.refresh()
            // The user's own visits changed, so "places friends have been that
            // you haven't" has too.
            socialStats.invalidateAll()
        }
        // Photos picker sheet fires directly — no more placeholder screen in front of it.
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $pickerSelection,
            maxSelectionCount: 8,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: showPhotosPicker) { _, isShown in
            // When the picker closes with photos selected, start the capture flow.
            // Backing out of the picker cancels the entry — a visit needs at least
            // one photo — and that includes discarding any venue the user had
            // chosen on the way in.
            guard !isShown else { return }
            if !pickerSelection.isEmpty {
                captureCoordinator.begin(with: pickerSelection, venue: pendingVenue)
                pickerSelection = []
            }
            pendingVenue = nil
        }
        .sheet(item: $entrySheet) { sheet in
            switch sheet {
            case .wantToTry:
                WantToTryView(userID: userID)
            case .placeSearch:
                PlaceSearchView(
                    onLogVisit: { venue in pendingVenue = venue },
                    onWantToTry: { venue in saveWantToTry(venue) }
                )
            }
        }
        // The picker is opened here rather than from inside the search sheet:
        // presenting it while that sheet is still dismissing gives a picker
        // stacked on a disappearing presenter, which on device ends up
        // undismissable. Waiting for the dismissal to land avoids the race.
        .onChange(of: entrySheet) { _, sheet in
            guard sheet == nil, pendingVenue != nil else { return }
            pickerSelection = []
            showPhotosPicker = true
        }
        .fullScreenCover(isPresented: bindingForCapture()) {
            CaptureFlowView(
                userID: userID,
                coordinator: captureCoordinator,
                enricher: enricher,
                onConfirmedVisit: { visit in
                    openedVisit = nil
                    router.showMap()
                    mapFocusVisitID = visit.id
                }
            )
        }
        .sheet(item: $openedVisit) { visit in
            NavigationStack {
                ReadOnlyWriteUpView(
                    visit: visit,
                    onDismiss: { openedVisit = nil },
                    onShowOnMap: {
                        let id = visit.id
                        openedVisit = nil
                        router.showMap()
                        mapFocusVisitID = id
                    }
                )
                .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            }
            .presentationBackground(Color(uiColor: .systemBackground))
            // Sheets don't always inherit `@State` Observable values injected
            // on the presenter; VisitFriendsSection needs these explicitly.
            .environment(graph)
            .environment(friendVisits)
            .environment(feed)
            .environment(socialStats)
            .environment(router)
        }
    }

    /// Save a want-to-try straight from an Apple Maps result, then show it.
    ///
    /// No sheet, no confirmation step: everything the entry holds — name,
    /// coordinate, category, address — came from the venue the user just tapped,
    /// so there is nothing left to ask them. Panning the map to the new pin is
    /// the receipt.
    private func saveWantToTry(_ venue: VenueCandidate) {
        Task {
            let described = await LocationResolver.describe(coordinate: venue.coordinate)
            let repository = VisitRepository(context: modelContext, userID: userID)
            let visit = repository.insertWantToTry(
                from: venue,
                neighborhood: described.neighborhood
            )
            Haptics.success()
            sync.requestSync(reason: .newLocalWrite)

            openedVisit = nil
            router.showMap()
            mapFocusVisitID = visit.id
        }
    }

    private func bindingForCapture() -> Binding<Bool> {
        Binding(
            get: { captureCoordinator.isPresented },
            set: { captureCoordinator.isPresented = $0 }
        )
    }
}

#Preview {
    ContentView(userID: UUID())
        .modelContainer(LocalStore.shared)
        .environment(AuthManager())
        .environment(SyncEngine())
        .environment(SocialGraph())
        .environment(ChatStore())
        .environment(SocialDemoMode.shared)
}
