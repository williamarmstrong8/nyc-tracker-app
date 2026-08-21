import SwiftUI
import SwiftData
import PhotosUI
import CoreLocation
import UIKit

/// "Add a place to try" sheet — the same shape as the capture flow's `DetailsView`
/// (photos, location search, description, tags), minus what doesn't make sense
/// for a place nobody has been to yet: a verdict (`RatingField`), a visited
/// date (`VisitDateField`), and who was there (`TagPeopleField`) — nobody's
/// been, so there's no one to tag. Uses a scrolling VStack (not a Form) so
/// tapping into a field doesn't shuffle the layout.
///
/// Unlike the real capture flow — where photos are picked before this screen is
/// ever reached — photos here are entirely optional: `LocationSearchField`
/// lets the user name the place directly, and Vision-based OCR silently reads
/// a likely venue name off any added photo (the biggest, most confident piece
/// of text in the frame, typically storefront signage) as a fallback so
/// `LocationResolver` still has something to search by if the user adds a
/// photo without searching. If both come up empty the place is saved as
/// "New Spot" and can be renamed later.
///
/// No verdict here. A want-to-try is a place nobody has been to yet, so "liked
/// it" has nothing to describe; it appears the moment the entry is marked as
/// visited. No date either — a want-to-try has no "when".
struct WantToTryView: View {
    let userID: UUID
    /// Set when the entry started from a place already tapped on the map (or
    /// found via search) — seeds the name/address fields and `selectedVenue`
    /// with an already-confirmed venue instead of starting empty.
    let preselectedVenue: VenueCandidate?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncEngine.self) private var sync

    @State private var name: String
    @State private var address: String
    /// The confirmed venue behind `name`/`address`, whether it arrived as
    /// `preselectedVenue` or was picked from `LocationSearchField` below.
    /// Non-nil skips `LocationResolver` entirely at save time — same shortcut
    /// the capture flow's Details screen uses.
    @State private var selectedVenue: VenueCandidate?

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotosPicker: Bool = false
    @State private var note: String = ""
    @State private var hadVoiceNote: Bool = false
    /// Raw `VenueTag` values. Worth asking for even on a place nobody has been
    /// to — "date night" and "great coffee" are exactly why it's on the list.
    @State private var tags: [String] = []

    @State private var recorder: any RecorderProtocol = SpeechRecorder()

    @State private var candidates: [VenueCandidate] = []
    @State private var isResolving: Bool = false
    @State private var showPicker: Bool = false
    @State private var pendingResolution: LocationResolution?

    @FocusState private var focused: Field?
    enum Field { case description }

    init(userID: UUID, preselectedVenue: VenueCandidate? = nil) {
        self.userID = userID
        self.preselectedVenue = preselectedVenue
        _name = State(initialValue: preselectedVenue?.name ?? "")
        _address = State(initialValue: preselectedVenue?.address ?? "")
        _selectedVenue = State(initialValue: preselectedVenue)
    }

    private var canSave: Bool {
        !isResolving && (!name.trimmingCharacters(in: .whitespaces).isEmpty || !photoItems.isEmpty)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if !photoItems.isEmpty {
                        photoStrip
                    }

                    photoRow

                    descriptionSection

                    LocationSearchField(
                        nameInput: $name,
                        addressInput: $address,
                        selectedVenue: $selectedVenue
                    )
                    .zIndex(10)

                    VenueTagField(selection: $tags)

                    saveButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            .navigationTitle("Want to try")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .keyboard) {
                    Button("Done") {
                        focused = nil
                        // LocationSearchField owns its own FocusState, so this
                        // is the only way "Done" can also dismiss its keyboard.
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
            .photosPicker(
                isPresented: $showPhotosPicker,
                selection: $photoItems,
                maxSelectionCount: 4,
                matching: .images,
                photoLibrary: .shared()
            )
            .onChange(of: photoItems) { _, newItems in
                // No name yet (no preselected/searched venue) — try to read one off the photo(s), silently.
                if name.trimmingCharacters(in: .whitespaces).isEmpty, !newItems.isEmpty {
                    Task { await detectNameFromPhotos(newItems) }
                }
            }
            .sheet(isPresented: $showPicker) {
                NavigationStack {
                    VenuePickerView(
                        candidates: candidates,
                        biasCoordinate: pendingResolution?.coordinate,
                        typedName: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
                    ) { picked in
                        showPicker = false
                        persist(candidate: picked)
                        Haptics.success()
                        dismiss()
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showPicker = false }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Save a place you want to try")
                .font(.title3.weight(.semibold))
            Text("Search for it, or just add a photo — we'll read the name off the sign and pin it on the map.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var photoStrip: some View {
        ReorderablePhotoStrip(
            items: $photoItems,
            thumbnailWidth: 120,
            thumbnailHeight: 160,
            cornerRadius: 14
        )
    }

    private var photoRow: some View {
        Button {
            Haptics.tap()
            showPhotosPicker = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                Text(photoItems.isEmpty ? "Add photos (optional)" : "Change photos (\(photoItems.count))")
                Spacer()
                if !photoItems.isEmpty {
                    Text("Tap to change").font(.footnote).foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glass)
    }

    /// Type it, dictate it, or both — recording fills the same box a typed note would, and either
    /// one is free to edit afterward. The record button sits centered underneath, its own control
    /// rather than something the text field expects to share space with.
    private var descriptionSection: some View {
        VStack(spacing: 12) {
            LabeledField(
                title: "Description (optional)",
                text: $note,
                placeholder: "What do you want to remember about this place?",
                axis: .vertical,
                lineLimit: 3...8
            )
            .focused($focused, equals: .description)

            HoldToRecordButton(recorder: recorder, hasRecording: hadVoiceNote) { result in
                note = result.transcript
                hadVoiceNote = result.hadRecording
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            HStack(spacing: 8) {
                if isResolving {
                    ProgressView().tint(.white)
                }
                Text(isResolving ? "Finding place…" : "Save")
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.glassProminent)
        .disabled(!canSave)
    }

    // MARK: - OCR

    /// Load photo data and ask Vision for the most sign-like text across the batch. Only runs when
    /// `name` is still empty at completion time, and there's no UI feedback for it — it's a
    /// silent assist for `LocationResolver`, not something the user is asked to confirm here.
    private func detectNameFromPhotos(_ items: [PhotosPickerItem]) async {
        var datas: [Data] = []
        for item in items.prefix(3) {  // OCR up to first 3 photos to keep it snappy
            if let data = try? await item.loadTransferable(type: Data.self) {
                datas.append(data)
            }
        }
        guard !datas.isEmpty else { return }
        guard let detected = await TextRecognizer.recognizePlaceName(fromBatch: datas) else { return }

        // Only apply if nothing else has filled it in since we began.
        guard name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        name = detected.titleCasedForVenue
    }

    // MARK: - Save

    private func save() async {
        focused = nil
        isResolving = true
        defer { isResolving = false }

        if let selectedVenue {
            await save(confirmedVenue: selectedVenue)
            return
        }

        // If we still don't have a name and we do have photos, run OCR one more time synchronously.
        if name.trimmingCharacters(in: .whitespaces).isEmpty, !photoItems.isEmpty {
            await detectNameFromPhotos(photoItems)
        }

        let assetIdentifiers = photoItems.compactMap { $0.itemIdentifier }
        let deviceLocation = await LocationProvider.shared.currentLocation()
        let nameHint = name.trimmingCharacters(in: .whitespaces)

        let resolution = await LocationResolver.resolve(
            assetIdentifiers: assetIdentifiers,
            nameHint: nameHint.isEmpty ? nil : nameHint,
            addressHint: address.isEmpty ? nil : address,
            deviceLocation: deviceLocation
        )
        candidates = resolution.candidates
        pendingResolution = resolution

        if let confident = resolution.confidentPick {
            persist(candidate: confident)
            Haptics.success()
            dismiss()
        } else {
            // Always confirm when we resolved to a location via photos alone (no typed name), so
            // the user has a chance to correct — and confirm with NO candidates
            // too. That case used to save silently at the device's coordinate,
            // which is the wrong answer for the exact places MapKit cannot find:
            // a truck or a stall, pinned wherever the phone happened to be. The
            // picker's own empty state offers manual search and "write my own
            // name" (which pins it by hand).
            showPicker = true
        }
    }

    /// The venue is already confirmed — either handed in as `preselectedVenue` or picked from the
    /// search field — so there's nothing left to resolve. Only a neighbourhood label is missing
    /// (MapKit search results don't carry one), and the optional photos/note still feed the same
    /// local write-up path as the freeform save.
    private func save(confirmedVenue venue: VenueCandidate) async {
        // Already on the list — don't drop a second pin on the same spot.
        if VisitRepository(context: modelContext, userID: userID).existingWantToTry(matching: venue) != nil {
            Haptics.success()
            dismiss()
            return
        }

        let described = await LocationResolver.describe(coordinate: venue.coordinate)
        let resolvedAddress = venue.address ?? described.address
        pendingResolution = LocationResolution(
            coordinate: venue.coordinate,
            source: .manual,
            neighborhood: described.neighborhood,
            address: resolvedAddress,
            candidates: [venue],
            confidentPick: venue
        )

        persist(candidate: venue)
        Haptics.success()
        dismiss()
    }

    private func persist(candidate: VenueCandidate?, coordinate override: CLLocationCoordinate2D? = nil) {
        let coordinate = override
            ?? candidate?.coordinate
            ?? pendingResolution?.coordinate
            ?? CaptureCoordinator.nycFallback

        let typedName = name.trimmingCharacters(in: .whitespaces)
        let venueName = candidate?.name ?? (typedName.isEmpty ? "New Spot" : typedName)
        let category = candidate?.category ?? .other
        let neighborhood = pendingResolution?.neighborhood ?? "NYC"

        Task { @MainActor in
            let photoRows = await writePhotosToDisk()

            let place = Place(
                name: venueName,
                category: category,
                neighborhood: neighborhood,
                lat: coordinate.latitude,
                lng: coordinate.longitude,
                externalPOIId: candidate?.externalPOIId
            )

            let visit = Visit(
                title: venueName,
                tags: tags,
                note: note,
                address: candidate?.address ?? pendingResolution?.address ?? (address.isEmpty ? nil : address),
                nameOverride: typedName.isEmpty ? nil : typedName,
                locationSource: pendingResolution?.source ?? .manual,
                hadVoiceNote: hadVoiceNote,
                kind: .wantToTry
            )

            VisitRepository(context: modelContext, userID: userID)
                .insert(place: place, visit: visit, photos: photoRows)
            sync.requestSync(reason: .newLocalWrite)
        }
    }

    private func writePhotosToDisk() async -> [Photo] {
        await PhotoIngest.rows(from: photoItems)
    }
}

// MARK: - Helpers

private extension String {
    /// Signage is usually ALL CAPS. Convert to title case for a friendlier read, but keep small
    /// words lowercase like the rest of the app's copy.
    var titleCasedForVenue: String {
        // Leave anything with lowercase alone (already looks like natural text).
        guard self == uppercased() else { return self }
        let smallWords: Set<String> = ["and", "the", "of", "at", "in", "on", "to", "a", "an", "for", "with"]
        let words = split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        return words.enumerated().map { index, word in
            let lower = word.lowercased()
            if index != 0, smallWords.contains(lower) { return lower }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }
}
