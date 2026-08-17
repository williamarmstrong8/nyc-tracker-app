import SwiftUI

/// The map's "whose places am I looking at" picker.
///
/// Presented from the filter menu rather than as its own floating pill. A sheet
/// rather than a menu of friends, because the requirement is that it stays
/// usable at 50 friends — a nested menu can't hold 50 of anything.
struct MapAudiencePicker: View {
    @Environment(SocialGraph.self) private var graph
    @Environment(MapAudienceStore.self) private var audience
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    private var filteredFriends: [FriendshipEdge] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return graph.friends }
        return graph.friends.filter { edge in
            edge.person.bestName.lowercased().contains(trimmed)
                || (edge.person.username?.lowercased().contains(trimmed) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    modeRow(
                        .mine,
                        title: "My places",
                        subtitle: "Only what you've logged. Works offline.",
                        symbol: "person.fill"
                    )
                    modeRow(
                        .allFriends,
                        title: "All friends",
                        subtitle: friendsSubtitle,
                        symbol: "person.2.fill"
                    )
                    .disabled(graph.friends.isEmpty)
                }

                if graph.friends.isEmpty {
                    Section {
                        // Not a blank list: with no friends, "all friends" is a
                        // mode with nothing behind it, and saying so beats an
                        // empty map that looks broken.
                        Text("Add friends to see their places here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("One friend") {
                        ForEach(filteredFriends) { edge in
                            friendRow(edge)
                        }
                        if filteredFriends.isEmpty {
                            Text("No friends match \u{201C}\(query)\u{201D}.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .appSearchable(text: $query, prompt: "Search friends")
            .navigationTitle("Show on map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var friendsSubtitle: String {
        graph.friends.isEmpty
            ? "No friends yet"
            : "Only their places — not yours."
    }

    private func modeRow(
        _ mode: MapAudience,
        title: String,
        subtitle: String,
        symbol: String
    ) -> some View {
        Button {
            Haptics.tap()
            audience.select(mode)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.subheadline)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if audience.audience == mode {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func friendRow(_ edge: FriendshipEdge) -> some View {
        Button {
            Haptics.tap()
            audience.select(.friend(edge.userID))
            dismiss()
        } label: {
            HStack(spacing: 12) {
                PersonAvatar(person: edge.person, size: 36, showsPaletteRing: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(edge.person.bestName).font(.body).lineLimit(1)
                    if let handle = edge.person.handle {
                        Text(handle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if audience.audience == .friend(edge.userID) {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
