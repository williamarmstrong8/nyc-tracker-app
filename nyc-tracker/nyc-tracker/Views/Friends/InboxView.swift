import SwiftUI

// ============================================================================
// The inbox is a container, and this is the task it was built for.
// ============================================================================
// Adding recommendations cost exactly what the last task predicted: one
// `InboxCategory` case, two `InboxItem` cases, one row builder branch. Nothing
// about friend requests changed, and the badge picked up the second term
// because `SocialGraph.inboxBadgeCount` was written as a sum from the start.
// ============================================================================

/// A kind of thing the inbox can hold.
enum InboxCategory: String, CaseIterable, Identifiable, Hashable {
    case requests
    case recommendations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .requests:        "Requests"
        case .recommendations: "Places"
        }
    }

    var symbol: String {
        switch self {
        case .requests:        "person.crop.circle.badge.questionmark"
        case .recommendations: "mappin.and.ellipse"
        }
    }
}

/// One entry in the inbox.
///
/// Outgoing requests are entries too, even though they need no response — they
/// belong to the same mental model ("things in flight between me and other
/// people") and putting them anywhere else means a user who wants to cancel one
/// has to guess where it lives.
enum InboxItem: Identifiable, Hashable {
    case incomingRequest(FriendshipEdge)
    case outgoingRequest(FriendshipEdge)
    case recommendation(InboxRecommendation)

    var id: String {
        switch self {
        case .incomingRequest(let edge): "in-\(edge.friendshipID.uuidString)"
        case .outgoingRequest(let edge): "out-\(edge.friendshipID.uuidString)"
        case .recommendation(let rec):   "rec-\(rec.id.uuidString)"
        }
    }

    var category: InboxCategory {
        switch self {
        case .incomingRequest, .outgoingRequest: .requests
        case .recommendation:                    .recommendations
        }
    }

    var person: PersonSummary {
        switch self {
        case .incomingRequest(let edge), .outgoingRequest(let edge): edge.person
        case .recommendation(let rec):                              rec.sender
        }
    }

    var sortDate: Date {
        switch self {
        case .incomingRequest(let edge), .outgoingRequest(let edge):
            edge.createdAt ?? .distantPast
        case .recommendation(let rec):
            rec.createdAt ?? .distantPast
        }
    }

    /// Counts toward the badge. Only things awaiting *this* user's attention do —
    /// a request you sent is not a task on your list, and a recommendation you
    /// have already read is not either.
    var isActionable: Bool {
        switch self {
        case .incomingRequest:         true
        case .outgoingRequest:         false
        case .recommendation(let rec): rec.isUnread
        }
    }
}

/// The inbox surface.
struct InboxView: View {
    @Environment(SocialGraph.self) private var graph

    /// `nil` means "everything".
    @State private var selectedCategory: InboxCategory?
    @State private var busyPersonID: UUID?
    @State private var openedPlace: PlaceSummary?

    /// Batched so a scroll past ten rows is one request, not ten.
    @State private var pendingReadIDs: Set<UUID> = []
    @State private var readFlushTask: Task<Void, Never>?

    private var showsCategoryPicker: Bool { InboxCategory.allCases.count > 1 }

    private var incomingItems: [InboxItem] {
        graph.incoming.map(InboxItem.incomingRequest).sorted { $0.sortDate > $1.sortDate }
    }

    private var outgoingItems: [InboxItem] {
        graph.outgoing.map(InboxItem.outgoingRequest).sorted { $0.sortDate > $1.sortDate }
    }

    private var recommendationItems: [InboxItem] {
        graph.recommendations.map(InboxItem.recommendation).sorted { $0.sortDate > $1.sortDate }
    }

    private func isVisible(_ category: InboxCategory) -> Bool {
        selectedCategory == nil || selectedCategory == category
    }

    var body: some View {
        List {
            if showsCategoryPicker {
                categoryPicker
            }

            if isVisible(.recommendations), !recommendationItems.isEmpty {
                Section("Places from friends") {
                    ForEach(recommendationItems) { row(for: $0) }
                }
            }

            if isVisible(.requests) {
                if !incomingItems.isEmpty {
                    Section("Friend requests") {
                        ForEach(incomingItems) { row(for: $0) }
                    }
                }
                if !outgoingItems.isEmpty {
                    Section("Sent") {
                        ForEach(outgoingItems) { row(for: $0) }
                    }
                }
            }

            if isEmpty {
                emptySection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await graph.reload() }
        .task { graph.refresh() }
        .onDisappear { flushReadsNow() }
        .sheet(item: $openedPlace) { place in
            RecommendedPlaceSheet(place: place)
        }
    }

    private var isEmpty: Bool {
        incomingItems.isEmpty && outgoingItems.isEmpty && recommendationItems.isEmpty
    }

    private var categoryPicker: some View {
        Picker("Show", selection: $selectedCategory) {
            Text("All").tag(InboxCategory?.none)
            ForEach(InboxCategory.allCases) { category in
                Text(category.title).tag(InboxCategory?.some(category))
            }
        }
        .pickerStyle(.segmented)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .padding(.vertical, 4)
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for item: InboxItem) -> some View {
        switch item {
        case .incomingRequest(let edge):
            requestRow(edge: edge, caption: "Wants to be friends", relationship: .incoming)
        case .outgoingRequest(let edge):
            requestRow(edge: edge, caption: "Request sent", relationship: .outgoing)
        case .recommendation(let rec):
            recommendationRow(rec)
        }
    }

    private func recommendationRow(_ rec: InboxRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                NavigationLink(value: rec.sender) {
                    HStack(spacing: 10) {
                        PersonAvatar(person: rec.sender, size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rec.sender.bestName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if let date = rec.createdAt {
                                Text(date.formatted(.relative(presentation: .named)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if rec.isUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Unread")
                }
            }

            Button {
                Haptics.tap()
                openedPlace = rec.place
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: categorySymbol(rec.place.category))
                        .font(.subheadline)
                        .foregroundStyle(categoryTint(rec.place.category))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(categoryTint(rec.place.category).opacity(0.15)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rec.place.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let subtitle = rec.place.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let message = rec.message, !message.isEmpty {
                Text("\u{201C}\(message)\u{201D}")
                    .font(.subheadline.italic())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The sender's gesture still lands even when it's redundant — saying
            // so is friendlier than silently doing nothing with it.
            if rec.alreadyVisited {
                Label("You've already been here", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if rec.onWishlist {
                Label("On your wishlist", systemImage: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        // Read on visible, not on tap: seeing "Dev sent you Lucali" in the list
        // IS receiving it, and requiring a tap leaves the badge lit for something
        // already read.
        .onAppear { scheduleRead(rec) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await graph.dismissRecommendation(rec.id) }
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
        }
        .contextMenu {
            Button {
                openedPlace = rec.place
            } label: {
                Label("View place", systemImage: "mappin.and.ellipse")
            }
            Button(role: .destructive) {
                Task { await graph.dismissRecommendation(rec.id) }
            } label: {
                // Named explicitly, because the two are separate decisions and
                // people reasonably assume dismissing also unsaves.
                Label("Dismiss (keeps wishlist)", systemImage: "xmark")
            }
        }
    }

    private func requestRow(
        edge: FriendshipEdge,
        caption: String,
        relationship: RelationshipState
    ) -> some View {
        HStack(spacing: 12) {
            NavigationLink(value: edge.person) {
                HStack(spacing: 12) {
                    PersonAvatar(person: edge.person, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(edge.person.bestName)
                            .font(.headline)
                            .lineLimit(1)
                        Text(subtitle(caption: caption, date: edge.createdAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            RelationshipButton(
                person: edge.person,
                relationship: relationship,
                isBusy: busyPersonID == edge.userID
            ) { action in
                handle(action, edge: edge)
            }
        }
        .padding(.vertical, 4)
    }

    private func subtitle(caption: String, date: Date?) -> String {
        guard let date else { return caption }
        return "\(caption) · \(date.formatted(.relative(presentation: .named)))"
    }

    private var emptySection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Nothing waiting")
                    .font(.headline)
                Text("Friend requests and places friends send you show up here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Read batching

    /// Collect ids as rows appear and flush shortly after the scroll settles.
    ///
    /// One request per visible row would mean ten calls to scroll a screen. The
    /// short delay also avoids marking something read that merely flickered past
    /// during a fling.
    private func scheduleRead(_ rec: InboxRecommendation) {
        guard rec.isUnread else { return }
        pendingReadIDs.insert(rec.id)

        readFlushTask?.cancel()
        readFlushTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            flushReadsNow()
        }
    }

    private func flushReadsNow() {
        readFlushTask?.cancel()
        readFlushTask = nil
        guard !pendingReadIDs.isEmpty else { return }
        let ids = Array(pendingReadIDs)
        pendingReadIDs.removeAll()
        graph.markRecommendationsRead(ids)
    }

    // MARK: - Actions

    private func handle(_ action: RelationshipAction, edge: FriendshipEdge) {
        Task {
            busyPersonID = edge.userID
            defer { busyPersonID = nil }

            switch action {
            case .accept:
                if await graph.accept(edge.friendshipID) { Haptics.success() }
            case .cancel, .decline, .unfriend:
                await graph.remove(edge.friendshipID)
            case .add:
                if await graph.sendRequest(to: edge.userID) == .becameFriends {
                    Haptics.success()
                }
            }
        }
    }

    private func categorySymbol(_ category: PlaceCategory) -> String {
        switch category {
        case .restaurant: "fork.knife"
        case .bar:        "wineglass.fill"
        case .cafe:       "cup.and.saucer.fill"
        case .bakery:     "birthday.cake.fill"
        case .other:      "mappin"
        }
    }

    private func categoryTint(_ category: PlaceCategory) -> Color {
        switch category {
        case .restaurant: .orange
        case .bar:        .purple
        case .cafe:       .brown
        case .bakery:     .pink
        case .other:      .gray
        }
    }
}
