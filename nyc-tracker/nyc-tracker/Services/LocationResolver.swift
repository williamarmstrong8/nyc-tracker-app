import Foundation
import CoreLocation
import Photos
import MapKit

/// A candidate venue returned by MapKit for the user to pick from (or auto-selected when confident).
struct VenueCandidate: Identifiable, Hashable {
    let id: String        // MKMapItem.Identifier string (or a fallback UUID)
    let name: String
    let category: PlaceCategory
    let coordinate: CLLocationCoordinate2D
    let address: String?
    let externalPOIId: String?

    static func == (lhs: VenueCandidate, rhs: VenueCandidate) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Convert an `MKMapItem` (from any MapKit search) into our neutral candidate type.
    static func from(mapItem item: MKMapItem) -> VenueCandidate {
        let identifierString = item.identifier.map { String(describing: $0) }
        let id = identifierString ?? UUID().uuidString
        return VenueCandidate(
            id: id,
            name: item.name ?? "Unknown",
            category: PlaceCategory.from(poi: item.pointOfInterestCategory),
            coordinate: item.location.coordinate,
            address: MapKitAddress.displayAddress(for: item),
            externalPOIId: identifierString
        )
    }
}

/// Reading addresses off an `MKMapItem` under the iOS 26 API.
///
/// `MKMapItem.placemark` — and with it `thoroughfare` / `subThoroughfare` /
/// `locality` / `subLocality` — is deprecated. The replacement exposes formatted
/// STRINGS (`MKAddress`, `MKAddressRepresentations`) rather than components, so
/// address text is no longer assembled here; MapKit formats it for the device's
/// region and we choose which of its forms to show.
///
/// The one thing genuinely lost is sub-locality. `CLPlacemark.subLocality`
/// returned "Carroll Gardens"; the new API's finest granularity is `cityName`,
/// which for the same coordinate is "Brooklyn". See `neighborhood(for:)`.
enum MapKitAddress {

    /// A one-line address for a venue row: street-level if MapKit has one,
    /// otherwise the full address minus the country.
    ///
    /// `shortAddress` first because that is the form Apple intends for compact
    /// display, and it is what the old `subThoroughfare + thoroughfare` string
    /// was reaching for by hand.
    static func displayAddress(for item: MKMapItem) -> String? {
        if let short = item.address?.shortAddress?.nonEmpty {
            return short
        }
        if let full = item.addressRepresentations?
            .fullAddress(includingRegion: false, singleLine: true)?.nonEmpty {
            return full
        }
        return item.address?.fullAddress.nonEmpty
    }

    /// The best available neighbourhood label.
    ///
    /// `cityWithContext` ("Brooklyn, NY") is deliberately NOT used as a
    /// fallback: this string is displayed as a neighbourhood on list rows and
    /// map groupings, and a state suffix would read as a different kind of
    /// thing next to "Carroll Gardens" on the row above it.
    static func neighborhood(for item: MKMapItem) -> String? {
        item.addressRepresentations?.cityName?.nonEmpty
    }
}

extension PlaceCategory {
    static func from(poi: MKPointOfInterestCategory?) -> PlaceCategory {
        switch poi {
        case .some(.restaurant): return .restaurant
        case .some(.bakery):     return .bakery
        case .some(.cafe):       return .cafe
        case .some(.brewery), .some(.winery), .some(.nightlife): return .bar
        default: return .other
        }
    }
}

/// Result of resolving a batch of photos into a place + venue candidates.
struct LocationResolution {
    var coordinate: CLLocationCoordinate2D?
    var source: LocationSource
    var neighborhood: String?
    var address: String?
    var candidates: [VenueCandidate]
    var confidentPick: VenueCandidate?
}

/// Turns a batch of photos + optional Name/Address hints into a resolved location and a set of
/// nearby venue candidates. All work is on-device; no network calls beyond MapKit's own services.
///
/// Priorities:
///   • Typed Name → broad NYC-metro name search first, distance is a tiebreaker.
///   • Otherwise: photo GPS → address hint → device location, then a POI search around the anchor.
///
/// The pipeline is guaranteed to end with *some* usable anchor: even when nothing resolves, we
/// return the NYC fallback + a reverse-geocoded address so the UI never faces a totally empty result.
enum LocationResolver {
    private static let nycFallback = CLLocationCoordinate2D(latitude: 40.7300, longitude: -73.9950)
    private static let nycRegion = MKCoordinateRegion(
        center: nycFallback,
        latitudinalMeters: 40_000,
        longitudinalMeters: 40_000
    )

    static func resolve(
        assetIdentifiers: [String],
        nameHint: String?,
        addressHint: String?,
        deviceLocation: CLLocation?
    ) async -> LocationResolution {
        let cleanedName = nameHint?.trimmingCharacters(in: .whitespaces).nonEmpty
        let photoCoordinate = await coordinatesFromAssets(assetIdentifiers: assetIdentifiers)
        let biasCoordinate = photoCoordinate ?? deviceLocation?.coordinate

        // === Name-first branch ================================================================
        if let name = cleanedName {
            let matches = await searchByName(name, biasedTo: biasCoordinate)
            if !matches.isEmpty {
                let ranked = rankByFuzzyName(matches, query: name, biasCoordinate: biasCoordinate)
                let top = Array(ranked.prefix(5))
                let confident = pickConfident(from: top, nameHint: name, biasCoordinate: biasCoordinate)
                let anchor = confident?.coordinate ?? top.first?.coordinate ?? biasCoordinate ?? nycFallback
                let (neighborhood, address) = await reverseGeocode(coordinate: anchor)
                let source: LocationSource = photoCoordinate != nil ? .photoGPS : (deviceLocation != nil ? .device : .manual)
                return LocationResolution(
                    coordinate: anchor,
                    source: source,
                    neighborhood: neighborhood,
                    address: address ?? confident?.address ?? top.first?.address,
                    candidates: top,
                    confidentPick: confident
                )
            }
        }

        // === Location-first branch ============================================================
        if let center = photoCoordinate {
            let (neighborhood, address) = await reverseGeocode(coordinate: center)
            let candidates = await nearbyVenues(near: center, nameHint: cleanedName)
            return LocationResolution(
                coordinate: center,
                source: .photoGPS,
                neighborhood: neighborhood,
                address: address ?? candidates.first?.address,
                candidates: candidates,
                confidentPick: pickConfident(from: candidates, nameHint: cleanedName, biasCoordinate: center)
            )
        }

        if let address = addressHint?.trimmingCharacters(in: .whitespaces).nonEmpty,
           let geocoded = await geocode(query: address)
        {
            let (neighborhood, resolvedAddress) = await reverseGeocode(coordinate: geocoded)
            let candidates = await nearbyVenues(near: geocoded, nameHint: cleanedName)
            return LocationResolution(
                coordinate: geocoded,
                source: .manual,
                neighborhood: neighborhood,
                address: resolvedAddress ?? address,
                candidates: candidates,
                confidentPick: pickConfident(from: candidates, nameHint: cleanedName, biasCoordinate: geocoded)
            )
        }

        if let live = deviceLocation {
            let coord = live.coordinate
            let (neighborhood, address) = await reverseGeocode(coordinate: coord)
            let candidates = await nearbyVenues(near: coord, nameHint: cleanedName)
            return LocationResolution(
                coordinate: coord,
                source: .device,
                neighborhood: neighborhood,
                address: address ?? candidates.first?.address,
                candidates: candidates,
                confidentPick: pickConfident(from: candidates, nameHint: cleanedName, biasCoordinate: coord)
            )
        }

        // === Absolute fallback ================================================================
        // We deliberately never return a fully-empty result. Reverse-geocode the NYC fallback so
        // the UI still has a neighborhood + address string to display.
        let (neighborhood, address) = await reverseGeocode(coordinate: nycFallback)
        return LocationResolution(
            coordinate: nycFallback,
            source: .manual,
            neighborhood: neighborhood,
            address: address ?? addressHint,
            candidates: [],
            confidentPick: nil
        )
    }

    /// A typed address → a coordinate.
    ///
    /// The counterpart to `describe`: used when the user is placing a venue by
    /// hand and types a street address instead of dragging the map to it. Nil
    /// means the address did not geocode, which the caller should treat as "keep
    /// the pin where it is" rather than as an error worth blocking on.
    static func locate(address: String) async -> CLLocationCoordinate2D? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await geocode(query: trimmed)
    }

    /// Neighbourhood + street address for a coordinate that is already trusted.
    ///
    /// The whole of `resolve` exists to *find* a venue. When the user picked one
    /// out of Apple Maps themselves there is nothing left to find — but a pin
    /// still needs a neighbourhood label, and MapKit's search result does not
    /// carry one. This is that one step, on its own.
    static func describe(
        coordinate: CLLocationCoordinate2D
    ) async -> (neighborhood: String?, address: String?) {
        await reverseGeocode(coordinate: coordinate)
    }

    // MARK: - Steps

    /// Read PHAsset locations, cluster them and return the tightest cluster's center.
    private static func coordinatesFromAssets(assetIdentifiers: [String]) async -> CLLocationCoordinate2D? {
        let ids = assetIdentifiers.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return nil }
        guard await requestPhotosAccess() else { return nil }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var locations: [CLLocation] = []
        assets.enumerateObjects { asset, _, _ in
            if let loc = asset.location { locations.append(loc) }
        }
        guard !locations.isEmpty else { return nil }
        if locations.count == 1 { return locations[0].coordinate }

        let clusterRadius: CLLocationDistance = 120
        var clusters: [[CLLocation]] = []
        for loc in locations {
            if let idx = clusters.firstIndex(where: { cluster in
                cluster.contains { $0.distance(from: loc) <= clusterRadius }
            }) {
                clusters[idx].append(loc)
            } else {
                clusters.append([loc])
            }
        }
        let best = clusters.max(by: { $0.count < $1.count }) ?? locations
        let lat = best.map(\.coordinate.latitude).reduce(0, +) / Double(best.count)
        let lng = best.map(\.coordinate.longitude).reduce(0, +) / Double(best.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// Address text → coordinate, via MapKit's `MKGeocodingRequest`.
    ///
    /// Replaces `CLGeocoder.geocodeAddressString`, deprecated in iOS 26. The
    /// initialiser is failable — it rejects an unusable query string outright,
    /// which is a free early exit the old API didn't offer.
    ///
    /// Biased to the NYC region, which `CLGeocoder` had no way to express: "575
    /// Henry St" is a real address in several states and this app is only ever
    /// asking about one of them.
    private static func geocode(query: String) async -> CLLocationCoordinate2D? {
        guard let request = MKGeocodingRequest(addressString: query) else { return nil }
        request.region = nycRegion
        do {
            let items = try await request.mapItems
            return items.first?.location.coordinate
        } catch {
            return nil
        }
    }

    /// Coordinate → neighbourhood + address, via `MKReverseGeocodingRequest`.
    ///
    /// Replaces `CLGeocoder.reverseGeocodeLocation`, deprecated in iOS 26.
    ///
    /// Known regression, and it is the API's rather than ours: the replacement
    /// has no sub-locality. Where this used to answer "Carroll Gardens" it now
    /// answers "Brooklyn", because `MKAddressRepresentations` stops at
    /// `cityName`. Everything downstream still works — the field is free text
    /// the user can edit — but map groupings and list rows are coarser for
    /// places resolved from a bare coordinate. Venues matched to a MapKit POI
    /// are unaffected; they carry their own address.
    private static func reverseGeocode(coordinate: CLLocationCoordinate2D) async -> (neighborhood: String?, address: String?) {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else {
            return (nil, nil)
        }
        do {
            let items = try await request.mapItems
            guard let item = items.first else { return (nil, nil) }
            return (MapKitAddress.neighborhood(for: item), MapKitAddress.displayAddress(for: item))
        } catch {
            return (nil, nil)
        }
    }

    /// Broad NYC-metro name search. Biases toward `biasCoordinate` in the region parameter but
    /// doesn't strictly limit results to it, so photos far from the venue still find it.
    private static func searchByName(_ name: String, biasedTo biasCoordinate: CLLocationCoordinate2D?) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.resultTypes = [.pointOfInterest]
        request.region = biasCoordinate.map {
            MKCoordinateRegion(center: $0, latitudinalMeters: 40_000, longitudinalMeters: 40_000)
        } ?? nycRegion
        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems
        } catch {
            return []
        }
    }

    /// POI-style search. Tries progressively wider radii so we're not blanked out at 200m.
    private static func nearbyVenues(near coordinate: CLLocationCoordinate2D, nameHint: String?) async -> [VenueCandidate] {
        if let name = nameHint?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 1_500, longitudinalMeters: 1_500)
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = name
            request.region = region
            request.resultTypes = [.pointOfInterest]
            if let response = try? await MKLocalSearch(request: request).start(), !response.mapItems.isEmpty {
                return rank(items: response.mapItems, near: coordinate).map(VenueCandidate.from(mapItem:))
            }
        }

        for radius in [250.0, 750.0, 2_000.0] as [CLLocationDistance] {
            let poi = MKLocalPointsOfInterestRequest(center: coordinate, radius: radius)
            poi.pointOfInterestFilter = MKPointOfInterestFilter(
                including: [.restaurant, .bakery, .cafe, .brewery, .winery, .nightlife]
            )
            if let response = try? await MKLocalSearch(request: poi).start(), !response.mapItems.isEmpty {
                return rank(items: response.mapItems, near: coordinate).map(VenueCandidate.from(mapItem:))
            }
        }
        return []
    }

    // MARK: - Ranking

    private static func rank(items: [MKMapItem], near coordinate: CLLocationCoordinate2D) -> [MKMapItem] {
        let center = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return items
            // `MKMapItem.location` is already a CLLocation in iOS 26, so the
            // rebuild-from-a-placemark-coordinate dance is gone.
            .sorted { a, b in
                a.location.distance(from: center) < b.location.distance(from: center)
            }
            .prefix(5)
            .map { $0 }
    }

    /// Fuzzy-name-first ranking; distance is a tiebreaker for equally-matching names.
    private static func rankByFuzzyName(
        _ items: [MKMapItem],
        query: String,
        biasCoordinate: CLLocationCoordinate2D?
    ) -> [VenueCandidate] {
        let normalizedQuery = normalize(query)
        let center = biasCoordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }

        struct Scored { let item: MKMapItem; let score: Int; let distance: CLLocationDistance }
        let scored: [Scored] = items.map { item in
            let name = normalize(item.name ?? "")
            let score = nameMatchScore(query: normalizedQuery, candidate: name)
            let distance: CLLocationDistance = {
                guard let center else { return .infinity }
                return item.location.distance(from: center)
            }()
            return Scored(item: item, score: score, distance: distance)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.distance < rhs.distance
            }
            .map { VenueCandidate.from(mapItem: $0.item) }
    }

    /// Normalize for fuzzy matching: fold apostrophes/curly-quotes, ampersands, punctuation, and
    /// collapse whitespace.
    private static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        // Strip all common punctuation that hurts matching (apostrophes, curly quotes, periods, hyphens).
        let dropped: Set<Character> = ["'", "\u{2019}", ".", "-", ",", "!", "?", ":", ";"]
        t = String(t.filter { !dropped.contains($0) })
        t = t.replacingOccurrences(of: "&", with: " and ")
        // Collapse runs of whitespace.
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return t
    }

    /// Aggressive fuzzy score: exact / prefix / contains / token-overlap / edit distance.
    private static func nameMatchScore(query: String, candidate: String) -> Int {
        guard !query.isEmpty, !candidate.isEmpty else { return 0 }
        if query == candidate { return 100 }
        if candidate.hasPrefix(query) || candidate.hasSuffix(query) { return 92 }
        if candidate.contains(query) { return 82 }
        if query.contains(candidate) { return 65 }

        let queryTokens = Set(query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let candidateTokens = Set(candidate.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        guard !queryTokens.isEmpty else { return 0 }
        let shared = queryTokens.intersection(candidateTokens).count
        let tokenScore = Int(45.0 * Double(shared) / Double(queryTokens.count))

        // Small boost for length-similar strings so "joes" doesn't match "trader joes market".
        let lengthDelta = abs(query.count - candidate.count)
        let lengthBoost = lengthDelta <= 3 ? 5 : 0
        return tokenScore + lengthBoost
    }

    /// Only auto-select when the top match clearly beats the runner-up.
    private static func pickConfident(
        from candidates: [VenueCandidate],
        nameHint: String?,
        biasCoordinate: CLLocationCoordinate2D?
    ) -> VenueCandidate? {
        guard let top = candidates.first else { return nil }
        if candidates.count == 1, nameHint != nil { return top }  // single name-match is confident

        guard let hint = nameHint?.trimmingCharacters(in: .whitespaces), !hint.isEmpty else {
            return nil
        }
        let hintN = normalize(hint)
        let topScore = nameMatchScore(query: hintN, candidate: normalize(top.name))
        let runnerScore = candidates.dropFirst().map { nameMatchScore(query: hintN, candidate: normalize($0.name)) }.max() ?? 0
        if topScore >= 82, topScore - runnerScore >= 30 { return top }
        return nil
    }

    // MARK: - Permissions

    private static func requestPhotosAccess() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch current {
        case .authorized, .limited: return true
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: status == .authorized || status == .limited)
                }
            }
            return granted
        default: return false
        }
    }
}

// MARK: - Small helpers

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
