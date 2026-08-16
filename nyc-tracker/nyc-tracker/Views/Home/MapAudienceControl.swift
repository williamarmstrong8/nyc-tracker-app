import SwiftUI

/// The map's "whose places am I looking at" control.
///
/// A single glass pill that names the current audience and opens a sheet, rather
/// than a segmented control with a picker hanging off it. The requirement is
/// that it stays usable at 50 friends, and a segment can't hold 50 of anything —
/// the third mode would immediately become "…and a menu", which is a sheet with
/// extra steps. The pill also has room to say *whose* map you are on, which is
/// the thing you most want to know at a glance when the answer isn't "mine".
struct MapAudienceControl: View {
    @Environment(SocialGraph.self) private var graph
    @Environment(MapAudienceStore.self) private var audience

    @State private var showPicker = false

    private var label: String {
        switch audience.audience {
        case .mine:
            "My places"
        case .allFriends:
            "Friends"
        case .friend(let id):
            graph.friend(withID: id)?.person.shortName ?? "Friend"
        }
    }

    private var symbol: String {
        switch audience.audience {
        case .mine:       "person.fill"
        case .allFriends: "person.2.fill"
        case .friend:     "person.crop.circle.fill"
        }
    }

    var body: some View {
        Button {
            Haptics.tap()
            showPicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(label)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(height: 36)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Showing \(label)")
        .accessibilityHint("Choose whose places appear on the map")
        .sheet(isPresented: $showPicker) {
            MapAudiencePicker()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// The picker sheet. Two fixed modes, then the friend list — searchable, because
/// scrolling for a name stops working somewhere around twenty.
private struct MapAudiencePicker: View {
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
            .searchable(text: $query, prompt: "Search friends")
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
            : pluralized(graph.friends.count, "friend")
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
