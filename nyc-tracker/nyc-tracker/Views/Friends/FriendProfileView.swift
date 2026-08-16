import SwiftUI

/// Someone else's profile: who they are, what they've logged, and one control to
/// change the relationship.
///
/// Straightforward reads, because everything is public. No permission branching,
/// no redaction, no "friends only" section — `isFriend` exists to decide which
/// button to draw and nothing else.
///
/// Takes a `PersonSummary` rather than a user ID so the header can render
/// immediately from what the caller already knew, and fill in stats when they
/// arrive. Pushing to a spinner when the name is already on screen is a
/// self-inflicted wait.
struct FriendProfileView: View {
    let person: PersonSummary

    @Environment(SocialGraph.self) private var graph
    @Environment(MapAudienceStore.self) private var audience
    @Environment(AppRouter.self) private var router
    @Environment(SocialStatsCache.self) private var stats

    @State private var summary: FriendProfileSummary?
    @State private var overlap: FriendOverlap?
    @State private var visits: [FriendVisit] = []
    @State private var loadState: LoadState = .loading
    @State private var isMutating = false

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                switch loadState {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)

                case .missing:
                    missingAccountState

                case .failed(let message):
                    failureState(message)

                case .loaded:
                    if let overlap, overlap.placesInCommon > 0 {
                        overlapSection(overlap)
                    }
                    if visits.isEmpty {
                        noVisitsState
                    } else {
                        visitsSection
                    }
                }

                // Clear the floating bottom nav.
                Color.clear.frame(height: 90)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(person.bestName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: person.id) { await load() }
        .refreshable { await load() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                PersonAvatar(person: person, size: 72, showsPaletteRing: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(person.bestName)
                        .font(.title3.weight(.semibold))
                    if let handle = person.handle {
                        Text(handle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let bio = summary?.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }

            if let summary, loadState == .loaded {
                statsRow(summary)
            }

            if loadState != .missing {
                actionRow
            }
        }
    }

    private func statsRow(_ summary: FriendProfileSummary) -> some View {
        HStack(spacing: 8) {
            statPill(summary.visitCount, "visits", "checkmark.seal.fill")
            statPill(summary.placeCount, "places", "mappin.and.ellipse")
            statPill(summary.wantToTryCount, "want to try", "bookmark.fill")
            Spacer(minLength: 0)
        }
    }

    private func statPill(_ value: Int, _ label: String, _ symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text("\(value)").fontWeight(.semibold)
            Text(label).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }

    @ViewBuilder
    private var actionRow: some View {
        // `isSelf` renders no relationship control at all, which would leave an
        // empty row — so the whole thing is skipped rather than laid out empty.
        if snapshot.state != .isSelf {
            VStack(spacing: 10) {
                RelationshipButton(
                    person: person,
                    relationship: snapshot.state,
                    isBusy: isMutating,
                    isCompact: false
                ) { action in
                    handle(action)
                }

                // Only offered for actual friends: the map filter's modes are
                // "mine" and "friends", and pointing it at a non-friend would ask
                // for a mode that does not exist.
                if snapshot.state == .friends {
                    Button {
                        Haptics.tap()
                        audience.select(.friend(person.id))
                        router.showMap()
                    } label: {
                        Label("View on map", systemImage: "map")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    // MARK: - Sections

    /// Places you have both been. Computed server-side because the local mirror
    /// holds only the user's own visits and knows nothing about theirs.
    private func overlapSection(_ overlap: FriendOverlap) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("\(pluralized(overlap.placesInCommon, "place")) in common")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }

            FlowLayout(spacing: 6) {
                ForEach(overlap.commonPlaces.prefix(12)) { place in
                    Text(place.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                }
            }

            if overlap.commonPlaces.count > 12 {
                Text("+ \(overlap.commonPlaces.count - 12) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private var visitsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Places they've been")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(visits) { visit in
                FriendVisitCard(visit: visit, showsAuthor: false)
            }
        }
    }

    private var noVisitsState: some View {
        emptyBlock(
            symbol: "map",
            title: "Nothing logged yet",
            message: "\(person.shortName) hasn't added any places."
        )
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
        loadState = .loading
        do {
            // Sequential rather than concurrent on purpose: if the profile is
            // gone there is nothing to list, and firing both would spend a
            // request to find that out.
            guard let profile = try await FriendshipService.profile(of: person.id) else {
                summary = nil
                visits = []
                loadState = .missing
                return
            }
            summary = profile
            visits = try await FriendshipService.visits(of: person.id)
            loadState = .loaded

            // After the content, not alongside it: the overlap is a nice-to-have
            // strip and shouldn't hold up the profile. Cached with a short TTL,
            // so revisiting a friend is usually free.
            overlap = await stats.overlap(with: person.id)
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
}
