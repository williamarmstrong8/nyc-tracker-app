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
/// Compact by default — a count and avatars — with comments behind a tap so the
/// write-up stays about the visit the user opened.
struct VisitFriendsSection: View {
    let placeID: UUID
    var latitude: Double?
    var longitude: Double?

    @Environment(SocialStatsCache.self) private var stats
    @Environment(FriendVisitCache.self) private var friendCache
    @Environment(FeedStore.self) private var feed
    @Environment(SocialDemoMode.self) private var demo
    @Environment(AuthManager.self) private var auth
    @Environment(SocialGraph.self) private var graph

    @State private var social: PlaceSocial?
    @State private var isLoading = false
    @State private var showComments = false
    @State private var comments: [FriendVisit] = []
    @State private var isLoadingComments = false

    private var hasAnythingToShow: Bool {
        guard let social else { return false }
        return social.friendPlaceCount > 0
            || social.recommenders.contains { !($0.message ?? "").isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let social, hasAnythingToShow {
                if social.friendPlaceCount > 0 {
                    friendsRow(social)
                }
                commentsToggle
                if showComments {
                    commentsBlock(social)
                }
            } else if isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: placeID) {
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
            Text("\(pluralized(social.friendPlaceCount, "friend")) \(social.friendPlaceCount == 1 ? "has" : "have") been here")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var commentsToggle: some View {
        Button {
            Haptics.tap()
            withAnimation(.snappy) { showComments.toggle() }
            if showComments { Task { await loadComments() } }
        } label: {
            HStack(spacing: 4) {
                Text(showComments ? "Hide comments" : "See what they said")
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(showComments ? 0 : -90))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func commentsBlock(_ social: PlaceSocial) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(social.recommenders) { recommender in
                if let message = recommender.message, !message.isEmpty {
                    commentCard(
                        person: recommender.person,
                        date: recommender.createdAt,
                        rating: nil,
                        body: "\u{201C}\(message)\u{201D}"
                    )
                }
            }

            if isLoadingComments && comments.isEmpty {
                ProgressView().controlSize(.small)
                    .padding(.vertical, 4)
            }

            ForEach(comments) { visit in
                commentCard(
                    person: visit.person,
                    date: visit.visitedAt,
                    rating: visit.rating,
                    body: commentBody(for: visit)
                )
            }

            if !isLoadingComments,
               comments.isEmpty,
               social.recommenders.allSatisfy({ ($0.message ?? "").isEmpty }) {
                Text("No notes from friends yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commentCard(
        person: PersonSummary,
        date: Date?,
        rating: Rating?,
        body: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PersonAvatar(person: person, size: 28, showsPaletteRing: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.bestName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let date {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if let rating {
                    Image(systemName: rating.symbol)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(rating.label)
                }
            }
            if let body, !body.isEmpty {
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private func commentBody(for visit: FriendVisit) -> String? {
        if let summary = visit.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        if let quote = visit.topQuote?.trimmingCharacters(in: .whitespacesAndNewlines),
           !quote.isEmpty {
            return "\u{201C}\(quote)\u{201D}"
        }
        return nil
    }

    private func loadComments() async {
        guard comments.isEmpty else { return }
        isLoadingComments = true
        defer { isLoadingComments = false }

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
        comments = SocialPlaceVisits.collected(
            placeID: placeID,
            seed: seed,
            cache: friendCache,
            feed: feed,
            demo: demo
        ).filter { $0.userID != ownID }
    }
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

    @Environment(WishlistStore.self) private var wishlist
    @Environment(SocialStatsCache.self) private var stats
    @Environment(\.modelContext) private var modelContext
    @Environment(AuthManager.self) private var auth
    @Environment(SyncEngine.self) private var sync

    @State private var isSaving = false
    @State private var showSendSheet = false

    private var savedEntry: WishlistEntry? { wishlist.entry(forPlace: place.id) }

    /// See `WantToTryMirror`: a save has to land in the local Want to try list
    /// too, or it never shows up anywhere the user looks.
    private var mirror: WantToTryMirror? {
        guard let userID = auth.state.profile?.id else { return nil }
        return WantToTryMirror(context: modelContext, userID: userID)
    }

    var body: some View {
        HStack(spacing: 10) {
            saveButton

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

    /// Written as an if/else rather than a ternary over two button styles:
    /// `buttonStyle` is generic over the style type, so the two branches have
    /// different types and a ternary doesn't type-check.
    @ViewBuilder
    private var saveButton: some View {
        let isSaved = savedEntry != nil
        let button = Button {
            Haptics.tap()
            Task { await toggleSaved() }
        } label: {
            Label(
                isSaved ? savedSaveLabel : unsavedSaveLabel,
                systemImage: isSaved ? "bookmark.fill" : "bookmark"
            )
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, minHeight: 44)
            .opacity(isSaving ? 0 : 1)
            .overlay { if isSaving { ProgressView().controlSize(.small) } }
        }
        .disabled(isSaving)

        if isSaved {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.glassProminent)
        }
    }

    private func toggleSaved() async {
        isSaving = true
        defer { isSaving = false }

        if let savedEntry {
            let removed = await wishlist.remove(itemID: savedEntry.id)
            if removed { mirror?.removeMirror(placeID: place.id) }
        } else {
            let saved = await wishlist.add(placeID: place.id)
            if saved { mirror?.mirror(place) }
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
/// someone sent with it.
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
    @Environment(SocialDemoMode.self) private var demo

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

    var body: some View {
        PlaceDetailSheet(
            group: group,
            onOpenOwnVisit: onOpenOwnVisit,
            recommendationNote: recommendationNote
        )
        .task { await loadSenderVisitsIfNeeded() }
    }

    private var mergedFriendVisits: [FriendVisit] {
        SocialPlaceVisits.collected(
            placeID: place.id,
            seed: seedVisits + fetchedVisits,
            cache: friendCache,
            feed: feed,
            demo: demo
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
        feed: FeedStore,
        demo: SocialDemoMode
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
        if demo.isEnabled {
            for visit in demo.visits(atPlace: placeID) {
                byID[visit.id] = visit
            }
        }
        return byID.values.sorted { $0.visitedAt > $1.visitedAt }
    }
}
