import SwiftUI

/// Top-level friends page. Shows your friend list, recent activity from people you follow, places
/// trending across that graph, and a "find friends" section to add people. Tapping a friend
/// anywhere opens their profile inside the same stack, where you can also manage the friendship.
struct FriendsView: View {
    @State private var store = MockFriendsStore.shared
    @State private var showFindFriends = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    header
                    if store.myFriends.isEmpty {
                        emptyState
                    } else {
                        friendsSection
                        if !store.recentActivities().isEmpty {
                            recentActivitySection
                        }
                        if !trendingPlaces.isEmpty {
                            trendingSection
                        }
                    }
                    // Clear the floating bottom nav.
                    Color.clear.frame(height: 90)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.tap()
                        showFindFriends = true
                    } label: {
                        Label("Find friends", systemImage: "person.badge.plus")
                    }
                }
            }
            .navigationDestination(for: Friend.self) { friend in
                FriendDetailView(friend: friend)
            }
            .sheet(isPresented: $showFindFriends) {
                NavigationStack {
                    FindFriendsView()
                }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: -10) {
                ForEach(store.myFriends.prefix(5)) { friend in
                    FriendAvatar(friend: friend, size: 40)
                        .overlay(Circle().stroke(Color(uiColor: .systemGroupedBackground), lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(store.myFriends.count) \(store.myFriends.count == 1 ? "friend" : "friends")")
                    .font(.title3.weight(.semibold))
                Text("in your NYC graph")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var recentActivitySection: some View {
        FriendsSectionCard(title: "Recent activity", systemImage: "clock.arrow.circlepath") {
            VStack(spacing: 12) {
                ForEach(store.recentActivities()) { activity in
                    if let friend = store.friend(for: activity.friendID) {
                        NavigationLink(value: friend) {
                            FriendActivityRow(friend: friend, activity: activity)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var friendsSection: some View {
        FriendsSectionCard(title: "Your friends", systemImage: "person.2.fill") {
            VStack(spacing: 12) {
                ForEach(store.myFriends) { friend in
                    NavigationLink(value: friend) {
                        FriendCard(
                            friend: friend,
                            visitCount: store.activities(for: friend.id).filter { $0.kind == .visited }.count,
                            wantCount: store.activities(for: friend.id).filter { $0.kind == .wantToTry }.count
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            Haptics.tap()
                            withAnimation(.snappy) { store.removeFriend(friend) }
                        } label: {
                            Label("Remove friend", systemImage: "person.badge.minus")
                        }
                    }
                }
            }
        }
    }

    private var trendingPlaces: [FriendTrendingPlace] {
        store.trendingPlaces(minFriends: 2, limit: 5)
    }

    private var trendingSection: some View {
        FriendsSectionCard(title: "Trending among friends", systemImage: "chart.line.uptrend.xyaxis") {
            VStack(spacing: 10) {
                ForEach(trendingPlaces, id: \.self) { place in
                    TrendingPlaceRow(place: place)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("No friends yet")
                .font(.headline)
            Text("Find friends to see their activity and compare notes on places.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Haptics.tap()
                showFindFriends = true
            } label: {
                Label("Find friends", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Find friends

/// Directory of people you don't yet follow. Kept as its own sheet so the main Friends page stays
/// focused on people you've already added.
private struct FindFriendsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = MockFriendsStore.shared
    @State private var query: String = ""

    private var filtered: [Friend] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return store.suggested }
        return store.suggested.filter {
            $0.name.lowercased().contains(trimmed) || $0.handle.lowercased().contains(trimmed)
        }
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                Section {
                    Text(store.suggested.isEmpty ? "You've added everyone in your graph." : "No matches.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(filtered) { friend in
                        HStack(spacing: 12) {
                            FriendAvatar(friend: friend, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(friend.name).font(.headline)
                                Text("@\(friend.handle)").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                Haptics.tap()
                                withAnimation(.snappy) { store.addFriend(friend) }
                            } label: {
                                Label("Add", systemImage: "person.badge.plus")
                                    .labelStyle(.titleOnly)
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.glass)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Name or @handle")
        .navigationTitle("Find friends")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

// MARK: - Avatar

struct FriendAvatar: View {
    let friend: Friend
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [friend.avatarTint.opacity(0.85), friend.avatarTint.opacity(0.35)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            Image(systemName: friend.avatarSymbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Rows / cards

private struct FriendActivityRow: View {
    let friend: Friend
    let activity: FriendActivity

    var body: some View {
        HStack(spacing: 12) {
            FriendAvatar(friend: friend, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                (
                    Text(friend.name).fontWeight(.semibold)
                    + Text(activity.kind == .visited ? " visited " : " wants to try ").foregroundColor(.secondary)
                    + Text(activity.placeName).fontWeight(.semibold)
                )
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)

                HStack(spacing: 6) {
                    Text(activity.neighborhood)
                    Text("•")
                    Text(daysAgoLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let rating = activity.rating {
                Image(systemName: rating.symbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var daysAgoLabel: String {
        activity.daysAgo == 0 ? "today" : "\(activity.daysAgo)d ago"
    }
}

struct FriendCard: View {
    let friend: Friend
    let visitCount: Int
    let wantCount: Int

    var body: some View {
        HStack(spacing: 12) {
            FriendAvatar(friend: friend, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(friend.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("@\(friend.handle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(friend.bio)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Label("\(visitCount)", systemImage: "checkmark.seal.fill")
                Label("\(wantCount)", systemImage: "bookmark.fill")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .fixedSize()
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }
}

private struct TrendingPlaceRow: View {
    let place: FriendTrendingPlace

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: categorySymbol)
                .font(.subheadline)
                .foregroundStyle(categoryTint)
                .frame(width: 32, height: 32)
                .background(Circle().fill(categoryTint.opacity(0.15)))

            VStack(alignment: .leading, spacing: 2) {
                Text(place.placeName).font(.subheadline.weight(.semibold))
                Text(place.neighborhood).font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            HStack(spacing: -8) {
                ForEach(place.friends.prefix(3)) { friend in
                    FriendAvatar(friend: friend, size: 24)
                        .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 2))
                }
            }
            Text("\(place.friends.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var categorySymbol: String {
        switch place.category {
        case .restaurant: "fork.knife"
        case .bar:        "wineglass.fill"
        case .cafe:       "cup.and.saucer.fill"
        case .bakery:     "birthday.cake.fill"
        case .other:      "mappin"
        }
    }

    private var categoryTint: Color {
        switch place.category {
        case .restaurant: .orange
        case .bar:        .purple
        case .cafe:       .brown
        case .bakery:     .pink
        case .other:      .gray
        }
    }
}

// MARK: - Section card (shared with FriendDetailView)

struct FriendsSectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }
}
