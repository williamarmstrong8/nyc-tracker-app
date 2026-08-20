import Foundation
import Observation

/// In-memory sample social graph for exercising friends, inbox, explore, and
/// the map without a second real account.
///
/// ## Why this exists
///
/// Friendships are a two-person feature. Testing the UI against the live API
/// means a second signed-in device, and every accept/decline is a real row.
/// This overlay answers the same reads and mutations the screens already make,
/// against a canned cast of New Yorkers, so the UX can be walked end to end
/// on one phone.
///
/// ## What it does not do
///
/// It never writes to Supabase. The signed-in user's own visits, wishlist, and
/// profile stay real. Only the *other people* layer is replaced: edges, search,
/// friend profiles, friend visits, the explore feed, inbox recommendations,
/// and the social aggregates.
///
/// App-lifetime singleton, matching `NetworkMonitor` — the wire types are
/// called from static service methods that have no environment to read from.
@Observable
final class SocialDemoMode {

    static let shared = SocialDemoMode()

    /// Non-nil only while the overlay is on, so call sites can write
    /// `if let demo = SocialDemoMode.active`.
    static var active: SocialDemoMode? { shared.isEnabled ? shared : nil }

    // MARK: - Observable state

    private(set) var isEnabled: Bool

    /// Bumped on enable, disable, and reset so screens that already loaded
    /// can throw away coverage and refetch, even when the friend ID list
    /// happens to look the same as last time.
    private(set) var epoch: Int = 0

    // MARK: - Catalog

    private var people: [UUID: DemoPerson] = [:]
    private var visitsByUser: [UUID: [FriendVisit]] = [:]
    private var places: [UUID: DemoPlace] = [:]
    private var edges: [FriendshipEdge] = []
    private var recommendations: [InboxRecommendation] = []

    /// Direct-message threads with the sample cast.
    ///
    /// Seeded separately from everything else because a conversation has two
    /// sides and only one of them is invented here — the signed-in user is real,
    /// and their id doesn't arrive until `ChatStore` configures itself. Until
    /// then these stay empty and the friends list simply shows no previews.
    private var chatThreads: [ConversationThread] = []
    private var chatMessages: [UUID: [ChatMessage]] = [:]
    private var signedInUserID: UUID?

    private static let defaultsKey = "nyc-tracker.socialDemoMode.enabled.v1"

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        if isEnabled { seed() }
    }

    // MARK: - Lifecycle

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
        if enabled {
            seed()
        } else {
            clear()
        }
        epoch += 1
    }

    /// Restore the original cast after accept / decline / unfriend have been
    /// walked through. Enable stays on.
    func reset() {
        guard isEnabled else { return }
        seed()
        epoch += 1
    }

    func simulateLatency() async {
        try? await Task.sleep(for: .milliseconds(160))
    }

    /// Tell the overlay who the real person in these conversations is.
    ///
    /// The only place the signed-in user leaks into the sample data, and it has
    /// to: a message needs a sender, and half the messages in a thread are the
    /// user's own. Called by `ChatStore.configure`.
    func noteSignedInUser(_ userID: UUID) {
        guard signedInUserID != userID else { return }
        signedInUserID = userID
        if isEnabled { seedChat() }
    }

    // MARK: - Graph reads

    func currentEdges() -> [FriendshipEdge] { edges }

    func inboxRecommendations() -> [InboxRecommendation] {
        recommendations.filter { $0.status != .dismissed }
    }

    func search(_ query: String, limit: Int) -> [ProfileSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = people.values.filter { person in
            guard !trimmed.isEmpty else { return true }
            return person.displayName.lowercased().contains(trimmed)
                || person.username.lowercased().contains(trimmed)
        }
        .sorted { $0.displayName < $1.displayName }

        return matches.prefix(limit).map { person in
            let snap = snapshot(for: person.id)
            return ProfileSearchResult(
                id: person.id,
                username: person.username,
                displayName: person.displayName,
                avatarURL: nil,
                bio: person.bio,
                relationship: snap.state,
                friendshipID: snap.friendshipID
            )
        }
    }

    func profile(of userID: UUID) -> FriendProfileSummary? {
        guard let person = people[userID] else { return nil }
        let visits = visitsByUser[userID] ?? []
        let visited = visits.filter { $0.visitKind == .visited }
        let wantToTry = visits.filter { $0.visitKind == .wantToTry }
        let placesLogged = Set(visited.map(\.placeID))
        return FriendProfileSummary(
            id: person.id,
            username: person.username,
            displayName: person.displayName,
            avatarURL: nil,
            bio: person.bio,
            isFriend: edges.contains { $0.userID == userID && $0.isAcceptedFriend },
            isSelf: false,
            visitCount: visited.count,
            wantToTryCount: wantToTry.count,
            placeCount: placesLogged.count,
            firstVisitAt: visited.map(\.visitedAt).min(),
            lastVisitAt: visited.map(\.visitedAt).max()
        )
    }

    /// Demo friends are treated as a clique: if this person is an accepted
    /// friend of the signed-in user, they have the same friend count the user
    /// does (the user plus the other sample friends).
    func acceptedFriendCount(of userID: UUID) -> Int {
        guard friendIDs.contains(userID) else { return 0 }
        return friendIDs.count
    }

    func visits(of userID: UUID) -> [FriendVisit] {
        (visitsByUser[userID] ?? []).sorted { $0.visitedAt > $1.visitedAt }
    }

    /// Friends' visits at one venue, newest first — used to give inbox and
    /// explore sheets the same photos the map pin already has.
    func visits(atPlace placeID: UUID) -> [FriendVisit] {
        allFriendVisits
            .filter { $0.placeID == placeID }
            .sorted { $0.visitedAt > $1.visitedAt }
    }

    func visitsInBounds(
        minLat: Double,
        maxLat: Double,
        minLng: Double,
        maxLng: Double,
        userIDs: [UUID]?
    ) -> [FriendVisit] {
        let allowed = Set(userIDs ?? friendIDs)
        return allFriendVisits
            .filter { allowed.contains($0.userID) }
            .filter { visit in
                visit.latitude >= minLat && visit.latitude <= maxLat
                    && visit.longitude >= minLng && visit.longitude <= maxLng
            }
            .sorted { $0.visitedAt > $1.visitedAt }
    }

    func feed(after cursor: FeedCursor?, limit: Int) -> [FeedItem] {
        let counts = friendPlaceCounts
        var rows = allFriendVisits
            .sorted { lhs, rhs in
                if lhs.visitedAt != rhs.visitedAt { return lhs.visitedAt > rhs.visitedAt }
                return lhs.visitID.uuidString > rhs.visitID.uuidString
            }
            .map { visit in
                FeedItem(visit: visit, friendPlaceCount: counts[visit.placeID] ?? 1)
            }

        if let cursor {
            rows = Array(rows.drop(while: { item in
                let newer = item.visit.visitedAt > cursor.visitedAt
                let sameTimeLaterID = item.visit.visitedAt == cursor.visitedAt
                    && item.visit.visitID.uuidString >= cursor.id.uuidString
                return newer || sameTimeLaterID
            }))
        }
        return Array(rows.prefix(limit))
    }

    func placeSocial(placeID: UUID) -> PlaceSocial? {
        let visitors = allFriendVisits.filter { $0.placeID == placeID }
        guard !visitors.isEmpty else { return nil }

        let grouped = Dictionary(grouping: visitors, by: \.userID)
        let friends = grouped.values.compactMap { visits -> PlaceVisitor? in
            guard let first = visits.first else { return nil }
            return PlaceVisitor(
                id: first.userID,
                username: first.username,
                displayName: first.displayName,
                avatarURL: first.avatarURL,
                visitCount: visits.count
            )
        }
        .sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }

        let recs = recommendations.filter { $0.place.id == placeID && $0.status != .dismissed }
        let recommenders = recs.map { rec in
            Recommender(
                id: rec.senderID,
                username: rec.username,
                displayName: rec.displayName,
                avatarURL: rec.avatarURL,
                message: rec.message,
                createdAt: rec.createdAt
            )
        }

        return PlaceSocial(
            placeID: placeID,
            friendVisitCount: visitors.count,
            friendPlaceCount: friends.count,
            friends: friends,
            iHaveVisited: false,
            onMyWishlist: false,
            wishlistItemID: nil,
            recommenders: recommenders
        )
    }

    func friendOverlap(with userID: UUID) -> FriendOverlap? {
        guard people[userID] != nil else { return nil }
        // Demo places have their own IDs, so they never actually overlap the
        // signed-in user's SwiftData rows. For friends, pretends a couple of
        // well-known spots are in common so the profile strip has something
        // to render; everyone else is a genuine empty overlap.
        let isFriend = edges.contains { $0.userID == userID && $0.isAcceptedFriend }
        let common: [CommonPlace]
        if isFriend {
            common = overlapPlaces.prefix(3).map {
                CommonPlace(id: $0.id, name: $0.name, category: $0.category)
            }
        } else {
            common = []
        }
        return FriendOverlap(userID: userID, placesInCommon: common.count, commonPlaces: common)
    }

    func ownSocialStats(gapLimit: Int) -> OwnSocialStats {
        let friendCount = friendIDs.count
        let grouped = Dictionary(grouping: allFriendVisits, by: \.placeID)
        let gaps: [GapPlace] = grouped.values.compactMap { visits -> GapPlace? in
            guard let first = visits.first else { return nil }
            return GapPlace(
                id: first.placeID,
                name: first.placeName,
                category: first.placeCategory,
                neighborhood: first.neighborhood,
                latitude: first.latitude,
                longitude: first.longitude,
                friendCount: Set(visits.map(\.userID)).count
            )
        }
        .sorted { $0.friendCount > $1.friendCount }

        return OwnSocialStats(
            friendCount: friendCount,
            gapCount: gaps.count,
            gapPlaces: Array(gaps.prefix(gapLimit))
        )
    }

    // MARK: - Mutations

    func sendRequest(to userID: UUID) {
        if let incoming = edges.first(where: { $0.userID == userID && $0.isIncomingRequest }) {
            try? accept(friendshipID: incoming.friendshipID)
            return
        }
        guard !edges.contains(where: { $0.userID == userID }) else { return }
        guard let person = people[userID] else { return }
        edges.append(makeEdge(
            friendshipID: UUID(),
            person: person,
            status: .pending,
            direction: .outgoing,
            createdAt: Date()
        ))
        sortEdges()
    }

    func accept(friendshipID: UUID) throws {
        guard let index = edges.firstIndex(where: { $0.friendshipID == friendshipID }),
              edges[index].isIncomingRequest
        else {
            throw FriendshipService.SocialError.acceptNotPermitted
        }
        edges[index].status = .accepted
        edges[index].respondedAt = Date()
        sortEdges()
    }

    func remove(friendshipID: UUID) {
        edges.removeAll { $0.friendshipID == friendshipID }
    }

    func markRecommendationsRead(_ ids: [UUID]) {
        let now = Date()
        for index in recommendations.indices where ids.contains(recommendations[index].id) {
            if recommendations[index].status == .unread {
                recommendations[index].status = .read
                recommendations[index].readAt = now
            }
        }
    }

    func dismissRecommendation(_ id: UUID) {
        if let index = recommendations.firstIndex(where: { $0.id == id }) {
            recommendations[index].status = .dismissed
        }
    }

    // MARK: - Chat

    func conversationThreads() -> [ConversationThread] {
        chatThreads.sorted {
            ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast)
        }
    }

    /// Find or create the thread with a sample person.
    ///
    /// Creates on demand for the friends who weren't seeded with a
    /// conversation, so every row on the friends page opens something.
    func openConversation(with userID: UUID) -> UUID {
        if let existing = chatThreads.first(where: { $0.userID == userID }) {
            return existing.conversationID
        }

        let conversationID = UUID()
        let person = people[userID]
        chatThreads.append(
            ConversationThread(
                conversationID: conversationID,
                userID: userID,
                username: person?.username,
                displayName: person?.displayName,
                avatarURL: nil,
                createdAt: Date(),
                lastMessageAt: nil,
                lastMessageBody: nil,
                lastMessageSenderID: nil,
                lastMessagePlaceName: nil,
                unreadCount: 0
            )
        )
        chatMessages[conversationID] = []
        return conversationID
    }

    func messages(in conversationID: UUID) -> [ChatMessage] {
        chatMessages[conversationID] ?? []
    }

    func sendMessage(
        conversation conversationID: UUID,
        body: String,
        place placeID: UUID?,
        visit visitID: UUID?,
        preview: SharedPlacePreview?
    ) -> ChatMessage {
        // The caller's snapshot first. A place the user picked from their own
        // log is a REAL row that this overlay has never heard of — looking it up
        // in the sample catalog finds nothing, which is what made a sent place
        // arrive as a bare note with no card.
        let place = preview?.place ?? placeID.flatMap { places[$0]?.summary }

        let message = ChatMessage(
            id: UUID(),
            conversationID: conversationID,
            senderID: signedInUserID ?? UUID(),
            body: body,
            createdAt: Date(),
            username: nil,
            displayName: nil,
            avatarURL: nil,
            place: place,
            visitID: visitID,
            visitTitle: preview?.title,
            visitTags: preview?.tags ?? [],
            ratingLabel: nil,
            // Sample mode never uploads, so there is no storage object to point
            // at. The snapshot carries a `local:` path into the user's own photo
            // storage instead, and the card renders the same image the picker
            // showed.
            photos: preview?.photoPath.map {
                [FriendVisitPhoto(id: UUID(), storagePath: $0, thumbPath: nil, sortOrder: 0)]
            } ?? []
        )

        chatMessages[conversationID, default: []].append(message)
        applyPreview(of: message, to: conversationID, placeName: place?.name)
        return message
    }

    func markConversationRead(_ conversationID: UUID) {
        guard let index = chatThreads.firstIndex(where: { $0.conversationID == conversationID })
        else { return }
        chatThreads[index].unreadCount = 0
    }

    private func applyPreview(of message: ChatMessage, to conversationID: UUID, placeName: String?) {
        guard let index = chatThreads.firstIndex(where: { $0.conversationID == conversationID })
        else { return }
        chatThreads[index].lastMessageAt = message.createdAt
        chatThreads[index].lastMessageBody = message.body
        chatThreads[index].lastMessageSenderID = message.senderID
        chatThreads[index].lastMessagePlaceName = placeName
    }

    func sendPlace(placeID: UUID, to recipients: [UUID], message: String?) -> [RecommendationSendResult] {
        _ = (placeID, message)
        return recipients.map { recipient in
            guard friendIDs.contains(recipient) else {
                return RecommendationSendResult(
                    recipientID: recipient,
                    outcome: .notFriends,
                    recommendationID: nil
                )
            }
            return RecommendationSendResult(
                recipientID: recipient,
                outcome: .sent,
                recommendationID: UUID()
            )
        }
    }

    // MARK: - Private derived

    private var friendIDs: [UUID] {
        edges.filter(\.isAcceptedFriend).map(\.userID)
    }

    private var allFriendVisits: [FriendVisit] {
        friendIDs.flatMap { visitsByUser[$0] ?? [] }.map(taggingViewerIfListed)
    }

    /// Visits the sample cast "tagged the viewer in".
    ///
    /// Seeded data cannot name a real account: the cast is fixed at build time
    /// and the signed-in user's id is only known once someone actually signs in.
    /// So the relationship is stored as a list of visit ids here and the viewer
    /// is spliced in at read time — which is what gives the profile's Tagged tab
    /// something to show without a second real account.
    private static let viewerTaggedVisitIDs: Set<UUID> = [id(30), id(40), id(60)]

    private func taggingViewerIfListed(_ visit: FriendVisit) -> FriendVisit {
        guard let me = signedInUserID,
              Self.viewerTaggedVisitIDs.contains(visit.visitID),
              !visit.tagged.contains(where: { $0.id == me })
        else { return visit }

        var copy = visit
        copy.tagged.append(
            TaggedPerson(id: me, username: nil, displayName: "You", avatarURL: nil)
        )
        return copy
    }

    /// Visits in which this person was tagged by someone else, newest first.
    func taggedVisits(of userID: UUID) -> [FriendVisit] {
        allFriendVisits
            .filter { $0.visitKind == .visited }
            .filter { visit in visit.tagged.contains { $0.id == userID } }
            .sorted { $0.visitedAt > $1.visitedAt }
    }

    private var friendPlaceCounts: [UUID: Int] {
        Dictionary(grouping: allFriendVisits, by: \.placeID)
            .mapValues { Set($0.map(\.userID)).count }
    }

    private var overlapPlaces: [DemoPlace] {
        [Self.lucali, Self.lartusi, Self.deadRabbit]
    }

    private func snapshot(for id: UUID) -> RelationshipSnapshot {
        if let edge = edges.first(where: { $0.userID == id }) {
            if edge.isAcceptedFriend {
                return RelationshipSnapshot(state: .friends, friendshipID: edge.friendshipID)
            }
            if edge.isIncomingRequest {
                return RelationshipSnapshot(state: .incoming, friendshipID: edge.friendshipID)
            }
            if edge.isOutgoingRequest {
                return RelationshipSnapshot(state: .outgoing, friendshipID: edge.friendshipID)
            }
        }
        return RelationshipSnapshot(state: .none, friendshipID: nil)
    }

    // MARK: - Seed

    private func clear() {
        people = [:]
        visitsByUser = [:]
        places = [:]
        edges = []
        recommendations = []
        chatThreads = []
        chatMessages = [:]
    }

    private func seed() {
        let maya = DemoPerson(
            id: Self.id(1), username: "maya", displayName: "Maya Chen",
            bio: "Always hunting a perfect dumpling."
        )
        let dev = DemoPerson(
            id: Self.id(2), username: "dev", displayName: "Dev Patel",
            bio: "Cocktails, then a slice on the walk home."
        )
        let riley = DemoPerson(
            id: Self.id(3), username: "riley", displayName: "Riley Brooks",
            bio: "Baker. Will cross town for a croissant."
        )
        let sam = DemoPerson(
            id: Self.id(4), username: "sam", displayName: "Sam Rivera",
            bio: "Just moved to Brooklyn."
        )
        let jules = DemoPerson(
            id: Self.id(5), username: "jules", displayName: "Jules Okonkwo",
            bio: "Martinis and long walks."
        )
        let alex = DemoPerson(
            id: Self.id(6), username: "alex", displayName: "Alex Kim",
            bio: "Natural wine, loud rooms."
        )
        let priya = DemoPerson(
            id: Self.id(7), username: "priya", displayName: "Priya Shah",
            bio: "Weeknight pasta evangelist."
        )
        let jordan = DemoPerson(
            id: Self.id(8), username: "jordan", displayName: "Jordan Lee",
            bio: "Coffee first, then everything else."
        )
        let casey = DemoPerson(
            id: Self.id(9), username: "casey", displayName: "Casey Nguyen",
            bio: "If there's a patio, I'm there."
        )

        let cast = [maya, dev, riley, sam, jules, alex, priya, jordan, casey]
        people = Dictionary(uniqueKeysWithValues: cast.map { ($0.id, $0) })

        let catalog = [
            Self.lucali, Self.lartusi, Self.laCabra, Self.deadRabbit,
            Self.attaboy, Self.radioBakery, Self.princeStreet, Self.dante,
            Self.katz, Self.reggio, Self.appart, Self.odeon, Self.antico
        ]
        places = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })

        visitsByUser = [
            maya.id: [
                makeVisit(id: Self.id(34), person: maya, place: Self.antico, daysAgo: 0.2,
                          title: "The Dante, obviously",
                          summary: "Schiacciata still warm, mortadella spilling out both sides. Ate it standing on 15th because there is never a seat and that is part of it.",
                          quote: "If it fits in two hands, you ordered wrong.",
                          tags: ["sandwich", "worth-the-wait", "solo"],
                          rating: "loved"),
                makeVisit(id: Self.id(30), person: maya, place: Self.lucali, daysAgo: 2,
                          title: "The wait was worth it",
                          summary: "Got there at 4:40 and still waited an hour. The calzone is the move — one is enough for two if you pretend it isn't.",
                          quote: "One calzone, two people, no leftovers. That's the ratio.",
                          tags: ["pizza", "date-night", "worth-the-wait"],
                          rating: "loved",
                          tagged: [dev, riley]),
                makeVisit(id: Self.id(31), person: maya, place: Self.lartusi, daysAgo: 5,
                          title: "West Village pasta night",
                          summary: "The cacio e pepe was exactly as loud with pepper as it should be. Sat at the bar and watched the open kitchen the whole time.",
                          quote: "Pepper first, cheese second, pasta third.",
                          tags: ["pasta", "bar-seats"],
                          rating: "loved"),
                makeVisit(id: Self.id(32), person: maya, place: Self.laCabra, daysAgo: 9,
                          title: "Cardamom bun, again",
                          summary: "Third time this month. The line looks worse than it is.",
                          tags: ["coffee", "pastry", "solo"],
                          rating: "liked"),
                makeVisit(id: Self.id(33), person: maya, place: Self.katz, daysAgo: 18,
                          title: "Tourist on purpose",
                          summary: "Took my parents. They wanted the sandwich they remembered from a movie. It delivered.",
                          tags: ["deli", "group"],
                          rating: "liked"),
            ],
            dev.id: [
                makeVisit(id: Self.id(40), person: dev, place: Self.deadRabbit, daysAgo: 1,
                          title: "Downstairs is the move",
                          summary: "Skipped the parlor, stayed in the taproom. The Irish coffee still slaps and the bartender talked us into a second round we did not need.",
                          quote: "Never trust a cocktail list this long, except here.",
                          tags: ["cocktails", "date-night"],
                          rating: "loved"),
                makeVisit(id: Self.id(41), person: dev, place: Self.attaboy, daysAgo: 4,
                          title: "No menu, no notes",
                          summary: "Told them gin and something bitter. What came back was better than anything I would have ordered.",
                          tags: ["cocktails", "speakeasy"],
                          rating: "loved"),
                makeVisit(id: Self.id(42), person: dev, place: Self.odeon, daysAgo: 11,
                          title: "Late dinner after a show",
                          summary: "The steak frites at 11pm is a personality. Lights still too bright, food still too good.",
                          tags: ["late-night", "french"],
                          rating: "liked"),
            ],
            riley.id: [
                makeVisit(id: Self.id(50), person: riley, place: Self.radioBakery, daysAgo: 3,
                          title: "Greenpoint pilgrimage",
                          summary: "The potato focaccia was gone by 9:15. Got the kouign-amann and a coffee and sat on a hydrant like a local.",
                          quote: "If they still have focaccia, get two.",
                          tags: ["bakery", "breakfast", "worth-the-wait"],
                          rating: "loved"),
                makeVisit(id: Self.id(51), person: riley, place: Self.appart, daysAgo: 8,
                          title: "Croissant that ruined me",
                          summary: "I bake. I know what this takes. I'm not okay.",
                          tags: ["bakery", "pastry"],
                          rating: "loved"),
                makeVisit(id: Self.id(52), person: riley, place: Self.reggio, daysAgo: 14,
                          kind: "wantToTry",
                          title: "Need to go back for the tiramisu",
                          summary: "Walked past twice. Next time I'm going in.",
                          tags: ["cafe"],
                          rating: nil),
            ],
            sam.id: [
                makeVisit(id: Self.id(60), person: sam, place: Self.princeStreet, daysAgo: 6,
                          title: "First slice in the new neighborhood",
                          summary: "The pepperoni cup is not a rumor. Ate it standing on the sidewalk and did not regret the oil on my shirt.",
                          tags: ["pizza", "solo"],
                          rating: "loved",
                          tagged: [maya]),
            ],
            jules.id: [
                makeVisit(id: Self.id(70), person: jules, place: Self.dante, daysAgo: 12,
                          title: "Negroni, then another",
                          summary: "Sat outside even though it was almost too cold. The frozen one is a gimmick that works.",
                          tags: ["cocktails", "patio"],
                          rating: "liked",
                          tagged: [sam]),
            ],
        ]

        edges = [
            makeEdge(friendshipID: Self.id(80), person: maya, status: .accepted, direction: .incoming, createdAt: daysAgo(40), respondedAt: daysAgo(39)),
            makeEdge(friendshipID: Self.id(81), person: dev, status: .accepted, direction: .outgoing, createdAt: daysAgo(28), respondedAt: daysAgo(27)),
            makeEdge(friendshipID: Self.id(82), person: riley, status: .accepted, direction: .incoming, createdAt: daysAgo(15), respondedAt: daysAgo(14)),
            makeEdge(friendshipID: Self.id(83), person: sam, status: .pending, direction: .incoming, createdAt: daysAgo(1)),
            makeEdge(friendshipID: Self.id(84), person: jules, status: .pending, direction: .incoming, createdAt: daysAgo(0.3)),
            makeEdge(friendshipID: Self.id(85), person: alex, status: .pending, direction: .outgoing, createdAt: daysAgo(3)),
        ]
        sortEdges()

        recommendations = [
            InboxRecommendation(
                id: Self.id(90),
                status: .unread,
                message: "Get there before 5 or don't bother. Calzone, not the pizza.",
                createdAt: daysAgo(0.6),
                readAt: nil,
                senderID: dev.id,
                username: dev.username,
                displayName: dev.displayName,
                avatarURL: nil,
                place: Self.lucali.summary,
                alreadyVisited: false,
                onWishlist: false
            ),
            InboxRecommendation(
                id: Self.id(91),
                status: .unread,
                message: "Kouign-amann if they have it. Focaccia if they don't.",
                createdAt: daysAgo(2),
                readAt: nil,
                senderID: riley.id,
                username: riley.username,
                displayName: riley.displayName,
                avatarURL: nil,
                place: Self.radioBakery.summary,
                alreadyVisited: false,
                onWishlist: false
            ),
        ]

        seedChat()
    }

    /// Two threads with the two friends who already appear everywhere else.
    ///
    /// Both sides are represented on purpose — an unread message from them and a
    /// reply from the user — because a thread that is all one person's messages
    /// never shows whether the mine/theirs layout actually reads correctly.
    ///
    /// Runs again whenever the signed-in user becomes known, which is why it
    /// assigns rather than appends: re-seeding must not double the history.
    private func seedChat() {
        guard let me = signedInUserID, let maya = people[Self.id(1)], let dev = people[Self.id(2)] else {
            chatThreads = []
            chatMessages = [:]
            return
        }

        let mayaThread = Self.id(120)
        let devThread = Self.id(121)

        chatMessages = [
            mayaThread: [
                chatMessage(
                    id: Self.id(130), conversation: mayaThread, from: maya,
                    daysAgo: 4, place: Self.lartusi, visitID: Self.id(31),
                    visitTitle: "West Village pasta night",
                    tags: ["pasta", "bar-seats"],
                    body: "Bar seats only, but you can watch them make the cacio e pepe. Go early."
                ),
                chatMessage(
                    id: Self.id(131), conversation: mayaThread, fromMe: me,
                    daysAgo: 3.9,
                    body: "Adding it. Are you free Thursday?"
                ),
                chatMessage(
                    id: Self.id(132), conversation: mayaThread, from: maya,
                    daysAgo: 0.4, place: Self.antico, visitID: Self.id(34),
                    visitTitle: "The Dante, obviously",
                    tags: ["sandwich", "worth-the-wait"],
                    body: "This is the sandwich I keep talking about. Two hands minimum."
                ),
            ],
            devThread: [
                chatMessage(
                    id: Self.id(140), conversation: devThread, from: dev,
                    daysAgo: 8, place: Self.deadRabbit, visitID: Self.id(40),
                    visitTitle: nil,
                    tags: ["cocktails"],
                    body: "Upstairs, not downstairs. Downstairs is for tourists and I say that with love."
                ),
                chatMessage(
                    id: Self.id(141), conversation: devThread, fromMe: me,
                    daysAgo: 7.8,
                    body: "Noted. Next round is on me."
                ),
            ],
        ]

        chatThreads = [
            chatThread(
                id: mayaThread, person: maya,
                messages: chatMessages[mayaThread] ?? [],
                placeName: Self.antico.name,
                unread: 1
            ),
            chatThread(
                id: devThread, person: dev,
                messages: chatMessages[devThread] ?? [],
                placeName: nil,
                unread: 0
            ),
        ]
    }

    /// A message from one of the sample people, about one of their visits.
    private func chatMessage(
        id: UUID,
        conversation: UUID,
        from person: DemoPerson,
        daysAgo offset: Double,
        place: DemoPlace,
        visitID: UUID?,
        visitTitle: String?,
        tags: [String],
        body: String
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            conversationID: conversation,
            senderID: person.id,
            body: body,
            createdAt: daysAgo(offset),
            username: person.username,
            displayName: person.displayName,
            avatarURL: nil,
            place: place.summary,
            visitID: visitID,
            visitTitle: visitTitle,
            visitTags: tags,
            ratingLabel: nil,
            photos: [demoPhoto(forVisit: visitID ?? id)]
        )
    }

    /// A reply from the signed-in user. No place attached: these stand in for
    /// the half of a conversation that is just talking.
    private func chatMessage(
        id: UUID,
        conversation: UUID,
        fromMe me: UUID,
        daysAgo offset: Double,
        body: String
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            conversationID: conversation,
            senderID: me,
            body: body,
            createdAt: daysAgo(offset),
            username: nil,
            displayName: nil,
            avatarURL: nil,
            place: nil,
            visitID: nil,
            visitTitle: nil,
            visitTags: [],
            ratingLabel: nil,
            photos: []
        )
    }

    private func chatThread(
        id: UUID,
        person: DemoPerson,
        messages: [ChatMessage],
        placeName: String?,
        unread: Int
    ) -> ConversationThread {
        let last = messages.last
        return ConversationThread(
            conversationID: id,
            userID: person.id,
            username: person.username,
            displayName: person.displayName,
            avatarURL: nil,
            createdAt: messages.first?.createdAt ?? Date(),
            lastMessageAt: last?.createdAt,
            lastMessageBody: last?.body,
            lastMessageSenderID: last?.senderID,
            lastMessagePlaceName: placeName,
            unreadCount: unread
        )
    }

    private func sortEdges() {
        edges.sort { lhs, rhs in
            lhs.person.bestName.localizedCaseInsensitiveCompare(rhs.person.bestName) == .orderedAscending
        }
    }

    private func makeEdge(
        friendshipID: UUID,
        person: DemoPerson,
        status: FriendshipStatus,
        direction: FriendshipEdge.Direction,
        createdAt: Date,
        respondedAt: Date? = nil
    ) -> FriendshipEdge {
        FriendshipEdge(
            friendshipID: friendshipID,
            status: status,
            direction: direction,
            createdAt: createdAt,
            respondedAt: respondedAt,
            userID: person.id,
            username: person.username,
            displayName: person.displayName,
            avatarURL: nil,
            bio: person.bio
        )
    }

    private func makeVisit(
        id: UUID,
        person: DemoPerson,
        place: DemoPlace,
        daysAgo offset: Double,
        kind: String = "visited",
        title: String?,
        summary: String?,
        quote: String? = nil,
        transcript: String? = nil,
        tags: [String],
        rating: String?,
        tagged: [DemoPerson] = []
    ) -> FriendVisit {
        FriendVisit(
            visitID: id,
            visitedAt: daysAgo(offset),
            title: title,
            summary: summary,
            transcript: transcript,
            topQuote: quote,
            tags: tags,
            ratingLabel: rating,
            returnIntent: rating == "loved" ? "immediately" : "whenNearby",
            kind: kind,
            placeID: place.id,
            placeName: place.name,
            placeCategory: place.category,
            neighborhood: place.neighborhood,
            streetAddress: place.address,
            latitude: place.latitude,
            longitude: place.longitude,
            userID: person.id,
            username: person.username,
            displayName: person.displayName,
            avatarURL: nil,
            photos: kind == "visited" ? [demoPhoto(forVisit: id)] : [],
            tagged: tagged.map {
                TaggedPerson(id: $0.id, username: $0.username, displayName: $0.displayName, avatarURL: nil)
            }
        )
    }

    /// One bundled image on every logged visit so Explore and friend profiles
    /// render a real photo. Sample data does not upload to storage.
    private func demoPhoto(forVisit visitID: UUID) -> FriendVisitPhoto {
        FriendVisitPhoto(
            id: visitID,
            storagePath: Self.demoPhotoAssetPath,
            thumbPath: nil,
            sortOrder: 0
        )
    }

    private func daysAgo(_ days: Double) -> Date {
        Date().addingTimeInterval(-days * 86_400)
    }

    /// Stable UUIDs so SwiftUI identities survive a reset.
    private static func id(_ n: UInt8) -> UUID {
        UUID(uuid: (0xDE, 0x40, 0x10, 0x00, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, n))
    }

    private static let demoPhotoAssetPath = "asset:DemoVisitPhoto"

    // MARK: - Places

    private static let lucali = DemoPlace(
        id: id(10), name: "Lucali", category: "restaurant",
        neighborhood: "Carroll Gardens", address: "575 Henry St",
        latitude: 40.6754, longitude: -73.9992
    )
    private static let lartusi = DemoPlace(
        id: id(11), name: "L'Artusi", category: "restaurant",
        neighborhood: "West Village", address: "228 W 10th St",
        latitude: 40.7338, longitude: -74.0050
    )
    private static let laCabra = DemoPlace(
        id: id(12), name: "La Cabra", category: "cafe",
        neighborhood: "SoHo", address: "152 Elizabeth St",
        latitude: 40.7206, longitude: -73.9946
    )
    private static let deadRabbit = DemoPlace(
        id: id(13), name: "The Dead Rabbit", category: "bar",
        neighborhood: "Financial District", address: "30 Water St",
        latitude: 40.7033, longitude: -74.0110
    )
    private static let attaboy = DemoPlace(
        id: id(14), name: "Attaboy", category: "bar",
        neighborhood: "Lower East Side", address: "134 Eldridge St",
        latitude: 40.7195, longitude: -73.9913
    )
    private static let radioBakery = DemoPlace(
        id: id(15), name: "Radio Bakery", category: "bakery",
        neighborhood: "Greenpoint", address: "135 India St",
        latitude: 40.7324, longitude: -73.9553
    )
    private static let princeStreet = DemoPlace(
        id: id(16), name: "Prince Street Pizza", category: "restaurant",
        neighborhood: "Nolita", address: "27 Prince St",
        latitude: 40.7231, longitude: -73.9946
    )
    private static let dante = DemoPlace(
        id: id(17), name: "Dante", category: "bar",
        neighborhood: "Greenwich Village", address: "79-81 Macdougal St",
        latitude: 40.7289, longitude: -74.0018
    )
    private static let katz = DemoPlace(
        id: id(18), name: "Katz's Delicatessen", category: "restaurant",
        neighborhood: "Lower East Side", address: "205 E Houston St",
        latitude: 40.7223, longitude: -73.9874
    )
    private static let reggio = DemoPlace(
        id: id(19), name: "Caffe Reggio", category: "cafe",
        neighborhood: "Greenwich Village", address: "119 Macdougal St",
        latitude: 40.7303, longitude: -74.0002
    )
    private static let appart = DemoPlace(
        id: id(20), name: "L'Appartement 4F", category: "bakery",
        neighborhood: "Cobble Hill", address: "186 Sackett St",
        latitude: 40.6865, longitude: -73.9956
    )
    private static let odeon = DemoPlace(
        id: id(21), name: "The Odeon", category: "restaurant",
        neighborhood: "Tribeca", address: "145 W Broadway",
        latitude: 40.7170, longitude: -74.0078
    )
    private static let antico = DemoPlace(
        id: id(22), name: "All'Antico Vinaio", category: "restaurant",
        neighborhood: "Union Square", address: "15 E 15th St",
        latitude: 40.7366, longitude: -73.9915
    )
}

// MARK: - Catalog types

private struct DemoPerson {
    let id: UUID
    var username: String
    var displayName: String
    var bio: String
}

private struct DemoPlace {
    let id: UUID
    var name: String
    var category: String
    var neighborhood: String
    var address: String
    var latitude: Double
    var longitude: Double

    var summary: PlaceSummary {
        PlaceSummary(
            id: id,
            name: name,
            categoryRaw: category,
            neighborhood: neighborhood,
            streetAddress: address,
            latitude: latitude,
            longitude: longitude
        )
    }
}

// MARK: - Memberwise inits for Decodable DTOs

extension ProfileSearchResult {
    init(
        id: UUID,
        username: String?,
        displayName: String?,
        avatarURL: String?,
        bio: String?,
        relationship: RelationshipState,
        friendshipID: UUID?
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.bio = bio
        self.relationship = relationship
        self.friendshipID = friendshipID
    }
}

extension FriendVisit {
    init(
        visitID: UUID,
        visitedAt: Date,
        title: String?,
        summary: String?,
        transcript: String?,
        topQuote: String?,
        tags: [String],
        ratingLabel: String?,
        returnIntent: String?,
        kind: String,
        placeID: UUID,
        placeName: String,
        placeCategory: String?,
        neighborhood: String?,
        streetAddress: String?,
        latitude: Double,
        longitude: Double,
        userID: UUID,
        username: String?,
        displayName: String?,
        avatarURL: String?,
        photos: [FriendVisitPhoto],
        tagged: [TaggedPerson] = []
    ) {
        self.visitID = visitID
        self.visitedAt = visitedAt
        self.title = title
        self.summary = summary
        self.transcript = transcript
        self.topQuote = topQuote
        self.tags = tags
        self.ratingLabel = ratingLabel
        self.returnIntent = returnIntent
        self.kind = kind
        self.placeID = placeID
        self.placeName = placeName
        self.placeCategory = placeCategory
        self.neighborhood = neighborhood
        self.streetAddress = streetAddress
        self.latitude = latitude
        self.longitude = longitude
        self.userID = userID
        self.username = username
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.photos = photos
        self.tagged = tagged
    }
}

extension InboxRecommendation {
    init(
        id: UUID,
        status: RecommendationStatus,
        message: String?,
        createdAt: Date?,
        readAt: Date?,
        senderID: UUID,
        username: String?,
        displayName: String?,
        avatarURL: String?,
        place: PlaceSummary,
        alreadyVisited: Bool,
        onWishlist: Bool
    ) {
        self.id = id
        self.status = status
        self.message = message
        self.createdAt = createdAt
        self.readAt = readAt
        self.senderID = senderID
        self.username = username
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.place = place
        self.alreadyVisited = alreadyVisited
        self.onWishlist = onWishlist
    }
}

extension FeedItem {
    init(visit: FriendVisit, friendPlaceCount: Int) {
        self.visit = visit
        self.friendPlaceCount = friendPlaceCount
    }
}

extension RecommendationSendResult {
    init(recipientID: UUID, outcome: RecommendationOutcome, recommendationID: UUID?) {
        self.recipientID = recipientID
        self.outcome = outcome
        self.recommendationID = recommendationID
    }
}

extension ConversationThread {
    init(
        conversationID: UUID,
        userID: UUID,
        username: String?,
        displayName: String?,
        avatarURL: String?,
        createdAt: Date?,
        lastMessageAt: Date?,
        lastMessageBody: String?,
        lastMessageSenderID: UUID?,
        lastMessagePlaceName: String?,
        unreadCount: Int
    ) {
        self.conversationID = conversationID
        self.userID = userID
        self.username = username
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt
        self.lastMessageBody = lastMessageBody
        self.lastMessageSenderID = lastMessageSenderID
        self.lastMessagePlaceName = lastMessagePlaceName
        self.unreadCount = unreadCount
    }
}

extension ChatMessage {
    init(
        id: UUID,
        conversationID: UUID,
        senderID: UUID,
        body: String,
        createdAt: Date,
        username: String?,
        displayName: String?,
        avatarURL: String?,
        place: PlaceSummary?,
        visitID: UUID?,
        visitTitle: String?,
        visitTags: [String],
        ratingLabel: String?,
        photos: [FriendVisitPhoto]
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderID = senderID
        self.body = body
        self.createdAt = createdAt
        self.username = username
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.place = place
        self.visitID = visitID
        self.visitTitle = visitTitle
        self.visitTags = visitTags
        self.ratingLabel = ratingLabel
        self.photos = photos
    }
}
