import SwiftUI
import SwiftData

/// A venue picked from the picker, optionally with the visit it came from.
///
/// Carries no note — the composer's text field is where that gets written,
/// with this attached alongside it. That is the whole reason the picker no
/// longer pushes a second "write something" screen: there is already
/// somewhere to write, sitting at the bottom of the chat the picker was
/// opened from.
struct PickedChatPlace: Equatable, Sendable {
    var placeID: UUID
    var visitID: UUID?
    /// A local snapshot of what was picked.
    ///
    /// The server composes the real message row — venue, photos and all — from
    /// `place_id`, so on the normal path this is unused. It exists for sample
    /// mode, which has no server to ask and no knowledge of the user's own
    /// places: without it a place you send in demo mode arrives as a bare note.
    var preview: SharedPlacePreview
}

/// Enough of a picked visit to draw its card without the server.
struct SharedPlacePreview: Equatable, Sendable {
    var place: PlaceSummary
    var title: String?
    var tags: [String]
    /// A `local:`-prefixed path into the app's own photo storage, which
    /// `PhotoView.Source.friendPhoto` resolves to an on-disk file.
    var photoPath: String?
}

/// Pick somewhere you've been.
///
/// One screen, not two: tapping a row picks it and hands it back to the chat's
/// own text field, which is where the note about it gets written. This list is
/// deliberately the Map page's list view, row for row — same thumbnail, same
/// title/neighbourhood/tags stack — so there is nothing new to learn here.
struct SharePlacePicker: View {
    let userID: UUID
    let recipient: PersonSummary
    var onPick: (PickedChatPlace) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query private var visits: [Visit]

    @State private var query = ""

    init(
        userID: UUID,
        recipient: PersonSummary,
        onPick: @escaping (PickedChatPlace) -> Void
    ) {
        self.userID = userID
        self.recipient = recipient
        self.onPick = onPick
        _visits = Query(
            filter: LocalStore.visitsPredicate(for: userID),
            sort: [SortDescriptor(\Visit.visitedOn, order: .reverse)]
        )
    }

    /// Only entries with a venue, newest first. An entry whose place never
    /// resolved has nothing to send — the recipient would get a note attached to
    /// nowhere.
    private var sendableVisits: [Visit] {
        let withPlaces = visits.filter { $0.place != nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return withPlaces }
        return withPlaces.filter { visit in
            let place = visit.place
            return visit.title.lowercased().contains(trimmed)
                || (place?.name.lowercased().contains(trimmed) ?? false)
                || (place?.neighborhood.lowercased().contains(trimmed) ?? false)
                || visit.tags.contains { $0.lowercased().contains(trimmed) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sendableVisits.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Attach a place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(sendableVisits.enumerated()), id: \.element.id) { index, visit in
                    row(for: visit)

                    if index < sendableVisits.count - 1 {
                        Divider().padding(.leading, 86)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            searchField
        }
    }

    @ViewBuilder
    private func row(for visit: Visit) -> some View {
        // A place that hasn't reached the server yet has no id the recipient's
        // app could resolve. Shown rather than hidden, because "where's the
        // place I logged an hour ago" is a worse question than a greyed row that
        // says why.
        if visit.place?.remotePlaceID == nil {
            SharePlaceRow(visit: visit, isPending: true)
                .opacity(0.5)
                .accessibilityHint("Still uploading. Available once it syncs.")
        } else {
            Button {
                pick(visit)
            } label: {
                SharePlaceRow(visit: visit, isPending: false)
            }
            .buttonStyle(.plain)
        }
    }

    private func pick(_ visit: Visit) {
        guard let place = visit.place, let placeID = place.remotePlaceID else { return }
        Haptics.tap()
        onPick(
            PickedChatPlace(
                placeID: placeID,
                // Only a synced visit can be referenced; an unsynced one would
                // point at a row the server has never seen and `send_message`
                // would reject the whole message rather than just the link.
                visitID: visit.remoteID,
                preview: SharedPlacePreview(
                    place: PlaceSummary(
                        id: placeID,
                        name: place.name,
                        categoryRaw: place.categoryRaw,
                        neighborhood: place.neighborhood,
                        streetAddress: visit.address,
                        latitude: place.lat,
                        longitude: place.lng
                    ),
                    title: visit.title.isEmpty ? nil : visit.title,
                    tags: visit.tags,
                    photoPath: localPhotoPath(for: visit)
                )
            )
        )
        dismiss()
    }

    /// The picked visit's own photo, on disk. Prefers the thumbnail — the
    /// attachment chip and the sent card both draw it small.
    private func localPhotoPath(for visit: Visit) -> String? {
        guard let photo = visit.photos.sorted(by: { $0.order < $1.order }).first else {
            return nil
        }
        guard let path = photo.thumbRelativePath ?? photo.relativePath else { return nil }
        return "local:" + path
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search your places", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Color(uiColor: .secondarySystemFill))
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(uiColor: .systemBackground))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: query.isEmpty ? "map" : "magnifyingglass")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text(query.isEmpty ? "Nothing to send yet" : "No places match")
                .font(.headline)
            Text(query.isEmpty
                 ? "Log a place and it shows up here."
                 : "Try a different name or neighbourhood.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

/// The Map page's list row, reproduced here so the two lists stay identical.
private struct SharePlaceRow: View {
    let visit: Visit
    let isPending: Bool

    private var thumbnail: Photo? {
        visit.photos.sorted { $0.order < $1.order }.first
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            thumbnailView
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    if visit.kind == .wantToTry {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.blue, lineWidth: 2.5)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(visit.title.isEmpty ? (visit.place?.name ?? "Untitled") : visit.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let neighborhood = visit.place?.neighborhood, !neighborhood.isEmpty {
                    Text(neighborhood)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if isPending {
                    Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if !visit.tags.isEmpty {
                    Text(visit.tags.prefix(3).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if !isPending {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityValue(visit.kind == .wantToTry ? "Want to try" : "")
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            PhotoView(source: PhotoView.Source(photo: thumbnail, wantsThumbnail: true), contentMode: .fill)
        } else {
            ZStack {
                Color(uiColor: .secondarySystemFill)
                Image(systemName: visit.kind == .wantToTry ? "bookmark" : "photo")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

