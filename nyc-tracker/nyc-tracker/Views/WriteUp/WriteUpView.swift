import SwiftUI
import SwiftData
import PhotosUI
import MapKit
import CoreLocation

// MARK: - Verdict

/// The one-line "liked it / didn't" readout under a write-up's body.
struct RatingLine: View {
    let rating: Rating

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: rating.symbol)
            Text(rating.label)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
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
    // Optional: this view is presented from several sheets, and a sheet doesn't
    // reliably inherit an `@State` Observable from its presenter. Where the
    // store is missing the saved-place affordances simply don't draw, rather
    // than trapping on a missing environment value.
    @Environment(WishlistStore.self) private var wishlist: WishlistStore?
    @Environment(SocialStatsCache.self) private var socialStats: SocialStatsCache?
    @State private var showEdit = false
    @State private var promoteToVisited = false
    @State private var showDeleteConfirm = false
    @State private var showSendSheet = false
    @State private var isUnsaving = false

    /// The upstream place id, when this entry points at one — the handle both
    /// the wishlist row and the local mirror are keyed by.
    private var remotePlaceID: UUID? { visit.place?.remotePlaceID }

    /// True when this want-to-try is the local face of a saved wishlist place,
    /// which is the only case where "unsave" means anything.
    private var isSavedPlace: Bool {
        guard visit.kind == .wantToTry, let remotePlaceID, let wishlist else { return false }
        return wishlist.contains(placeID: remotePlaceID)
    }

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

                    TaggedPeopleRow(people: visit.taggedPeopleOrdered.map(\.person))

                    // Shown because it is now something the user chose rather
                    // than a timestamp the app happened to record.
                    Label(
                        visit.visitedOn.formatted(date: .abbreviated, time: .omitted),
                        systemImage: "calendar"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

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

                    // Wishlist mirrors copy a friend's note so the map pin has
                    // content; that note is shown under their avatar in
                    // `VisitFriendsSection`, so don't also print it here.
                    if !visit.note.isEmpty, !visit.wishlistMirror {
                        Text(visit.note)
                            .font(.body)
                    }

                    if let rating = visit.rating {
                        RatingLine(rating: rating)
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

                if visit.kind == .wantToTry {
                    VStack(spacing: 10) {
                        // Above Mark as visited, and only for a place that is
                        // actually on the wishlist: unsaving drops the upstream
                        // row and this entry together, so the save can't survive
                        // as a pin the user has no way to reach from here.
                        if isSavedPlace {
                            Button {
                                Haptics.tap()
                                Task { await unsave() }
                            } label: {
                                Label("Unsave", systemImage: "bookmark.slash")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .opacity(isUnsaving ? 0 : 1)
                                    .overlay { if isUnsaving { ProgressView().controlSize(.small) } }
                            }
                            .buttonStyle(.glass)
                            .disabled(isUnsaving)
                        }

                        Button {
                            Haptics.tap()
                            beginMarkAsVisited()
                        } label: {
                            Label("Mark as visited", systemImage: "checkmark.circle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                } else {
                    Button {
                        Haptics.tap()
                        showSendSheet = true
                    } label: {
                        Label("Send", systemImage: "paperplane")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.glass)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                }

                Spacer(minLength: 24)
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
                            beginMarkAsVisited()
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
        .sheet(isPresented: $showEdit, onDismiss: { promoteToVisited = false }) {
            NavigationStack {
                EditPersistedVisitView(visit: visit, promoteToVisited: promoteToVisited)
            }
            .flatModalBackground()
        }
        .confirmationDialog("Delete this entry?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                // Read the handle before the row goes: deleting the only visit
                // at a place cascades the `Place` too, and `visit.place` is nil
                // by the time the tombstone is queued.
                let savedPlaceID = visit.kind == .wantToTry ? remotePlaceID : nil
                VisitRepository(context: modelContext, userID: visit.ownerUserID)
                    .delete(visit)
                sync.requestSync(reason: .newLocalWrite)
                // Deleting a saved want-to-try unsaves it. Without this the
                // wishlist row outlives the entry the user just deleted and
                // comes back as a pin with its own sheet — and, worse, gets
                // re-mirrored into a fresh want-to-try on the next refresh.
                if let savedPlaceID, let wishlist {
                    Task {
                        await wishlist.remove(placeID: savedPlaceID)
                        socialStats?.invalidate(placeID: savedPlaceID)
                    }
                }
                onDismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This can't be undone.")
        }
        .sheet(isPresented: $showSendSheet) {
            SendVisitSheet(visit: visit)
        }
    }

    /// Drop the wishlist row and the local mirror together.
    ///
    /// Upstream first: if the network call fails the local entry stays put and
    /// `WishlistStore.lastError` carries the reason, which is better than a row
    /// that vanishes here and reappears at the next refresh. Removal of the
    /// local half goes through `WantToTryMirror`, so a want-to-try the user
    /// wrote themselves — photos, a note — is unsaved without being deleted;
    /// only in the case where the entry really was a mirror does the sheet
    /// close, because only then is there nothing left behind it.
    private func unsave() async {
        guard let wishlist, let remotePlaceID else { return }

        isUnsaving = true
        defer { isUnsaving = false }

        guard await wishlist.remove(placeID: remotePlaceID) else { return }
        socialStats?.invalidate(placeID: remotePlaceID)

        var removedLocally = false
        if let ownerID = visit.ownerUserID {
            removedLocally = WantToTryMirror(context: modelContext, userID: ownerID)
                .removeMirror(placeID: remotePlaceID)
        }
        sync.requestSync(reason: .newLocalWrite)

        if removedLocally { onDismiss() }
    }

    /// Opens the edit sheet in "mark as visited" mode. The kind flip happens
    /// inside `EditPersistedVisitView.onAppear` so the read-only sheet behind
    /// it never briefly swaps Send in for Mark as visited.
    private func beginMarkAsVisited() {
        promoteToVisited = true
        showEdit = true
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
/// carousel, title, tags, description, verdict — but sourced from a friend's
/// `FriendVisit` instead of a local `Visit`, and with no edit/delete/move menu,
/// since none of that is the viewer's to change.
///
/// Used wherever a specific friend visit is opened — map pins, explore posts,
/// chat place cards, and profile activity/tagged grids — so a friend's entry
/// always gets the same full-screen treatment as your own.
struct FriendVisitWriteUpView: View {
    let visit: FriendVisit
    var onDismiss: () -> Void
    /// Present only where jumping back to the map makes sense (e.g. from a
    /// chat). Omitted on surfaces that have nowhere sensible to send it.
    var onShowOnMap: (() -> Void)? = nil
    /// Draws the author line. Off on the reader's own Tagged tab, where the
    /// entry is already framed as something someone else wrote about them and
    /// the tagged-people row directly under it carries the faces.
    var showsAuthor: Bool = true

    @Environment(AuthManager.self) private var auth
    @Environment(\.modelContext) private var modelContext

    /// So a tag naming the reader reads "with you and Dev" rather than the
    /// reader's own display name, which is how nobody refers to themselves.
    private var viewerID: UUID? { auth.state.profile?.id }

    /// Hides "Want to try" wherever the reader was already there — tagged in
    /// this very visit, or the owner of a `visited` entry of their own at the
    /// same place. Either way the bookmark is offering to plan a trip that
    /// already happened.
    private var hasBeenHereAlready: Bool {
        if let viewerID, visit.tagged.contains(where: { $0.id == viewerID }) {
            return true
        }
        guard let viewerID else { return false }
        let predicate = LocalStore.visitsPredicate(for: viewerID)
        let descriptor = FetchDescriptor<Visit>(predicate: predicate)
        let ownVisits = (try? modelContext.fetch(descriptor)) ?? []
        return ownVisits.contains {
            $0.kind == .visited && $0.place?.remotePlaceID == visit.placeID
        }
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

                    if showsAuthor {
                        HStack(spacing: 8) {
                            PersonAvatar(person: visit.person, size: 22)
                            Text(visit.person.bestName)
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }

                    TaggedPeopleRow(
                        people: visit.tagged.map(\.person),
                        viewerID: viewerID
                    )

                    Label(
                        visit.visitedAt.formatted(date: .abbreviated, time: .omitted),
                        systemImage: "calendar"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

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

                    if let rating = visit.rating {
                        RatingLine(rating: rating)
                    }
                }
                .padding(.horizontal, 20)

                // Scrolls with the content instead of floating, so a friend's
                // write-up ends the same way your own does (a single inline
                // button) rather than a sticky save/send bar. Omitted entirely
                // once the reader has already been here — see `hasBeenHereAlready`.
                if !hasBeenHereAlready {
                    WantToTryButton(place: visit.placeSummary, sourceVisit: visit)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                }

                Spacer(minLength: 24)
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
