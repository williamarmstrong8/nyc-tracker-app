import SwiftUI
import CoreLocation

/// A friend's note on a sent place, shown at the top of the place sheet.
struct PlaceRecommendationNote: Equatable, Hashable, Sendable {
    var senderName: String
    var message: String
}

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
    /// A note a friend attached when they sent this place. Shown up top so it
    /// isn't buried under visit cards.
    var recommendationNote: PlaceRecommendationNote? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    heroPhoto
                    header
                        .padding(.horizontal, 10)

                    if let recommendationNote, !recommendationNote.message.isEmpty {
                        recommendationBanner(recommendationNote)
                            .padding(.horizontal, 10)
                    }

                    // Save / send, then who else knows the place. Both need the
                    // shared `places.id`, so they are only offered once the local
                    // place has been resolved upstream — see `placeSummary`.
                    if let summary = placeSummary {
                        PlaceActionsRow(place: summary, photo: heroPhotoSources.first)
                            .padding(.horizontal, 10)
                        PlaceSocialSection(placeID: summary.id)
                            .padding(.horizontal, 10)
                    }

                    if !group.ownVisits.isEmpty {
                        ownSection
                            .padding(.horizontal, 10)
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
                            .padding(.horizontal, 10)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: - Header

    @ViewBuilder
    private var heroPhoto: some View {
        if !heroPhotoSources.isEmpty {
            Color.clear
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    PhotoCarousel(sources: heroPhotoSources)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var heroPhotoSources: [PhotoView.Source] {
        let own = group.ownVisits.flatMap { visit in
            visit.photos.sorted(by: { $0.order < $1.order }).map { PhotoView.Source(photo: $0) }
        }
        if !own.isEmpty { return own }
        return group.friendVisits.flatMap { visit in
            visit.photos.map { PhotoView.Source.friendPhoto(path: $0.storagePath) }
        }
    }

    private func recommendationBanner(_ note: PlaceRecommendationNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("From \(note.senderName)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 3)
                    .clipShape(Capsule())
                Text("\u{201C}\(note.message)\u{201D}")
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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
                                    Color(uiColor: .systemBackground),
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
    /// is the one you came to find. Floating rows — thumbnail and type, no fill.
    private var ownSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("\(pluralized(group.ownVisits.count, "visit")) by you")
                .padding(.bottom, 4)

            ForEach(Array(group.ownVisits.enumerated()), id: \.element.id) { index, visit in
                Button {
                    Haptics.tap()
                    onOpenOwnVisit(visit)
                } label: {
                    ownVisitRow(visit)
                }
                .buttonStyle(.plain)

                if index < group.ownVisits.count - 1 {
                    Divider().padding(.leading, 78)
                }
            }
        }
    }

    private func ownVisitRow(_ visit: Visit) -> some View {
        HStack(spacing: 14) {
            thumbnail(for: visit)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    if visit.kind == .wantToTry {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.blue, lineWidth: 2.5)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(visit.title.isEmpty ? group.name : visit.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(visit.visitedOn.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !visit.enrichedDescription.isEmpty {
                    Text(visit.enrichedDescription)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
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
        VStack(alignment: .leading, spacing: 28) {
            sectionTitle(friendsSectionTitle)
                .padding(.horizontal, 10)

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
