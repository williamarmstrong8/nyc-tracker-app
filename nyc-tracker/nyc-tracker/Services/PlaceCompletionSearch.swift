import Foundation
import MapKit
import Observation

/// Thin Observable wrapper around `MKLocalSearchCompleter` for as-you-type venue suggestions.
/// SwiftUI views observe `results` and set `query` on each keystroke.
@Observable
@MainActor
final class PlaceCompletionSearch: NSObject, MKLocalSearchCompleterDelegate {
    var query: String = ""
    var results: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
        completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.7300, longitude: -73.9950),
            latitudinalMeters: 40_000,
            longitudinalMeters: 40_000
        )
    }

    /// Center the completer on the map viewport (or caller-supplied context).
    func setRegion(_ region: MKCoordinateRegion) {
        completer.region = region
    }

    /// Center the region on the user's current context, if we know it (photo GPS / device location).
    func setBias(_ coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else { return }
        setRegion(MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 20_000,
            longitudinalMeters: 20_000
        ))
    }

    func update(query: String) {
        self.query = query
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            results = []
            completer.cancel()
        } else {
            completer.queryFragment = trimmed
        }
    }

    /// Resolve a completion into a full `VenueCandidate` (i.e. actual coordinate + address).
    static func resolve(_ completion: MKLocalSearchCompletion) async -> VenueCandidate? {
        let request = MKLocalSearch.Request(completion: completion)
        request.resultTypes = [.pointOfInterest, .address]
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first
        else {
            return nil
        }
        return VenueCandidate.from(mapItem: item)
    }

    /// Map search variant — biases resolution to the visible viewport so a
    /// partial name in NYC does not land on a homonym three time zones away.
    static func resolve(
        _ completion: MKLocalSearchCompletion,
        in region: MKCoordinateRegion
    ) async -> VenueCandidate? {
        let request = MKLocalSearch.Request(completion: completion)
        request.resultTypes = [.pointOfInterest, .address]
        request.region = region
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first
        else {
            return nil
        }
        return VenueCandidate.from(mapItem: item)
    }

    // MARK: - MKLocalSearchCompleterDelegate

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in
            self.results = completer.results
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.results = []
        }
    }
}
