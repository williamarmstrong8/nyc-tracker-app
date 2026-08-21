import SwiftUI
import SwiftData
import CoreLocation

// ============================================================================
// The social layer that hangs off a place: who's been, who sent it to you, and
// the two things you can do about it.
// ============================================================================
// Extracted rather than written twice. A place is reachable from a map pin
// (`PlaceDetailSheet`), from the inbox and explore feed (`RecommendedPlaceSheet`,
// which now builds the same group), and from a wishlist row. They differ in
// what surrounds them, not in what "3 friends have been here" means.
// ============================================================================

/// Friends who have been here, plus anyone who recommended it to you.
///
/// Both come from `place_social` in one call, behind a 60-second TTL — a friend
/// count does not change per render, and a place sheet opened and reopened
/// shouldn't pay for the same aggregate three times.
struct PlaceSocialSection: View {
    let placeID: UUID

    @Environment(SocialStatsCache.self) private var stats

    @State private var social: PlaceSocial?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let social, social.friendPlaceCount > 0 {
                friendsRow(social)
            }
            if let social, !social.recommenders.isEmpty {
                recommendersRow(social.recommenders)
            }
            if isLoading && social == nil {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: placeID) {
            // Paint from cache first so a reopened sheet has no spinner at all.
            social = stats.cachedPlaceSocial(placeID)
            guard social == nil else { return }
            isLoading = true
            social = await stats.placeSocial(placeID)
            isLoading = false
        }
    }

    private func friendsRow(_ social: PlaceSocial) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: -8) {
                ForEach(social.friends.prefix(4)) { visitor in
                    PersonAvatar(person: visitor.person, size: 28, showsPaletteRing: true)
                        .overlay(
                            Circle().stroke(
                                Color(uiColor: .systemBackground),
                                lineWidth: 2
                            )
                        )
                }
            }
            // Distinct friends, not total visits: one friend who goes weekly is
            // one friend, and the other number would read as a popularity score
            // it isn't.
            Text("\(pluralized(social.friendPlaceCount, "friend")) \(social.friendPlaceCount == 1 ? "has" : "have") been here")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func recommendersRow(_ recommenders: [Recommender]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "quote.bubble.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text("\(recommenders.attributionText ?? "Someone") recommended this")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
            }

            ForEach(recommenders) { recommender in
                if let message = recommender.message, !message.isEmpty {
                    Text("\u{201C}\(message)\u{201D} — \(recommender.person.shortName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Friends at this place, on the user's own visit write-up.
///
/// One row per friend who has been — avatar and their note — with the first
/// three shown and a See more control when there are more. No count summary
/// and no toggle: friends' notes live here, not as a duplicated body above.
struct VisitFriendsSection: View {
    let placeID: UUID
    var latitude: Double?
    var longitude: Double?

    private static let previewLimit = 3

    @Environment(SocialStatsCache.self) private var stats
    @Environment(FriendVisitCache.self) private var friendCache
    @Environment(FeedStore.self) private var feed
    @Environment(AuthManager.self) private var auth
    @Environment(SocialGraph.self) private var graph

    @State private var entries: [FriendPlaceNote] = []
    @State private var isLoading = false
    @State private var showAll = false

    private var visibleEntries: [FriendPlaceNote] {
        showAll ? entries : Array(entries.prefix(Self.previewLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !entries.isEmpty {
                ForEach(visibleEntries) { entry in
                    friendNoteRow(entry)
                }
                if entries.count > Self.previewLimit && !showAll {
                    Button {
                        Haptics.tap()
                        withAnimation(.snappy) { showAll = true }
                    } label: {
                        Text("See more")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            } else if isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: placeID) {
            await load()
        }
    }

    private func friendNoteRow(_ entry: FriendPlaceNote) -> some View {
        HStack(alignment: .top, spacing: 10) {
            PersonAvatar(person: entry.person, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.person.bestName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let body = entry.body, !body.isEmpty {
                    Text(body)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func load() async {
        isLoading = entries.isEmpty
        defer { isLoading = false }

        async let socialTask = stats.placeSocial(placeID)
        let visits = await loadFriendVisits()
        let social = await socialTask

        entries = Self.mergedEntries(
            visits: visits,
            visitors: social?.friends ?? []
        )
    }

    private func loadFriendVisits() async -> [FriendVisit] {
        var seed: [FriendVisit] = []
        let friendIDs = graph.friendIDs
        if let latitude, let longitude, !friendIDs.isEmpty {
            let pad = 0.01
            if let fetched = try? await FriendshipService.visitsInBounds(
                minLat: latitude - pad,
                maxLat: latitude + pad,
                minLng: longitude - pad,
                maxLng: longitude + pad,
                userIDs: friendIDs,
                limit: 80
            ) {
                seed = fetched
            }
        }

        let ownID = auth.state.profile?.id
        return SocialPlaceVisits.collected(
            placeID: placeID,
            seed: seed,
            cache: friendCache,
            feed: feed
        ).filter { $0.userID != ownID }
    }

    /// One row per friend who has been. Prefer their visit note when we have
    /// one; otherwise fall back to a bare avatar + name from `place_social`.
    private static func mergedEntries(
        visits: [FriendVisit],
        visitors: [PlaceVisitor]
    ) -> [FriendPlaceNote] {
        var byUser: [UUID: FriendPlaceNote] = [:]
        var order: [UUID] = []

        func upsert(_ note: FriendPlaceNote, preferBody: Bool) {
            if let existing = byUser[note.id] {
                if preferBody,
                   (existing.body == nil || existing.body?.isEmpty == true),
                   let body = note.body, !body.isEmpty {
                    byUser[note.id] = note
                }
            } else {
                byUser[note.id] = note
                order.append(note.id)
            }
        }

        for visit in visits.sorted(by: { $0.visitedAt > $1.visitedAt }) {
            let body = visit.summary?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            upsert(
                FriendPlaceNote(
                    id: visit.userID,
                    person: visit.person,
                    body: (body?.isEmpty == false) ? body : nil,
                    sortDate: visit.visitedAt
                ),
                preferBody: true
            )
        }

        for visitor in visitors {
            upsert(
                FriendPlaceNote(
                    id: visitor.id,
                    person: visitor.person,
                    body: nil,
                    sortDate: nil
                ),
                preferBody: false
            )
        }

        return order.compactMap { byUser[$0] }
            .sorted { lhs, rhs in
                switch (lhs.sortDate, rhs.sortDate) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return false
                }
            }
    }
}

private struct FriendPlaceNote: Identifiable {
    let id: UUID
    var person: PersonSummary
    var body: String?
    var sortDate: Date?
}

/// Save-to-wishlist and send-to-friend.
///
/// Both act on a place rather than a visit, which is why they live together —
/// they are the two things you can do about somewhere you have not been.
struct PlaceActionsRow: View {
    let place: PlaceSummary
    /// The place's hero photo, if one is already on screen — carried into the
    /// send sheet so it can show the same image instead of a bare icon.
    var photo: PhotoView.Source? = nil
    var unsavedSaveLabel: String = "Save"
    var savedSaveLabel: String = "Saved"

    @State private var showSendSheet = false

    var body: some View {
        HStack(spacing: 10) {
            WantToTryButton(
                place: place,
                unsavedLabel: unsavedSaveLabel,
                savedLabel: savedSaveLabel,
                minHeight: 44,
                prominentWhenUnsaved: true
            )

            Button {
                Haptics.tap()
                showSendSheet = true
            } label: {
                Label("Send", systemImage: "paperplane")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glass)
        }
        .sheet(isPresented: $showSendSheet) {
            SendPlaceSheet(place: place, photo: photo)
        }
    }
}

/// The wishlist toggle half of `PlaceActionsRow`, on its own — for surfaces
/// that want just the save action and not the send button alongside it (a
/// friend's write-up ends with this single button, the same way your own
/// ends with a single Send button).
struct WantToTryButton: View {
    let place: PlaceSummary
    /// When saving from a friend's write-up, copy their photos and note into the
    /// local mirror so the saved row matches the standard visit modal.
    var sourceVisit: FriendVisit? = nil
    var unsavedLabel: String = "Want to try"
    var savedLabel: String = "Saved"
    /// 48 matches `ReadOnlyWriteUpView`'s standalone Send button; `PlaceActionsRow`
    /// passes 44 to line up with the Send button sharing its row.
    var minHeight: CGFloat = 48
    /// Own-visit's Send button is always `.glass`, never prominent — matched
    /// here by default so the two full-screen write-ups end the same way.
    /// `PlaceActionsRow` opts into the louder unsaved state instead, since
    /// there it's sharing the row with a second, lower-priority action.
    var prominentWhenUnsaved: Bool = false

    @Environment(WishlistStore.self) private var wishlist
    @Environment(SocialStatsCache.self) private var stats
    @Environment(\.modelContext) private var modelContext
    @Environment(AuthManager.self) private var auth
    @Environment(SyncEngine.self) private var sync

    @State private var isSaving = false

    private var savedEntry: WishlistEntry? { wishlist.entry(forPlace: place.id) }
    private var isSaved: Bool { savedEntry != nil }

    /// See `WantToTryMirror`: a save has to land in the local Want to try list
    /// too, or it never shows up anywhere the user looks.
    private var mirror: WantToTryMirror? {
        guard let userID = auth.state.profile?.id else { return nil }
        return WantToTryMirror(context: modelContext, userID: userID)
    }

    var body: some View {
        // Written as an if/else rather than a ternary over two button styles:
        // `buttonStyle` is generic over the style type, so the two branches
        // have different types and a ternary doesn't type-check.
        if !isSaved && prominentWhenUnsaved {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }

    private var button: some View {
        Button {
            Haptics.tap()
            Task { await toggleSaved() }
        } label: {
            Label(
                isSaved ? savedLabel : unsavedLabel,
                systemImage: isSaved ? "bookmark.fill" : "bookmark"
            )
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .opacity(isSaving ? 0 : 1)
            .overlay { if isSaving { ProgressView().controlSize(.small) } }
        }
        .disabled(isSaving)
    }

    private func toggleSaved() async {
        isSaving = true
        defer { isSaving = false }

        if let savedEntry {
            let removed = await wishlist.remove(itemID: savedEntry.id)
            if removed { mirror?.removeMirror(placeID: place.id) }
        } else {
            let saved = await wishlist.add(placeID: place.id)
            if saved { await mirror?.mirror(place, from: sourceVisit) }
        }
        sync.requestSync(reason: .newLocalWrite)
        // The user's own action — must be reflected immediately rather than
        // waiting out the stats TTL.
        stats.invalidate(placeID: place.id)
    }
}

/// A place opened from the inbox, explore feed, wishlist, or a gap row.
///
/// Same sheet as tapping a map pin: photos, tags, friend visits, and the note
/// someone sent with it — for a pin with more than one visit behind it. A
/// saved place backed by exactly one friend visit and nothing of the user's
/// own skips straight to that friend's full write-up instead, the same
/// one-visit shortcut `MapHome.open(_:)` takes for a map pin. Without it this
/// sheet showed the place header and then, underneath, a second smaller
/// card repeating the same photo and name — `PlaceDetailSheet`'s
/// `FriendVisitCard` row, built for stacking several visits, looking odd as
/// the only one.
struct RecommendedPlaceSheet: View {
    let place: PlaceSummary
    var seedVisits: [FriendVisit] = []
    /// When set, load this person's visits at `place` if the seed/cache don't
    /// already have them — typical for an inbox row that only carried the venue.
    var senderID: UUID? = nil
    var recommendationNote: PlaceRecommendationNote? = nil
    var onOpenOwnVisit: (Visit) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(AuthManager.self) private var auth
    @Environment(FriendVisitCache.self) private var friendCache
    @Environment(FeedStore.self) private var feed
    @Environment(\.dismiss) private var dismiss

    @State private var fetchedVisits: [FriendVisit] = []

    private var group: MapPlaceGroup {
        MapPlaceGroup(
            key: .remote(place.id),
            name: place.name,
            category: place.category,
            coordinate: CLLocationCoordinate2D(
                latitude: place.latitude,
                longitude: place.longitude
            ),
            ownVisits: ownVisits,
            friendVisits: mergedFriendVisits
        )
    }

    /// Nothing of the user's own here, exactly one friend's visit, and no
    /// recommendation note to show above it (only `PlaceDetailSheet` renders
    /// that banner) — the same condition under which a map pin skips the
    /// place sheet entirely and opens the visit itself.
    private var soleFriendVisit: FriendVisit? {
        guard recommendationNote == nil, group.ownVisits.isEmpty else { return nil }
        return mergedFriendVisits.count == 1 ? mergedFriendVisits.first : nil
    }

    var body: some View {
        Group {
            if let visit = soleFriendVisit {
                NavigationStack {
                    FriendVisitWriteUpView(visit: visit, onDismiss: { dismiss() })
                        .flatModalToolbarBackground()
                }
                .flatModalBackground()
            } else {
                PlaceDetailSheet(
                    group: group,
                    onOpenOwnVisit: onOpenOwnVisit,
                    recommendationNote: recommendationNote
                )
            }
        }
        .task { await loadSenderVisitsIfNeeded() }
    }

    private var mergedFriendVisits: [FriendVisit] {
        SocialPlaceVisits.collected(
            placeID: place.id,
            seed: seedVisits + fetchedVisits,
            cache: friendCache,
            feed: feed
        )
    }

    private var ownVisits: [Visit] {
        guard let userID = auth.state.profile?.id else { return [] }
        let predicate = LocalStore.visitsPredicate(for: userID)
        let descriptor = FetchDescriptor<Visit>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\Visit.visitedOn, order: .reverse),
                SortDescriptor(\Visit.createdAt, order: .reverse)
            ]
        )
        let visits = (try? modelContext.fetch(descriptor)) ?? []
        return visits.filter { $0.place?.remotePlaceID == place.id }
    }

    private func loadSenderVisitsIfNeeded() async {
        guard let senderID else { return }
        if mergedFriendVisits.contains(where: { $0.userID == senderID }) { return }
        do {
            let visits = try await FriendshipService.visits(of: senderID)
            fetchedVisits = visits.filter { $0.placeID == place.id }
        } catch {
            // Sheet still renders the place, actions, and any note we already have.
        }
    }
}

/// Friend visits for one venue, gathered from every in-memory source the app
/// already holds so inbox and explore sheets don't start empty.
enum SocialPlaceVisits {
    static func collected(
        placeID: UUID,
        seed: [FriendVisit] = [],
        cache: FriendVisitCache,
        feed: FeedStore
    ) -> [FriendVisit] {
        var byID: [UUID: FriendVisit] = [:]
        for visit in seed where visit.placeID == placeID {
            byID[visit.id] = visit
        }
        for visit in cache.visits where visit.placeID == placeID {
            byID[visit.id] = visit
        }
        for item in feed.items where item.visit.placeID == placeID {
            byID[item.visit.id] = item.visit
        }
        return byID.values.sorted { $0.visitedAt > $1.visitedAt }
    }
}
