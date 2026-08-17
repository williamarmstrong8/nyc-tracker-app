import SwiftUI
import SwiftData
import PhotosUI
import MapKit
import CoreLocation

/// Preview write-up shown after processing, before the user confirms.
struct WriteUpView: View {
    @Bindable var coordinator: CaptureCoordinator
    var onConfirm: () -> Void

    @State private var showEdit = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PhotoCarousel(sources: coordinator.selectedItems.map { .pickerItem($0) })
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 14) {
                    Text(coordinator.draftTitle)
                        .font(.largeTitle.weight(.bold))

                    if let neighborhood = coordinator.resolvedNeighborhood, !neighborhood.isEmpty {
                        Text(neighborhood)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if !coordinator.draftTags.isEmpty {
                        TagChipRow(tags: coordinator.draftTags)
                    }

                    Text(coordinator.draftDescription)
                        .font(.body)
                        .foregroundStyle(.primary)

                    if !coordinator.draftTopQuote.isEmpty {
                        PullQuote(text: coordinator.draftTopQuote)
                    }

                    DisclosureGroup {
                        Text(coordinator.transcript.isEmpty ? "No transcript yet." : coordinator.transcript)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    } label: {
                        Label("Transcript", systemImage: "waveform")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)

                actionButtons
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
            }
        }
        .navigationTitle("Write-up")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEdit) {
            NavigationStack {
                EditWriteUpView(coordinator: coordinator)
            }
            .preferredColorScheme(.dark)
            .presentationBackground(.black)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.tap()
                showEdit = true
            } label: {
                Label("Edit", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.glass)

            Button {
                onConfirm()
            } label: {
                Label("Confirm", systemImage: "checkmark")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.glassProminent)
        }
    }
}

// MARK: - Pull quote

struct PullQuote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 3)
                .cornerRadius(1.5)
            Text("\u{201C}\(text)\u{201D}")
                .font(.title3.italic())
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Read-only variant

struct ReadOnlyWriteUpView: View {
    @Bindable var visit: Visit
    var onDismiss: () -> Void
    /// Dismisses this write-up and centers the Home map on `visit`, opening its callout.
    var onShowOnMap: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(SyncEngine.self) private var sync
    @State private var showEdit = false
    @State private var showDeleteConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !visit.photos.isEmpty || visit.kind == .visited {
                    Color.clear
                        .aspectRatio(3 / 4, contentMode: .fit)
                        .overlay {
                            PhotoCarousel(
                                sources: visit.photos
                                    .sorted(by: { $0.order < $1.order })
                                    .map { PhotoView.Source(photo: $0) }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(.horizontal, 16)
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Text(visit.title.isEmpty ? (visit.place?.name ?? "Untitled") : visit.title)
                            .font(.largeTitle.weight(.bold))
                        if visit.kind == .wantToTry {
                            Label("Want to try", systemImage: "bookmark.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.blue)
                        }
                    }

                    HStack(spacing: 6) {
                        if let neighborhood = visit.place?.neighborhood {
                            Text(neighborhood).foregroundStyle(.secondary)
                        }
                        if let address = visit.address {
                            Text("•").foregroundStyle(.tertiary)
                            Text(address).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .font(.subheadline)

                    if visit.place != nil {
                        HStack(spacing: 10) {
                            Button {
                                Haptics.tap()
                                openDirections()
                            } label: {
                                Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.glass)

                            Button {
                                Haptics.tap()
                                onShowOnMap()
                            } label: {
                                Label("View on Map", systemImage: "map.fill")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.glass)
                        }
                        .padding(.top, 2)
                    }

                    if !visit.tags.isEmpty {
                        TagChipRow(tags: visit.tags)
                    }

                    if !visit.enrichedDescription.isEmpty {
                        Text(visit.enrichedDescription)
                            .font(.body)
                    }

                    if !visit.topQuote.isEmpty {
                        PullQuote(text: visit.topQuote)
                    }

                    if let rating = visit.rating {
                        HStack(spacing: 8) {
                            Image(systemName: rating.symbol)
                            Text(rating.label)
                            if let intent = visit.returnIntent {
                                Text("•").foregroundStyle(.tertiary)
                                Text("Return: \(intent.label)")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }

                    if !visit.transcript.isEmpty {
                        DisclosureGroup {
                            Text(visit.transcript)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        } label: {
                            Label("Transcript", systemImage: "waveform")
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 20)

                if let placeID = visit.place?.remotePlaceID {
                    VisitFriendsSection(
                        placeID: placeID,
                        latitude: visit.place?.lat,
                        longitude: visit.place?.lng
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                }

                Spacer(minLength: 60)
            }
        }
        .navigationTitle(visit.title.isEmpty ? (visit.place?.name ?? "") : visit.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { onDismiss() }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        Haptics.tap()
                        showEdit = true
                    } label: {
                        Label("Edit", systemImage: "square.and.pencil")
                    }
                    if visit.kind == .wantToTry {
                        Button {
                            Haptics.tap()
                            visit.kind = .visited
                            VisitRepository(context: modelContext).saveEdit(to: visit)
                            sync.requestSync(reason: .newLocalWrite)
                        } label: {
                            Label("Mark as visited", systemImage: "checkmark.circle")
                        }
                    } else {
                        Button {
                            Haptics.tap()
                            visit.kind = .wantToTry
                            VisitRepository(context: modelContext).saveEdit(to: visit)
                            sync.requestSync(reason: .newLocalWrite)
                        } label: {
                            Label("Move to want to try", systemImage: "bookmark")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        Haptics.tap()
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            NavigationStack {
                EditPersistedVisitView(visit: visit)
            }
            .preferredColorScheme(.dark)
            .presentationBackground(.black)
        }
        .confirmationDialog("Delete this entry?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                VisitRepository(context: modelContext, userID: visit.ownerUserID)
                    .delete(visit)
                sync.requestSync(reason: .newLocalWrite)
                onDismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func openDirections() {
        guard let place = visit.place else { return }
        // `MKMapItem(location:address:)` replaces the placemark initialiser
        // deprecated in iOS 26. Address is nil on purpose: Maps only needs a
        // coordinate to route to, and the name below is what it labels the pin
        // with — a formatted address we made up here would compete with it.
        let mapItem = MKMapItem(
            location: CLLocation(
                latitude: place.coordinate.latitude,
                longitude: place.coordinate.longitude
            ),
            address: nil
        )
        mapItem.name = visit.title.isEmpty ? place.name : visit.title
        mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }
}

// MARK: - Read-only variant, for a friend's entry

/// The same immersive write-up as `ReadOnlyWriteUpView` — full-width photo
/// carousel, title, tags, description, quote, transcript — but sourced from a
/// friend's `FriendVisit` instead of a local `Visit`, and with no edit/delete/
/// move menu, since none of that is the viewer's to change.
///
/// Used wherever a specific friend visit needs the same full-screen treatment
/// as your own (explore posts, opening a place card from a chat message), rather
/// than the lighter `FriendVisitDetailSheet` card used from the map.
struct FriendVisitWriteUpView: View {
    let visit: FriendVisit
    var onDismiss: () -> Void
    /// Present only where jumping back to the map makes sense (e.g. from a
    /// chat). Omitted on surfaces that have nowhere sensible to send it.
    var onShowOnMap: (() -> Void)? = nil

    private var heroPhotoSource: PhotoView.Source? {
        visit.photos
            .sorted { $0.sortOrder < $1.sortOrder }
            .first
            .map { PhotoView.Source.friendPhoto(path: $0.storagePath) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !visit.photos.isEmpty {
                    Color.clear
                        .aspectRatio(3 / 4, contentMode: .fit)
                        .overlay {
                            PhotoCarousel(
                                sources: visit.photos.map { .friendPhoto(path: $0.storagePath) }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(.horizontal, 16)
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Text(visit.headline)
                            .font(.largeTitle.weight(.bold))
                        if visit.visitKind == .wantToTry {
                            Label("Want to try", systemImage: "bookmark.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.blue)
                        }
                    }

                    HStack(spacing: 8) {
                        PersonAvatar(person: visit.person, size: 22)
                        Text(visit.person.bestName)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)

                    HStack(spacing: 6) {
                        if let neighborhood = nonEmpty(visit.neighborhood) {
                            Text(neighborhood).foregroundStyle(.secondary)
                        }
                        if let address = nonEmpty(visit.streetAddress) {
                            Text("•").foregroundStyle(.tertiary)
                            Text(address).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .font(.subheadline)

                    HStack(spacing: 10) {
                        Button {
                            Haptics.tap()
                            openDirections()
                        } label: {
                            Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.glass)

                        if let onShowOnMap {
                            Button {
                                Haptics.tap()
                                onShowOnMap()
                            } label: {
                                Label("View on Map", systemImage: "map.fill")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    .padding(.top, 2)

                    if !visit.tags.isEmpty {
                        TagChipRow(tags: visit.tags)
                    }

                    if let summary = nonEmpty(visit.summary) {
                        Text(summary)
                            .font(.body)
                    }

                    if let quote = nonEmpty(visit.topQuote) {
                        PullQuote(text: quote)
                    }

                    if let rating = visit.rating {
                        HStack(spacing: 8) {
                            Image(systemName: rating.symbol)
                            Text(rating.label)
                            if let intent = visit.returnIntent.flatMap(ReturnIntent.init(rawValue:)) {
                                Text("•").foregroundStyle(.tertiary)
                                Text("Return: \(intent.label)")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }

                    if let transcript = nonEmpty(visit.transcript) {
                        DisclosureGroup {
                            Text(transcript)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                        } label: {
                            Label("Transcript", systemImage: "waveform")
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 24)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlaceActionsRow(
                place: visit.placeSummary,
                photo: heroPhotoSource,
                unsavedSaveLabel: "Save to Want to Try",
                savedSaveLabel: "Saved"
            )
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background {
                Rectangle()
                    .fill(.background)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .navigationTitle(visit.headline)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { onDismiss() }
            }
        }
    }

    private func openDirections() {
        let mapItem = MKMapItem(
            location: CLLocation(latitude: visit.latitude, longitude: visit.longitude),
            address: nil
        )
        mapItem.name = visit.headline
        mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
