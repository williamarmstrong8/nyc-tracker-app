import SwiftUI
import SwiftData
import PhotosUI
import CoreLocation

/// "Add a place to try" sheet. Uses a scrolling VStack (not a Form) so tapping into a field
/// doesn't shuffle the layout. Photos + a short voice memo are both optional — when present, they
/// feed the same LocationResolver + FoundationModelsEnricher pipeline the real capture flow uses.
///
/// If the user adds photos without typing a name, Vision-based OCR extracts a likely venue name
/// from the biggest, most confident piece of text in the frame (typically storefront signage).
struct WantToTryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name: String = ""
    @State private var address: String = ""
    @State private var tags: String = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotosPicker: Bool = false
    @State private var transcript: String = ""
    @State private var audioRelativePath: String?

    /// Set when we auto-populated `name` from OCR — used to show the little "detected" hint and to
    /// clear the flag if the user starts editing.
    @State private var nameWasAutoDetected: Bool = false
    @State private var isDetectingName: Bool = false

    @State private var recorder: any RecorderProtocol = SpeechRecorder()

    @State private var candidates: [VenueCandidate] = []
    @State private var isResolving: Bool = false
    @State private var showPicker: Bool = false
    @State private var pendingResolution: LocationResolution?
    @State private var pendingEnrichment: EnricherOutput?

    @FocusState private var focused: Field?
    enum Field { case name, address, tags }

    private let enricher: EnricherProtocol = FoundationModelsEnricher()

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

                    voiceMemoSection

                    fieldsSection

                    saveButton

                    Spacer(minLength: 40)
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
                    Button("Done") { focused = nil }
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
                // If the user hasn't typed a name yet, try to read it off the photo(s).
                if name.trimmingCharacters(in: .whitespaces).isEmpty, !newItems.isEmpty {
                    Task { await detectNameFromPhotos(newItems) }
                }
            }
            .onChange(of: name) { _, newValue in
                // As soon as the user starts editing, stop calling the value "detected".
                if nameWasAutoDetected, !newValue.isEmpty {
                    nameWasAutoDetected = false
                }
            }
            .sheet(isPresented: $showPicker) {
                NavigationStack {
                    VenuePickerView(
                        candidates: candidates,
                        biasCoordinate: pendingResolution?.coordinate
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
            .task {
                await enricher.prewarm()
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Save a place you want to try")
                .font(.title3.weight(.semibold))
            Text("Just a photo works — we'll read the name off the sign and pin it on the map.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(photoItems, id: \.itemIdentifier) { item in
                    PhotoView(source: .pickerItem(item), contentMode: .fill)
                        .frame(width: 120, height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
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

    private var voiceMemoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Voice note (optional)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HoldToRecordButton(recorder: recorder, hasRecording: !transcript.isEmpty) { result in
                transcript = result.transcript
                audioRelativePath = result.audioRelativePath
            }
            .frame(maxWidth: .infinity, alignment: transcript.isEmpty ? .leading : .center)
            if !transcript.isEmpty {
                Text(transcript)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
            }
        }
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                LabeledField(title: "Name", text: $name, placeholder: "e.g. Katz's Deli")
                    .focused($focused, equals: .name)
                if isDetectingName {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Reading name from photo…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if nameWasAutoDetected, !name.isEmpty {
                    Label("Detected from photo — tap to correct", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledField(title: "Address (optional)", text: $address, placeholder: "e.g. 205 E Houston St")
                .focused($focused, equals: .address)
            LabeledField(title: "Tags (optional, comma separated)", text: $tags, placeholder: "pastrami, iconic")
                .focused($focused, equals: .tags)
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
    /// the name field is still empty at completion time.
    private func detectNameFromPhotos(_ items: [PhotosPickerItem]) async {
        isDetectingName = true
        defer { isDetectingName = false }

        var datas: [Data] = []
        for item in items.prefix(3) {  // OCR up to first 3 photos to keep it snappy
            if let data = try? await item.loadTransferable(type: Data.self) {
                datas.append(data)
            }
        }
        guard !datas.isEmpty else { return }
        guard let detected = await TextRecognizer.recognizePlaceName(fromBatch: datas) else { return }

        // Only apply if the user hasn't started typing since we began.
        guard name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        name = detected.titleCasedForVenue
        nameWasAutoDetected = true
    }

    // MARK: - Save

    private func save() async {
        focused = nil
        isResolving = true
        defer { isResolving = false }

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

        // If the user gave a voice memo, ask the on-device model to summarize it into tags/description.
        if !transcript.isEmpty {
            let input = EnricherInput(
                nameHint: nameHint.isEmpty ? nil : nameHint,
                addressHint: resolution.address ?? (address.isEmpty ? nil : address),
                venueName: resolution.confidentPick?.name,
                venueCategory: resolution.confidentPick?.category,
                tagHints: parsedTags(),
                transcript: transcript
            )
            pendingEnrichment = try? await enricher.enrich(input)
        }

        if let confident = resolution.confidentPick {
            persist(candidate: confident)
            Haptics.success()
            dismiss()
        } else if !candidates.isEmpty {
            // Always confirm when we resolved to a location via photos alone (no typed name), so
            // the user has a chance to correct.
            showPicker = true
        } else {
            persist(candidate: nil, coordinate: resolution.coordinate ?? deviceLocation?.coordinate)
            Haptics.success()
            dismiss()
        }
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

        let userTags = parsedTags()
        let modelTags = pendingEnrichment?.tags ?? []
        let mergedTags = (modelTags + userTags).uniqued()

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
                tags: mergedTags,
                enrichedDescription: pendingEnrichment?.enrichedDescription ?? "",
                transcript: transcript,
                topQuote: pendingEnrichment?.topQuote ?? "",
                address: candidate?.address ?? pendingResolution?.address ?? (address.isEmpty ? nil : address),
                nameOverride: typedName.isEmpty ? nil : typedName,
                locationSource: pendingResolution?.source ?? .manual,
                audioRelativePath: audioRelativePath,
                kind: .wantToTry
            )

            VisitRepository(context: modelContext).insert(place: place, visit: visit, photos: photoRows)
        }
    }

    private func writePhotosToDisk() async -> [Photo] {
        var rows: [Photo] = []
        for (index, item) in photoItems.enumerated() {
            var relativePath: String?
            if let data = try? await item.loadTransferable(type: Data.self) {
                let ext = detectExtension(for: data)
                if let written = try? FileStorage.writeData(data, kind: .photos, fileExtension: ext) {
                    relativePath = written.relativePath
                }
            }
            rows.append(Photo(
                relativePath: relativePath,
                assetLocalIdentifier: item.itemIdentifier,
                order: index
            ))
        }
        return rows
    }

    private func detectExtension(for data: Data) -> String {
        if data.count >= 4 {
            let sig = [UInt8](data.prefix(4))
            if sig[0] == 0x89, sig[1] == 0x50, sig[2] == 0x4E, sig[3] == 0x47 { return "png" }
            if sig[0] == 0xFF, sig[1] == 0xD8, sig[2] == 0xFF { return "jpg" }
            if sig[0] == 0x00, sig[1] == 0x00, sig[2] == 0x00 { return "heic" }
        }
        return "jpg"
    }

    private func parsedTags() -> [String] {
        tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Helpers

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

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
