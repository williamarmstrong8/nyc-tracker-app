import SwiftUI
import SwiftData
import PhotosUI

/// Edit a Visit that's already been saved to SwiftData.
///
/// Bound directly to the model, so the fields need no staging area — Cancel
/// rolls the context back and Save goes through `VisitRepository` to re-queue the
/// row for upload.
struct EditPersistedVisitView: View {
    @Bindable var visit: Visit
    /// When true, the sheet opened from "Mark as visited" — flip to visited on
    /// appear so the rating field shows, without mutating the model in the
    /// parent (which would flash the Send button under the sheet).
    var promoteToVisited: Bool = false
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss

    @State private var showTagPeople = false

    var body: some View {
        VisitEditForm(
            title: $visit.title,
            note: $visit.note,
            tags: $visit.tags,
            rating: ratingBinding,
            // Bound straight to the model. `saveEdit` on the way out is what
            // re-queues the row, and the feed re-orders on the next pull because
            // `visited_at` is what every surface sorts on.
            visitedOn: $visit.visitedOn,
            address: addressBinding,
            nameOverride: nameOverrideBinding,
            category: visit.place.map(categoryBinding),
            kind: kindBinding,
            photoSources: visit.photosOrdered.map { PhotoView.Source(photo: $0) },
            onDeletePhoto: { index in
                let ordered = visit.photosOrdered
                guard ordered.indices.contains(index) else { return }
                VisitRepository(context: modelContext, userID: visit.ownerUserID)
                    .deletePhoto(ordered[index], from: visit)
                sync.requestSync(reason: .newLocalWrite)
            },
            onMovePhoto: { offsets, target in
                // In-memory only, like every other field here — see
                // `reorderPhotos`. The Save button below is what queues it.
                VisitRepository(context: modelContext, userID: visit.ownerUserID)
                    .reorderPhotos(in: visit, fromOffsets: offsets, toOffset: target)
            },
            onAddPhotos: { items in
                Task {
                    let rows = await PhotoIngest.rows(from: items)
                    VisitRepository(context: modelContext, userID: visit.ownerUserID)
                        .addPhotos(rows, to: visit)
                    sync.requestSync(reason: .newLocalWrite)
                }
            },
            taggedPeople: visit.taggedPeopleOrdered.map(\.person),
            onEditTaggedPeople: { showTagPeople = true }
        )
        .sheet(isPresented: $showTagPeople) {
            TagPeoplePicker(initialSelection: visit.taggedPeopleOrdered.map(\.person)) { picked in
                // Through the repository, not a bare `context.save()`: changing
                // who is tagged is an edit the server has not seen, and an
                // unqueued edit looks right on this device forever while being
                // absent from every other one.
                VisitRepository(context: modelContext, userID: visit.ownerUserID)
                    .setTags(picked, on: visit)
                sync.requestSync(reason: .newLocalWrite)
            }
        }
        .flatModalContentBackground()
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
        .flatModalToolbarBackground()
        .onAppear {
            if promoteToVisited, visit.kind == .wantToTry {
                visit.kind = .visited
                // The want-to-try note is about wanting to go (or a friend's
                // write-up copied by the mirror) — not about this visit. Clear
                // it so the edit sheet starts blank; Cancel rolls it back.
                visit.note = ""
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Haptics.tap()
                    // `saveEdit` rather than `context.save()`: an edit that is
                    // persisted but not re-queued looks correct on this device
                    // forever and simply never reaches any other one.
                    VisitRepository(context: modelContext).saveEdit(to: visit)
                    sync.requestSync(reason: .newLocalWrite)
                    dismiss()
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    modelContext.rollback()
                    dismiss()
                }
            }
        }
    }

    // MARK: - Bindings

    private var ratingBinding: Binding<Rating?> {
        Binding(get: { visit.rating }, set: { visit.rating = $0 })
    }

    private var addressBinding: Binding<String> {
        Binding(get: { visit.address ?? "" }, set: { visit.address = $0.isEmpty ? nil : $0 })
    }

    private var nameOverrideBinding: Binding<String> {
        Binding(get: { visit.nameOverride ?? "" }, set: { visit.nameOverride = $0.isEmpty ? nil : $0 })
    }

    private var kindBinding: Binding<VisitKind> {
        Binding(get: { visit.kind }, set: { visit.kind = $0 })
    }

    /// Goes through `correctCategory` rather than setting `category`, so a fix to
    /// an already-synced place gets queued for its own push.
    private func categoryBinding(_ place: Place) -> Binding<PlaceCategory> {
        Binding(get: { place.category }, set: { place.correctCategory(to: $0) })
    }
}
