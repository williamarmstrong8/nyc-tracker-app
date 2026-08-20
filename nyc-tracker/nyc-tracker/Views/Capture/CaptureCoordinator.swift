import SwiftUI
import PhotosUI
import Photos
import CoreLocation
import UIKit

/// Drives the capture flow: details → processing → venue picker (optional) → write-up preview → confirm/edit.
///
/// The picker is presented from ContentView directly, so by the time this coordinator becomes
/// active the user has already picked their photos.
@MainActor
@Observable
final class CaptureCoordinator {
    enum Stage: Equatable {
        case details
        case processing
        case venuePicker
        case writeUp
    }

    var stage: Stage = .details
    var selectedItems: [PhotosPickerItem] = []
    var addressInput: String = ""
    var nameInput: String = ""
    var tagsInput: String = ""
    var transcript: String = ""
    /// Friends the user says were there. Empty is the common case.
    var taggedPeople: [PersonSummary] = []

    /// When the visit happened. Seeded to now, so an entry logged the same day
    /// needs no input; the user moves it when they are catching up on a place
    /// they went to last week. Everything in the app orders on this, so leaving
    /// it alone means "order me by when I uploaded", which is the right default.
    var visitedOn: Date = Date()

    /// Audio file that backs the transcript, if any.
    var hadVoiceNote: Bool = false

    // Location resolution (populated by submitDetails).
    var resolvedCoordinate: CLLocationCoordinate2D?
    var resolvedNeighborhood: String?
    var resolvedAddress: String?
    var resolvedLocationSource: LocationSource = .manual
    var venueCandidates: [VenueCandidate] = []
    var chosenVenue: VenueCandidate?
    var rawPlaceGuess: String?

    /// Set when the entry started from an Apple Maps search rather than from
    /// photos. The venue is then already known, so `submitDetails` skips venue
    /// resolution entirely instead of searching for a place the user has
    /// already pointed at.
    var preselectedVenue: VenueCandidate?

    // Produced by enrichment; edited by user in the write-up.
    var draftTitle: String = ""
    var draftTags: [String] = []
    var draftDescription: String = ""
    var draftTopQuote: String = ""
    var draftRating: Rating?
    var draftReturnIntent: ReturnIntent?
    var draftDish: String?
    var draftCompanions: String?
    /// Venue type, seeded from the resolved MapKit venue but user-editable — MapKit
    /// sometimes mistags a venue (a restaurant showing up as a cafe, say).
    var draftCategory: PlaceCategory = .restaurant

    var isPresented: Bool = false

    /// Begin the capture flow with a set of photos the user already picked from the library.
    ///
    /// `venue` is non-nil when the entry began from an Apple Maps search, in
    /// which case the name field is pre-filled and no venue picker is shown.
    func begin(with items: [PhotosPickerItem], venue: VenueCandidate? = nil) {
        reset()
        selectedItems = items
        preselectedVenue = venue
        if let venue {
            nameInput = venue.name
            addressInput = venue.address ?? ""
        }
        stage = .details
        isPresented = true
    }

    func reset() {
        selectedItems = []
        addressInput = ""
        nameInput = ""
        tagsInput = ""
        transcript = ""
        taggedPeople = []
        visitedOn = Date()
        hadVoiceNote = false
        resolvedCoordinate = nil
        resolvedNeighborhood = nil
        resolvedAddress = nil
        resolvedLocationSource = .manual
        venueCandidates = []
        chosenVenue = nil
        rawPlaceGuess = nil
        preselectedVenue = nil
        draftTitle = ""
        draftTags = []
        draftDescription = ""
        draftTopQuote = ""
        draftRating = nil
        draftReturnIntent = nil
        draftDish = nil
        draftCompanions = nil
        draftCategory = .restaurant
    }

    /// Runs location resolution + enrichment on the current inputs. If a confident venue match
    /// isn't found, we route through the venue picker before showing the write-up.
    func submitDetails(using enricher: EnricherProtocol) async {
        stage = .processing

        // 1) Location resolution
        if let venue = preselectedVenue {
            // Nothing to resolve. Photo GPS is deliberately ignored here: the
            // user picked this venue by name, and photos of a dinner are often
            // taken somewhere else entirely (or carry no location at all).
            // Letting the resolver run would sometimes move the pin off the
            // place they explicitly chose.
            await applyPreselected(venue)
        } else {
            let assetIdentifiers = selectedItems.compactMap { $0.itemIdentifier }
            let deviceLocation = await LocationProvider.shared.currentLocation()
            let resolution = await LocationResolver.resolve(
                assetIdentifiers: assetIdentifiers,
                nameHint: nameInput.isEmpty ? nil : nameInput,
                addressHint: addressInput.isEmpty ? nil : addressInput,
                deviceLocation: deviceLocation
            )

            resolvedCoordinate = resolution.coordinate
            resolvedNeighborhood = resolution.neighborhood
            resolvedAddress = resolution.address
            resolvedLocationSource = resolution.source
            venueCandidates = resolution.candidates
            chosenVenue = resolution.confidentPick
        }
        rawPlaceGuess = nameInput.isEmpty ? nil : nameInput
        draftCategory = chosenVenue?.category ?? .restaurant

        // 2) Enrichment
        let tagHints = tagsInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let input = EnricherInput(
            nameHint: nameInput.isEmpty ? nil : nameInput,
            addressHint: (resolution.address ?? addressInput).isEmptyNil,
            venueName: chosenVenue?.name,
            venueCategory: chosenVenue?.category,
            tagHints: tagHints,
            transcript: transcript
        )

        do {
            let output = try await enricher.enrich(input)
            draftTitle = chosenVenue?.name.nonEmpty ?? output.title
            draftTags = output.tags
            draftDescription = output.enrichedDescription
            draftTopQuote = output.topQuote
            if draftRating == nil {
                draftRating = output.suggestedRating
            }
            draftDish = output.dish
            draftCompanions = output.companions
        } catch {
            draftTitle = chosenVenue?.name.nonEmpty ?? (nameInput.isEmpty ? "New Spot" : nameInput)
            draftTags = tagHints
            draftDescription = transcript
            draftTopQuote = ""
        }

        // 3) If we don't have a confident venue pick, always show the picker so the user can
        //    confirm, tap a candidate, or fall back to manual search. A venue
        //    the user chose off the map is already confirmed and skips it.
        if chosenVenue == nil {
            stage = .venuePicker
        } else {
            stage = .writeUp
        }
    }

    /// Seed the resolution fields from a venue the user chose in Apple Maps.
    ///
    /// Only the neighbourhood needs a round trip — MapKit search results carry a
    /// name, a coordinate and an address, but no neighbourhood label, and that
    /// is what list rows and map groupings display.
    private func applyPreselected(_ venue: VenueCandidate) async {
        chosenVenue = venue
        venueCandidates = [venue]
        resolvedCoordinate = venue.coordinate
        resolvedAddress = venue.address
        resolvedLocationSource = .manual

        let described = await LocationResolver.describe(coordinate: venue.coordinate)
        resolvedNeighborhood = described.neighborhood
        resolvedAddress = venue.address ?? described.address
    }

    /// User picked a venue in the venue picker sheet; update the draft and advance.
    func applyVenue(_ venue: VenueCandidate?) {
        chosenVenue = venue
        if let venue {
            draftTitle = venue.name
            resolvedAddress = venue.address ?? resolvedAddress
            draftCategory = venue.category
        }
        stage = .writeUp
    }

    /// Commit the current draft to SwiftData through the repository and dismiss the flow.
    /// Returns the newly persisted Visit so callers can pan the map to it.
    func confirm(using repository: VisitRepository) async -> Visit {
        // Downscale, thumbnail, and read metadata off each picked photo, then
        // write both sizes to disk. This is the only image processing in the
        // flow — the upload reuses these exact files.
        let photoRows = await PhotoIngest.rows(from: selectedItems)

        let coordinate = resolvedCoordinate ?? chosenVenue?.coordinate ?? Self.nycFallback
        let category = draftCategory
        let neighborhood = resolvedNeighborhood ?? "NYC"
        let resolvedTitle = draftTitle.isEmpty ? (chosenVenue?.name ?? "New Spot") : draftTitle

        // Been here before? Fold this occasion into the existing log instead of a duplicate pin.
        if let existingVisit = repository.existingVisitedVisit(
            externalPOIId: chosenVenue?.externalPOIId,
            name: resolvedTitle,
            coordinate: coordinate
        ) {
            repository.appendVisitOccasion(
                to: existingVisit,
                photos: photoRows,
                transcript: transcript,
                description: draftDescription,
                tags: draftTags,
                topQuote: draftTopQuote,
                rating: draftRating,
                returnIntent: draftReturnIntent,
                visitedOn: visitedOn,
                tagged: taggedPeople
            )
            Haptics.success()
            isPresented = false
            return existingVisit
        }

        let place = Place(
            name: resolvedTitle,
            category: category,
            neighborhood: neighborhood,
            lat: coordinate.latitude,
            lng: coordinate.longitude,
            externalPOIId: chosenVenue?.externalPOIId
        )

        let visit = Visit(
            visitedOn: visitedOn,
            title: draftTitle,
            tags: draftTags,
            enrichedDescription: draftDescription,
            transcript: transcript,
            topQuote: draftTopQuote,
            rating: draftRating,
            returnIntent: draftReturnIntent,
            address: resolvedAddress ?? (addressInput.isEmpty ? nil : addressInput),
            nameOverride: nameInput.isEmpty ? nil : nameInput,
            locationSource: resolvedLocationSource,
            published: false,
            createdAt: Date(),
            hadVoiceNote: hadVoiceNote,
            rawPlaceGuess: rawPlaceGuess,
            kind: .visited
        )

        repository.insert(place: place, visit: visit, photos: photoRows, tagged: taggedPeople)
        Haptics.success()
        isPresented = false
        return visit
    }

    // MARK: - Helpers

    static let nycFallback = CLLocationCoordinate2D(latitude: 40.7300, longitude: -73.9950)
}

// MARK: - Small string helpers

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
    var isEmptyNil: String? { isEmpty ? nil : self }
}

private extension Optional where Wrapped == String {
    var isEmptyNil: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
