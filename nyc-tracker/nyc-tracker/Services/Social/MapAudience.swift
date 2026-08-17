import Foundation
import MapKit
import Observation

/// Whose visits the map is showing.
///
/// Three modes rather than a set of user IDs. A multi-select would be more
/// general, but "which friends am I looking at" is not a question anyone asks —
/// they want their own map, everyone's, or one person's — and a set makes the
/// control unbounded, the persisted value unbounded, and the empty states
/// combinatorial.
enum MapAudience: Hashable, Sendable {
    /// Only the signed-in user's visits. The only mode that works offline.
    case mine
    /// Every accepted friend's visits — not the signed-in user's.
    case allFriends
    /// One specific friend's visits — not the signed-in user's.
    case friend(UUID)

    /// True when this mode needs the network. Drives the offline notice: the
    /// user's own map is local and always works, friend data never is, and
    /// showing an empty map instead of saying so reads as "they've been nowhere".
    var requiresNetwork: Bool {
        self != .mine
    }

    /// The `user_ids` argument for `visits_in_bounds`.
    ///
    /// `.allFriends` sends `nil`, which the function resolves server-side with
    /// `friend_ids()` — the client does not re-send a friend list it just
    /// fetched, and the answer cannot drift from the graph.
    ///
    /// `.mine` traps rather than returning something: the SQL reads both `null`
    /// and `{}` as "caller and friends", so there is no array that means "only
    /// me" to pass here. Every caller is already gated on `requiresNetwork`, and
    /// a crash in debug beats silently fetching friend data for a mode that is
    /// supposed to be local-only.
    func remoteUserIDs() -> [UUID]? {
        switch self {
        case .mine:
            assertionFailure("`.mine` is served from SwiftData and must not be fetched remotely")
            return nil
        case .allFriends:
            return nil
        case .friend(let id):
            return [id]
        }
    }

    // MARK: - Persistence

    /// Round-trips through a single string so the whole thing is one
    /// `UserDefaults` value. `friend:<uuid>` is unambiguous because the other two
    /// cases are fixed words.
    var storageValue: String {
        switch self {
        case .mine:           "mine"
        case .allFriends:     "allFriends"
        case .friend(let id): "friend:\(id.uuidString)"
        }
    }

    init?(storageValue raw: String) {
        switch raw {
        case "mine":       self = .mine
        case "allFriends": self = .allFriends
        default:
            guard raw.hasPrefix("friend:"),
                  let id = UUID(uuidString: String(raw.dropFirst("friend:".count)))
            else { return nil }
            self = .friend(id)
        }
    }
}

/// The map audience selection, persisted across launches and scoped per user.
///
/// Per-user because the selection can name a specific friend, and that friend is
/// meaningless to a different account signed in on the same device.
@Observable
final class MapAudienceStore {

    private(set) var audience: MapAudience = .mine

    private var userID: UUID?

    private static let keyPrefix = "nyc-tracker.mapAudience.v1."

    private var defaultsKey: String? {
        guard let userID else { return nil }
        return Self.keyPrefix + userID.uuidString
    }

    init() {}

    func configure(userID: UUID) {
        guard self.userID != userID else { return }
        self.userID = userID

        guard
            let key = defaultsKey,
            let raw = UserDefaults.standard.string(forKey: key),
            let restored = MapAudience(storageValue: raw)
        else {
            audience = .mine
            return
        }
        audience = restored
    }

    func teardown() {
        userID = nil
        audience = .mine
    }

    func select(_ audience: MapAudience) {
        guard self.audience != audience else { return }
        self.audience = audience
        persist()
    }

    /// Drop back to `.mine` if the selected friend is no longer a friend.
    ///
    /// Covers unfriending while their pins are on screen, and the restored-from-
    /// disk case where the friendship ended on another device between launches.
    /// Returns true if it had to reset, so the caller can clear fetched pins.
    @discardableResult
    func reconcile(against friendIDs: [UUID], hasLoadedGraph: Bool) -> Bool {
        // Before the graph loads, `friendIDs` is empty for a reason that has
        // nothing to do with the friendship — resetting here would clobber a
        // perfectly valid restored selection on every cold launch.
        guard hasLoadedGraph else { return false }

        switch audience {
        case .mine:
            return false
        case .allFriends:
            return false
        case .friend(let id):
            guard !friendIDs.contains(id) else { return false }
            select(.mine)
            return true
        }
    }

    private func persist() {
        guard let defaultsKey else { return }
        UserDefaults.standard.set(audience.storageValue, forKey: defaultsKey)
    }
}

// MARK: - Bounds

/// A lat/lng rectangle, in the shape `visits_in_bounds` expects.
///
/// `MKCoordinateRegion` is center+span and needs converting at every call site;
/// this converts once and is comparable, which is what the coverage check needs.
struct GeoBounds: Equatable, Sendable {
    var minLat: Double
    var maxLat: Double
    var minLng: Double
    var maxLng: Double

    /// True when the box straddles ±180°, in which case `minLng > maxLng` and
    /// longitude containment is a disjunction rather than a range.
    var wrapsAntimeridian: Bool { minLng > maxLng }

    init(minLat: Double, maxLat: Double, minLng: Double, maxLng: Double) {
        self.minLat = minLat
        self.maxLat = maxLat
        self.minLng = minLng
        self.maxLng = maxLng
    }

    init(region: MKCoordinateRegion) {
        let halfLat = region.span.latitudeDelta / 2
        let halfLng = region.span.longitudeDelta / 2

        minLat = max(-90, region.center.latitude - halfLat)
        maxLat = min(90, region.center.latitude + halfLat)

        // A span wide enough to cover the globe collapses to the whole range
        // rather than wrapping onto itself.
        if region.span.longitudeDelta >= 360 {
            minLng = -180
            maxLng = 180
        } else {
            minLng = Self.normalizeLongitude(region.center.longitude - halfLng)
            maxLng = Self.normalizeLongitude(region.center.longitude + halfLng)
        }
    }

    /// Wrap into [-180, 180]. MapKit will happily hand back a center longitude
    /// outside that range after the user pans across the date line.
    private static func normalizeLongitude(_ value: Double) -> Double {
        var result = value.truncatingRemainder(dividingBy: 360)
        if result > 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result
    }

    func containsLongitude(_ longitude: Double) -> Bool {
        wrapsAntimeridian
            ? (longitude >= minLng || longitude <= maxLng)
            : (longitude >= minLng && longitude <= maxLng)
    }

    /// True when `other` lies entirely inside this box.
    ///
    /// Used to decide whether an already-fetched result still covers the visible
    /// map. Conservatively returns false whenever either box wraps the
    /// antimeridian — the containment maths is correct but fiddly, and getting it
    /// wrong means silently showing stale pins. An extra fetch is the cheaper
    /// failure, and it only happens in the middle of the Pacific.
    func contains(_ other: GeoBounds) -> Bool {
        guard !wrapsAntimeridian, !other.wrapsAntimeridian else { return false }
        return other.minLat >= minLat
            && other.maxLat <= maxLat
            && other.minLng >= minLng
            && other.maxLng <= maxLng
    }

    /// Grow the box by a fraction of its own size on each axis, so a small pan
    /// stays inside what was already fetched instead of triggering a request.
    func expanded(by fraction: Double) -> GeoBounds {
        let latPad = (maxLat - minLat) * fraction
        let lngSpan = wrapsAntimeridian
            ? (180 - minLng) + (maxLng + 180)
            : maxLng - minLng
        let lngPad = lngSpan * fraction

        return GeoBounds(
            minLat: max(-90, minLat - latPad),
            maxLat: min(90, maxLat + latPad),
            minLng: max(-180, minLng - lngPad),
            maxLng: min(180, maxLng + lngPad)
        )
    }
}
