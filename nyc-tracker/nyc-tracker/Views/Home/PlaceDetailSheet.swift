import SwiftUI

/// Everything logged at one place, by everyone in the current filter set.
///
/// This is where "everything is public" earns its keep: no permission checks, no
/// redaction, no "you must be friends to read this". Just the place, then a list
/// of visits — the caller's own first, then friends' newest-first.
///
/// Own visits are rendered as compact rows that open the existing read-only
/// write-up rather than as `FriendVisitCard`s. They are not the same thing: the
/// user's own entry has local photo files, an edit path, and a delete path, all
/// of which already live in `ReadOnlyWriteUpView`. Reshaping a `Visit` into a
/// `FriendVisit` to reuse one card would break photo rendering (local relative
/// paths are not storage paths) and throw away the actions.
struct PlaceDetailSheet: View {
    let group: MapPlaceGroup
    /// Opens the full write-up for one of the user's own visits.
    var onOpenOwnVisit: (Visit) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    // Save / send, then who else knows the place. Both need the
                    // shared `places.id`, so they are only offered once the local
                    // place has been resolved upstream — see `placeSummary`.
                    if let summary = placeSummary {
                        PlaceActionsRow(place: summary)
                        PlaceSocialSection(placeID: summary.id)
                    }

                    if !group.ownVisits.isEmpty {
                        ownSection
                    }

                    if !group.friendVisits.isEmpty {
                        friendsSection
                    }

                    if group.visitCount == 0 {
                        Text("Nothing logged here yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: categorySymbol)
                .font(.title3)
                .foregroundStyle(categoryTint)
                .frame(width: 46, height: 46)
                .background(Circle().fill(categoryTint.opacity(0.15)))

            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            if !group.friendPeople.isEmpty {
                HStack(spacing: -8) {
                    ForEach(group.friendPeople.prefix(3)) { person in
                        PersonAvatar(person: person, size: 28)
                            .overlay(
                                Circle().stroke(
                                    Color(uiColor: .systemGroupedBackground),
                                    lineWidth: 2
                                )
                            )
                    }
                }
            }
        }
    }

    /// The shared `places` row behind this pin, if there is one.
    ///
    /// `nil` for a place that hasn't synced yet: recommending or saving needs the
    /// server-side place id, and a locally-created `Place` has none until
    /// `find_or_create_place()` has resolved it. Hiding the actions for those few
    /// seconds is better than offering a button that can only fail — and better
    /// than inventing a place row from the client, which would bypass the dedupe
    /// that keeps one venue from becoming five.
    private var placeSummary: PlaceSummary? {
        guard case .remote(let placeID) = group.key else { return nil }
        let friendVisit = group.friendVisits.first
        return PlaceSummary(
            id: placeID,
            name: group.name,
            categoryRaw: friendVisit?.placeCategory ?? group.category.rawValue,
            neighborhood: friendVisit?.neighborhood ?? group.ownVisits.first?.place?.neighborhood,
            streetAddress: friendVisit?.streetAddress ?? group.ownVisits.first?.address,
            latitude: group.coordinate.latitude,
            longitude: group.coordinate.longitude
        )
    }

    private var subtitle: String? {
        let neighborhood = group.friendVisits.compactMap(\.neighborhood).first
        let address = group.friendVisits.compactMap(\.streetAddress).first
        let ownNeighborhood = group.ownVisits.first?.place?.neighborhood
        let parts = [address, neighborhood ?? ownNeighborhood]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: - Sections

    /// Pinned to the top, per the brief: on a place you've been, your own entry
    /// is the one you came to find.
    private var ownSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("\(pluralized(group.ownVisits.count, "visit")) by you")

            ForEach(group.ownVisits) { visit in
                Button {
                    Haptics.tap()
                    onOpenOwnVisit(visit)
                } label: {
                    ownVisitRow(visit)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func ownVisitRow(_ visit: Visit) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: visit)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(visit.title.isEmpty ? group.name : visit.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(visit.visitedOn.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !visit.enrichedDescription.isEmpty {
                    Text(visit.enrichedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5)
        }
    }

    @ViewBuilder
    private func thumbnail(for visit: Visit) -> some View {
        if let photo = visit.photos.sorted(by: { $0.order < $1.order }).first {
            PhotoView(
                source: PhotoView.Source(photo: photo, wantsThumbnail: true),
                contentMode: .fill
            )
        } else {
            ZStack {
                Color(uiColor: .tertiarySystemFill)
                Image(systemName: visit.kind == .wantToTry ? "bookmark.fill" : categorySymbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(friendsSectionTitle)

            ForEach(group.friendVisits) { visit in
                FriendVisitCard(visit: visit, showsAuthor: true)
            }
        }
    }

    private var friendsSectionTitle: String {
        let people = group.friendPeople.count
        let visits = pluralized(group.friendVisits.count, "visit")
        if people == 1, let only = group.friendPeople.first {
            return "\(visits) by \(only.shortName)"
        }
        return "\(visits) by \(pluralized(people, "friend"))"
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: - Category styling

    private var categorySymbol: String {
        switch group.category {
        case .restaurant: "fork.knife"
        case .bar:        "wineglass.fill"
        case .cafe:       "cup.and.saucer.fill"
        case .bakery:     "birthday.cake.fill"
        case .other:      "mappin"
        }
    }

    private var categoryTint: Color {
        switch group.category {
        case .restaurant: .orange
        case .bar:        .purple
        case .cafe:       .brown
        case .bakery:     .pink
        case .other:      .gray
        }
    }
}
