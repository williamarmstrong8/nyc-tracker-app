import Foundation
import CoreLocation
import Observation

/// Why a place is surfaced on the Discover page.
enum DiscoverReason: String, CaseIterable, Sendable {
    case trending
    case newOpening
    case editorsPick

    var label: String {
        switch self {
        case .trending:    "Trending this week"
        case .newOpening:   "New this month"
        case .editorsPick:  "Editor's pick"
        }
    }

    var symbol: String {
        switch self {
        case .trending:    "chart.line.uptrend.xyaxis"
        case .newOpening:   "sparkles"
        case .editorsPick:  "star.fill"
        }
    }
}

/// A curated NYC venue surfaced on the Discover page — content the user hasn't necessarily
/// logged or heard about from friends. A future backend can replace this static list with a
/// real, refreshed feed; the shape (name/category/coordinate/blurb/tags/reason) is designed to
/// map directly onto that later.
struct DiscoverPlace: Identifiable, Hashable {
    let id: UUID
    let name: String
    let category: PlaceCategory
    let neighborhood: String
    let coordinate: CLLocationCoordinate2D
    let blurb: String
    let tags: [String]
    let reason: DiscoverReason

    static func == (lhs: DiscoverPlace, rhs: DiscoverPlace) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Curated "discover" content, grouped by why it's surfaced. Mock for now — same pattern as
/// `MockFriendsStore` — but the query surface (`trending`/`newOpenings`/`editorsPicks`/`byCategory`)
/// is what a live recommendations feed would slot into later.
@Observable
final class MockDiscoverStore {
    static let shared = MockDiscoverStore()

    let allPlaces: [DiscoverPlace]

    private init() {
        allPlaces = [
            DiscoverPlace(
                id: UUID(), name: "Bar Continental", category: .bar,
                neighborhood: "East Village",
                coordinate: CLLocationCoordinate2D(latitude: 40.7265, longitude: -73.9815),
                blurb: "Low-lit natural wine bar with a short, ever-changing by-the-glass list.",
                tags: ["natural-wine", "cozy"], reason: .trending
            ),
            DiscoverPlace(
                id: UUID(), name: "Miso Hungry", category: .restaurant,
                neighborhood: "Long Island City",
                coordinate: CLLocationCoordinate2D(latitude: 40.7447, longitude: -73.9485),
                blurb: "Tonkotsu ramen with a miso-forward broth people are already lining up for.",
                tags: ["ramen", "japanese"], reason: .trending
            ),
            DiscoverPlace(
                id: UUID(), name: "Fig & Fennel", category: .cafe,
                neighborhood: "Fort Greene",
                coordinate: CLLocationCoordinate2D(latitude: 40.6896, longitude: -73.9750),
                blurb: "Plant-forward all-day cafe — good light, better for working than talking.",
                tags: ["work-friendly", "coffee-shop"], reason: .trending
            ),
            DiscoverPlace(
                id: UUID(), name: "Ember & Salt", category: .restaurant,
                neighborhood: "Williamsburg",
                coordinate: CLLocationCoordinate2D(latitude: 40.7081, longitude: -73.9571),
                blurb: "Live-fire steakhouse that just opened — reservations are already tight.",
                tags: ["steak", "date-night"], reason: .newOpening
            ),
            DiscoverPlace(
                id: UUID(), name: "Little Havana Coffee Co.", category: .cafe,
                neighborhood: "Harlem",
                coordinate: CLLocationCoordinate2D(latitude: 40.8116, longitude: -73.9465),
                blurb: "Cuban espresso and pastelitos from a family that's been roasting for decades.",
                tags: ["coffee-shop", "breakfast"], reason: .newOpening
            ),
            DiscoverPlace(
                id: UUID(), name: "Noodle & Bone", category: .restaurant,
                neighborhood: "Chinatown",
                coordinate: CLLocationCoordinate2D(latitude: 40.7158, longitude: -73.9970),
                blurb: "Hand-pulled noodles and a bone-broth soup base simmered for 18 hours.",
                tags: ["chinese", "lunch"], reason: .newOpening
            ),
            DiscoverPlace(
                id: UUID(), name: "Rubirosa", category: .restaurant,
                neighborhood: "Nolita",
                coordinate: CLLocationCoordinate2D(latitude: 40.7230, longitude: -73.9950),
                blurb: "Thin-crust vodka pizza that's been a downtown staple for years — always worth it.",
                tags: ["pizza", "italian"], reason: .editorsPick
            ),
            DiscoverPlace(
                id: UUID(), name: "Los Tacos No. 1", category: .restaurant,
                neighborhood: "Chelsea Market",
                coordinate: CLLocationCoordinate2D(latitude: 40.7424, longitude: -74.0061),
                blurb: "Adobada and nopal tacos, made to order, no matter how long the line looks.",
                tags: ["tacos", "casual"], reason: .editorsPick
            ),
            DiscoverPlace(
                id: UUID(), name: "Please Don't Tell", category: .bar,
                neighborhood: "East Village",
                coordinate: CLLocationCoordinate2D(latitude: 40.7268, longitude: -73.9835),
                blurb: "The hidden-door speakeasy that started the trend — still one of the best.",
                tags: ["cocktails", "hidden-gem"], reason: .editorsPick
            )
        ]
    }

    var trending: [DiscoverPlace] { allPlaces.filter { $0.reason == .trending } }
    var newOpenings: [DiscoverPlace] { allPlaces.filter { $0.reason == .newOpening } }
    var editorsPicks: [DiscoverPlace] { allPlaces.filter { $0.reason == .editorsPick } }

    func places(in category: PlaceCategory) -> [DiscoverPlace] {
        allPlaces.filter { $0.category == category }
    }
}
