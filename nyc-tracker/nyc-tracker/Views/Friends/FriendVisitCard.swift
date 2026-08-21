import SwiftUI

/// One person's visit, rendered in full.
///
/// Shared by the friend profile list and the place detail sheet, because those
/// two surfaces show the same thing from different directions — "everything this
/// person logged" vs "everything logged at this place" — and the card in the
/// middle is identical. Photo and type float on the page; there is no wrapping
/// fill.
///
/// Everything on it is world-readable: note, tags, verdict, photos. There is no
/// redaction path and no permission branch, which is the whole point of the
/// schema's read model. If a private-visit feature ever lands, this is one of the
/// two places that changes (the other is the map query) — not fifteen.
struct FriendVisitCard: View {
    let visit: FriendVisit
    /// Draws the author row. Off on a profile, where every card is the same
    /// person and repeating their name fourteen times is noise.
    var showsAuthor: Bool = true
    /// Marks this as the signed-in user's own entry.
    var isOwnVisit: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsAuthor {
                authorRow
                    .padding(.horizontal, 10)
            }
            if !visit.photos.isEmpty { photoStrip }
            VStack(alignment: .leading, spacing: 12) {
                headlineRow
                metaRow
                if !visit.tags.isEmpty { tagRow }
                if let summary = nonEmpty(visit.summary) {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pieces

    private var authorRow: some View {
        HStack(spacing: 10) {
            PersonAvatar(person: visit.person, size: 32, showsPaletteRing: !isOwnVisit)
            VStack(alignment: .leading, spacing: 1) {
                Text(isOwnVisit ? "You" : visit.person.bestName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let handle = visit.person.handle, !isOwnVisit {
                    Text(handle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isOwnVisit {
                Text("Your visit")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    /// Horizontal strip rather than a paged carousel: these cards stack in a
    /// scroll view under a hero photo, and a nested paging view swallows the
    /// vertical drag. Rounded photos, no wrapping fill.
    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visit.photos) { photo in
                    PhotoView(source: .friendPhoto(path: photo.smallestPath), contentMode: .fill)
                        .frame(width: 168, height: 224)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private var headlineRow: some View {
        HStack(spacing: 6) {
            Text(visit.headline)
                .font(.headline)
                .lineLimit(2)
            if visit.visitKind == .wantToTry {
                Image(systemName: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            Spacer(minLength: 0)
            if let rating = visit.rating {
                Image(systemName: rating.symbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(rating.label)
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            Text(visit.visitedAt.formatted(date: .abbreviated, time: .omitted))
            if let locationText = nonEmpty(visit.neighborhood) ?? nonEmpty(visit.streetAddress) {
                Text("·")
                Text(locationText).lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var tagRow: some View {
        // Wraps rather than clipping: tags are the fastest way to scan a card and
        // a single truncated line hides most of them.
        FlowLayout(spacing: 6) {
            ForEach(VenueTag.sorted(visit.tags), id: \.self) { tag in
                Text(VenueTag.label(forRawValue: tag))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
            }
        }
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }
}
