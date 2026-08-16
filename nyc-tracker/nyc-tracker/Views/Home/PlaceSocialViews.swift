import SwiftUI

// ============================================================================
// The social layer that hangs off a place: who's been, who sent it to you, and
// the two things you can do about it.
// ============================================================================
// Extracted rather than written twice. A place is reachable from a map pin
// (`PlaceDetailSheet`, which also has the user's own visits), from the inbox
// (`RecommendedPlaceSheet`, which has none), and from a feed card. They differ
// in what surrounds them, not in what "3 friends have been here" means.
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
                                Color(uiColor: .secondarySystemGroupedBackground),
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
    }
}

/// Save-to-wishlist and send-to-friend.
///
/// Both act on a place rather than a visit, which is why they live together —
/// they are the two things you can do about somewhere you have not been.
struct PlaceActionsRow: View {
    let place: PlaceSummary

    @Environment(WishlistStore.self) private var wishlist
    @Environment(SocialStatsCache.self) private var stats

    @State private var isSaving = false
    @State private var showSendSheet = false

    private var savedEntry: WishlistEntry? { wishlist.entry(forPlace: place.id) }

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
            SendPlaceSheet(place: place)
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
                isSaved ? "Saved" : "Save",
                systemImage: isSaved ? "bookmark.fill" : "bookmark"
            )
            .font(.subheadline.weight(.semibold))
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
            await wishlist.remove(itemID: savedEntry.id)
        } else {
            await wishlist.add(placeID: place.id)
        }
        // The user's own action — must be reflected immediately rather than
        // waiting out the stats TTL.
        stats.invalidate(placeID: place.id)
    }
}

/// A place opened from somewhere with no local visit behind it — an inbox
/// recommendation, a feed card's venue, a gap-list entry.
///
/// Deliberately thin. It is the place, what the social graph knows about it, and
/// the two actions. Anyone's *visits* to it belong to `PlaceDetailSheet`, which
/// is reached from the map where those visits are actually pinned.
struct RecommendedPlaceSheet: View {
    let place: PlaceSummary

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    PlaceActionsRow(place: place)
                    PlaceSocialSection(placeID: place.id)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(place.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 46, height: 46)
                .background(Circle().fill(tint.opacity(0.15)))

            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if let subtitle = place.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        switch place.category {
        case .restaurant: "fork.knife"
        case .bar:        "wineglass.fill"
        case .cafe:       "cup.and.saucer.fill"
        case .bakery:     "birthday.cake.fill"
        case .other:      "mappin"
        }
    }

    private var tint: Color {
        switch place.category {
        case .restaurant: .orange
        case .bar:        .purple
        case .cafe:       .brown
        case .bakery:     .pink
        case .other:      .gray
        }
    }
}
