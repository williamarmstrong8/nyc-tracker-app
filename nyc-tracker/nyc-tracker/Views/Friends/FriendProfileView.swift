import SwiftUI
import Charts

/// Someone else's profile, laid out like the signed-in Profile page: centered
/// identity, glanceable counts, then a photo grid of where they've been.
///
/// Header counts are display-only — there is no list of their friends or visits
/// to open from here. Activity photos still open the visit.
struct FriendProfileView: View {
    let person: PersonSummary

    @Environment(SocialGraph.self) private var graph
    @Environment(MapAudienceStore.self) private var audience
    @Environment(AppRouter.self) private var router

    @State private var summary: FriendProfileSummary?
    @State private var friendCount = 0
    @State private var visits: [FriendVisit] = []
    @State private var loadState: LoadState = .loading
    @State private var isMutating = false
    @State private var openedVisit: FriendVisit?
    @State private var confirmingUnfriend = false

    @State private var tab: ProfileTab = .activity
    /// Entries other people tagged this person in. Loaded alongside their own,
    /// so switching tabs never waits on a request.
    @State private var taggedVisits: [FriendVisit] = []

    private static let contentMargin: CGFloat = 20

    private enum LoadState: Equatable {
        case loading
        case loaded
        /// The profile came back with zero rows — the account is gone.
        case missing
        case failed(String)
    }

    private var snapshot: RelationshipSnapshot {
        graph.snapshot(for: person.id)
    }

    private var displayPerson: PersonSummary {
        summary?.person ?? person
    }

    private var visitedVisits: [FriendVisit] {
        visits.filter { $0.visitKind == .visited }
    }

    private var wantToTryVisits: [FriendVisit] {
        visits.filter { $0.visitKind == .wantToTry }
    }

    private var beenCount: Int {
        summary?.visitCount ?? visitedVisits.count
    }

    private var wantToTryCount: Int {
        summary?.wantToTryCount ?? wantToTryVisits.count
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                identitySection
                    .padding(.horizontal, Self.contentMargin)

                if loadState != .missing {
                    actionRow
                        .padding(.horizontal, Self.contentMargin)
                }

                switch loadState {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)

                case .missing:
                    missingAccountState
                        .padding(.horizontal, Self.contentMargin)

                case .failed(let message):
                    failureState(message)
                        .padding(.horizontal, Self.contentMargin)

                case .loaded:
                    categorySection
                        .padding(.horizontal, Self.contentMargin)
                    activitySection
                }
            }
            .padding(.vertical, 16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(displayPerson.bestName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if snapshot.state == .friends {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            Haptics.tap()
                            confirmingUnfriend = true
                        } label: {
                            Label("Remove friend", systemImage: "person.badge.minus")
                        }
                        .disabled(isMutating)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .confirmationDialog(
            "Remove \(displayPerson.bestName) from your friends?",
            isPresented: $confirmingUnfriend,
            titleVisibility: .visible
        ) {
            Button("Remove friend", role: .destructive) {
                handle(.unfriend)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their places disappear from your map. They aren't notified.")
        }
        .task(id: person.id) { await load() }
        .refreshable { await load() }
        .sheet(item: $openedVisit) { visit in
            FriendVisitDetailSheet(visit: visit)
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        VStack(spacing: 10) {
            PersonAvatar(person: displayPerson, size: 108)
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)

            VStack(spacing: 3) {
                Text(displayPerson.bestName)
                    .font(.title3.weight(.semibold))
                if let handle = displayPerson.handle {
                    Text(handle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let bio = summary?.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
            }

            ProfileHeaderStats(
                friendCount: friendCount,
                beenCount: beenCount,
                wantToTryCount: wantToTryCount
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var actionRow: some View {
        switch snapshot.state {
        case .isSelf:
            EmptyView()

        case .friends:
            Button {
                Haptics.tap()
                audience.select(.friend(person.id))
                router.showMap()
            } label: {
                Label("View on map", systemImage: "map")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glass)

        default:
            RelationshipButton(
                person: displayPerson,
                relationship: snapshot.state,
                isBusy: isMutating,
                isCompact: false
            ) { action in
                handle(action)
            }
        }
    }

    // MARK: - Category donut

    @ViewBuilder
    private var categorySection: some View {
        if !categoryBreakdown.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Where they've been")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 28) {
                    Chart(categoryBreakdown, id: \.category) { item in
                        SectorMark(
                            angle: .value("Count", item.count),
                            innerRadius: .ratio(0.68),
                            angularInset: 2
                        )
                        .cornerRadius(4)
                        .foregroundStyle(categoryTint(for: item.category))
                    }
                    .frame(width: 132, height: 132)
                    .chartBackground { _ in
                        VStack(spacing: 1) {
                            Text("\(visitedVisits.count)")
                                .font(.title2.weight(.bold))
                            Text(visitedVisits.count == 1 ? "place" : "places")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("\(visitedVisits.count) places visited")

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(categoryBreakdown, id: \.category) { item in
                            HStack(spacing: 8) {
                                Image(systemName: categorySymbol(for: item.category))
                                    .font(.caption2)
                                    .foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(categoryTint(for: item.category)))
                                Text(categoryLabel(for: item.category))
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text("\(item.count)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var categoryBreakdown: [(category: PlaceCategory, count: Int)] {
        let grouped = Dictionary(grouping: visitedVisits) { $0.category }
        return PlaceCategory.allCases
            .compactMap { category -> (category: PlaceCategory, count: Int)? in
                let count = grouped[category]?.count ?? 0
                return count > 0 ? (category, count) : nil
            }
            .sorted { $0.count > $1.count }
    }

    // MARK: - Activity

    @ViewBuilder
    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProfileTabPicker(selection: $tab)
                .padding(.horizontal, Self.contentMargin)

            grid(for: tab == .activity ? visitedVisits : taggedVisits,
                 showsAuthor: tab == .tagged)
        }
    }

    private static let gridColumns = [
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3),
        GridItem(.flexible(), spacing: 3)
    ]

    /// One grid for both tabs. `showsAuthor` is the only difference: on the
    /// Tagged tab the entries belong to other people, and whose they are is
    /// the first thing worth knowing about them.
    @ViewBuilder
    private func grid(for rows: [FriendVisit], showsAuthor: Bool) -> some View {
        if rows.isEmpty {
            emptyState(for: tab)
                .padding(.horizontal, Self.contentMargin)
        } else {
            LazyVGrid(columns: Self.gridColumns, spacing: 3) {
                ForEach(rows) { visit in
                    Button {
                        Haptics.tap()
                        openedVisit = visit
                    } label: {
                        activityCell(for: visit)
                            .overlay(alignment: .bottomLeading) {
                                if showsAuthor {
                                    PersonAvatar(person: visit.person, size: 20)
                                        .overlay {
                                            Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1)
                                        }
                                        .padding(5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 1)
        }
    }

    @ViewBuilder
    private func emptyState(for tab: ProfileTab) -> some View {
        switch tab {
        case .activity:
            activityEmptyState
        case .tagged:
            VStack(spacing: 8) {
                Image(systemName: "person.2")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
                Text("\(displayPerson.shortName) hasn't been tagged in anything yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    private func activityCell(for visit: FriendVisit) -> some View {
        let photo = visit.photos.sorted(by: { $0.sortOrder < $1.sortOrder }).first
        return Group {
            if let photo {
                PhotoView(source: .friendPhoto(path: photo.smallestPath), contentMode: .fill)
            } else {
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipped()
    }

    private var activityEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("\(displayPerson.shortName) hasn't logged any visits yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var missingAccountState: some View {
        emptyBlock(
            symbol: "person.crop.circle.badge.xmark",
            title: "Account no longer available",
            message: "This person deleted their account. Their places are gone too."
        )
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("Couldn't load this profile")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") {
                Task { await load() }
            }
            .buttonStyle(.glass)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func emptyBlock(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: - Loading

    private func load() async {
        let showSpinner = summary == nil && visits.isEmpty
        if showSpinner { loadState = .loading }

        do {
            guard let profile = try await FriendshipService.profile(of: person.id) else {
                summary = nil
                visits = []
                friendCount = 0
                loadState = .missing
                return
            }
            summary = profile

            async let loadedVisits = FriendshipService.visits(of: person.id)
            async let loadedFriendCount = FriendshipService.acceptedFriendCount(of: person.id)
            async let loadedTagged = VisitTagService.taggedVisits(of: person.id)
            visits = try await loadedVisits
            friendCount = (try? await loadedFriendCount) ?? friendCount
            // Not `try`: an empty Tagged tab is a fine outcome, and it should
            // not be able to fail the profile the user actually asked for.
            taggedVisits = (try? await loadedTagged) ?? []
            loadState = .loaded
        } catch {
            loadState = .failed(
                SupabaseErrorPresenter.presentable(error, context: .general).message
            )
        }
    }

    // MARK: - Actions

    private func handle(_ action: RelationshipAction) {
        Task {
            isMutating = true
            defer { isMutating = false }

            switch action {
            case .add:
                if await graph.sendRequest(to: person.id) == .becameFriends {
                    Haptics.success()
                }
            case .accept:
                guard let id = snapshot.friendshipID else { return }
                if await graph.accept(id) { Haptics.success() }
            case .cancel, .decline, .unfriend:
                guard let id = snapshot.friendshipID else { return }
                await graph.remove(id)
            }
        }
    }

    // MARK: - Style helpers

    private func categoryTint(for category: PlaceCategory) -> Color {
        switch category {
        case .restaurant: .orange
        case .bar:        .purple
        case .cafe:       .brown
        case .bakery:     .pink
        case .other:      .gray
        }
    }

    private func categorySymbol(for category: PlaceCategory) -> String {
        switch category {
        case .restaurant: "fork.knife"
        case .bar:        "wineglass.fill"
        case .cafe:       "cup.and.saucer.fill"
        case .bakery:     "birthday.cake.fill"
        case .other:      "mappin"
        }
    }

    private func categoryLabel(for category: PlaceCategory) -> String {
        switch category {
        case .restaurant: "Restaurants"
        case .bar:        "Bars"
        case .cafe:       "Cafes"
        case .bakery:     "Bakeries"
        case .other:      "Other"
        }
    }
}
