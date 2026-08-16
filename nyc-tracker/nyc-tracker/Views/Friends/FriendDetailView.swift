import SwiftUI
import SwiftData

/// Individual friend profile. Header + follow/unfollow toggle + mutual-places banner + their
/// visited list and want-to-try list.
struct FriendDetailView: View {
    let friend: Friend

    @State private var store = MockFriendsStore.shared
    @Query(sort: [SortDescriptor(\Visit.visitedOn, order: .reverse)]) private var myVisits: [Visit]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !mutualPlaces.isEmpty || !mutualWantToTry.isEmpty {
                    mutualSection
                }
                if !visitedActivities.isEmpty {
                    visitedSection
                }
                if !wantToTryActivities.isEmpty {
                    wantToTrySection
                }
                if visitedActivities.isEmpty && wantToTryActivities.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(friend.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var visitedActivities: [FriendActivity] {
        store.activities(for: friend.id).filter { $0.kind == .visited }
    }
    private var wantToTryActivities: [FriendActivity] {
        store.activities(for: friend.id).filter { $0.kind == .wantToTry }
    }

    /// Places I've logged where this friend has also been. Loose name match, either direction.
    private var mutualPlaces: [(mine: Visit, theirs: FriendActivity)] {
        let theirVisited = visitedActivities
        return myVisits.compactMap { visit -> (Visit, FriendActivity)? in
            let name = (visit.place?.name ?? visit.title).lowercased().trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            guard let match = theirVisited.first(where: { $0.placeName.lowercased().trimmingCharacters(in: .whitespaces) == name }) else {
                return nil
            }
            return (visit, match)
        }
    }

    private var mutualWantToTry: [(mine: Visit, theirs: FriendActivity)] {
        let theirWant = wantToTryActivities
        return myVisits.compactMap { visit -> (Visit, FriendActivity)? in
            let name = (visit.place?.name ?? visit.title).lowercased().trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            guard let match = theirWant.first(where: { $0.placeName.lowercased().trimmingCharacters(in: .whitespaces) == name }) else {
                return nil
            }
            return (visit, match)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                FriendAvatar(friend: friend, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(friend.name)
                        .font(.title3.weight(.semibold))
                    Text("@\(friend.handle) · \(friend.neighborhood)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(friend.bio)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                statPill(value: visitedActivities.count, label: "visited", symbol: "checkmark.seal.fill")
                statPill(value: wantToTryActivities.count, label: "want to try", symbol: "bookmark.fill")
                Spacer()
            }

            followButton
        }
    }

    @ViewBuilder
    private var followButton: some View {
        let label = Label(
            isFriend ? "Friends" : "Add friend",
            systemImage: isFriend ? "person.fill.checkmark" : "person.badge.plus"
        )
        .frame(maxWidth: .infinity, minHeight: 44)

        if isFriend {
            Button {
                Haptics.tap()
                withAnimation(.snappy) { store.toggleFriend(friend) }
            } label: { label }
                .buttonStyle(.glass)
        } else {
            Button {
                Haptics.tap()
                withAnimation(.snappy) { store.toggleFriend(friend) }
            } label: { label }
                .buttonStyle(.glassProminent)
        }
    }

    private var isFriend: Bool { store.isFriend(friend) }

    private func statPill(value: Int, label: String, symbol: String) -> some View {
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

    private var mutualSection: some View {
        FriendsSectionCard(title: "You + \(firstName)", systemImage: "person.2.wave.2.fill") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(mutualPlaces, id: \.mine.id) { pair in
                    mutualRow(name: pair.mine.place?.name ?? pair.mine.title, note: "You've both been here")
                }
                ForEach(mutualWantToTry, id: \.mine.id) { pair in
                    mutualRow(name: pair.mine.place?.name ?? pair.mine.title, note: "Both on your want-to-try lists")
                }
            }
        }
    }

    private var firstName: String {
        friend.name.split(separator: " ").first.map(String.init) ?? friend.name
    }

    private func mutualRow(name: String, note: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.subheadline)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.subheadline.weight(.semibold))
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var visitedSection: some View {
        FriendsSectionCard(title: "Places they've been", systemImage: "checkmark.seal.fill") {
            VStack(spacing: 10) {
                ForEach(visitedActivities) { activity in
                    FriendPlaceRow(activity: activity)
                }
            }
        }
    }

    private var wantToTrySection: some View {
        FriendsSectionCard(title: "Want to try", systemImage: "bookmark.fill") {
            VStack(spacing: 10) {
                ForEach(wantToTryActivities) { activity in
                    FriendPlaceRow(activity: activity)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("No activity yet")
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Row

private struct FriendPlaceRow: View {
    let activity: FriendActivity

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: categorySymbol)
                .font(.subheadline)
                .foregroundStyle(categoryTint)
                .frame(width: 32, height: 32)
                .background(Circle().fill(categoryTint.opacity(0.15)))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(activity.placeName).font(.subheadline.weight(.semibold))
                    if let rating = activity.rating {
                        Image(systemName: rating.symbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(activity.neighborhood)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let quote = activity.quote {
                    Text("\u{201C}\(quote)\u{201D}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                }
                if !activity.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(activity.tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var categorySymbol: String {
        switch activity.category {
        case .restaurant: "fork.knife"
        case .bar:        "wineglass.fill"
        case .cafe:       "cup.and.saucer.fill"
        case .bakery:     "birthday.cake.fill"
        case .other:      "mappin"
        }
    }

    private var categoryTint: Color {
        switch activity.category {
        case .restaurant: .orange
        case .bar:        .purple
        case .cafe:       .brown
        case .bakery:     .pink
        case .other:      .gray
        }
    }
}
