import Foundation
import SwiftUI

/// A mock person in the friend graph. A future networking layer will replace this with a real
/// profile fetched from the backend; the shape (name/handle/bio/avatar) is designed to map
/// directly onto that later.
struct Friend: Identifiable, Hashable {
    let id: UUID
    let name: String
    let handle: String
    let neighborhood: String
    let bio: String
    let avatarSymbol: String
    let avatarTint: Color
}

enum FriendActivityKind: Hashable {
    case visited
    case wantToTry
}

struct FriendActivity: Identifiable, Hashable {
    let id: UUID
    let friendID: UUID
    let kind: FriendActivityKind
    let placeName: String
    let category: PlaceCategory
    let neighborhood: String
    let quote: String?
    let tags: [String]
    let daysAgo: Int
    let rating: Rating?
}

/// A place aggregated across the friend graph — used for the "trending among friends" list.
struct FriendTrendingPlace: Hashable {
    let placeName: String
    let category: PlaceCategory
    let neighborhood: String
    let friends: [Friend]
}

/// Mock friend graph + a locally-persisted "who I follow" set, so add/remove feels real across
/// launches even though there's no backend yet. A future networking layer will replace the
/// directory + activity feed with real fetches; `myFriendIDs` maps onto a real "following" table.
///
/// The view API (myFriends/suggested/activities/matching/toggleFriend) can stay the same when
/// that swap happens.
@Observable
final class MockFriendsStore {
    static let shared = MockFriendsStore()

    /// Every person in the mock directory, friend or not.
    let allPeople: [Friend]
    let activities: [FriendActivity]

    private static let defaultsKey = "nyc-tracker.myFriendIDs.v1"

    var friendIDs: Set<UUID> {
        didSet { persist() }
    }

    private init() {
        let alex = Friend(
            id: UUID(), name: "Alex Rivera", handle: "alexeatsnyc",
            neighborhood: "West Village", bio: "Pizza completionist. Always down for a late-night slice.",
            avatarSymbol: "flame.fill", avatarTint: .orange
        )
        let maya = Friend(
            id: UUID(), name: "Maya Chen", handle: "maya.wanders",
            neighborhood: "Lower East Side", bio: "Natural wine + small plates. Will talk your ear off about orange wine.",
            avatarSymbol: "wineglass.fill", avatarTint: .purple
        )
        let sam = Friend(
            id: UUID(), name: "Sam Okafor", handle: "sameatsramen",
            neighborhood: "East Village", bio: "Ramen and noodle soups, ranked by broth depth.",
            avatarSymbol: "bowl.fill", avatarTint: .red
        )
        let jordan = Friend(
            id: UUID(), name: "Jordan Blake", handle: "jblakecocktails",
            neighborhood: "West Village", bio: "Cocktail bars with no menu are a personality trait at this point.",
            avatarSymbol: "sparkles", avatarTint: .indigo
        )
        let riley = Friend(
            id: UUID(), name: "Riley Park", handle: "rileyroasts",
            neighborhood: "Williamsburg", bio: "Coffee shop hopper. Judges a place by its oat milk.",
            avatarSymbol: "cup.and.saucer.fill", avatarTint: .brown
        )
        let nico = Friend(
            id: UUID(), name: "Nico Tanaka", handle: "nico.bites",
            neighborhood: "Carroll Gardens", bio: "Will wait two hours for the right slice. No regrets.",
            avatarSymbol: "star.fill", avatarTint: .pink
        )
        let devon = Friend(
            id: UUID(), name: "Devon Ellis", handle: "devoneats",
            neighborhood: "FiDi", bio: "Rooftop bars with a view, ideally with a great martini.",
            avatarSymbol: "building.2.fill", avatarTint: .teal
        )
        let priya = Friend(
            id: UUID(), name: "Priya Shah", handle: "priya.nyc",
            neighborhood: "Chinatown", bio: "Dumplings, always. Will die on the soup dumpling hill.",
            avatarSymbol: "leaf.fill", avatarTint: .green
        )

        let people = [alex, maya, sam, jordan, riley, nico, devon, priya]
        self.allPeople = people
        self.activities = Self.makeSeed(alex: alex, maya: maya, sam: sam, jordan: jordan, riley: riley, nico: nico, devon: devon, priya: priya)

        if let saved = UserDefaults.standard.array(forKey: Self.defaultsKey) as? [String] {
            self.friendIDs = Set(saved.compactMap(UUID.init(uuidString:)))
        } else {
            // First launch: seed a few friends so the page isn't empty.
            self.friendIDs = Set([alex, maya, jordan, riley].map(\.id))
        }
    }

    // MARK: - Friend management

    var myFriends: [Friend] {
        allPeople.filter { friendIDs.contains($0.id) }.sorted { $0.name < $1.name }
    }

    var suggested: [Friend] {
        allPeople.filter { !friendIDs.contains($0.id) }.sorted { $0.name < $1.name }
    }

    func isFriend(_ friend: Friend) -> Bool {
        friendIDs.contains(friend.id)
    }

    func addFriend(_ friend: Friend) {
        friendIDs.insert(friend.id)
    }

    func removeFriend(_ friend: Friend) {
        friendIDs.remove(friend.id)
    }

    func toggleFriend(_ friend: Friend) {
        if isFriend(friend) {
            removeFriend(friend)
        } else {
            addFriend(friend)
        }
    }

    private func persist() {
        UserDefaults.standard.set(friendIDs.map(\.uuidString), forKey: Self.defaultsKey)
    }

    // MARK: - Lookups

    func friend(for id: UUID) -> Friend? {
        allPeople.first { $0.id == id }
    }

    func activities(for friendID: UUID) -> [FriendActivity] {
        activities.filter { $0.friendID == friendID }.sorted { $0.daysAgo < $1.daysAgo }
    }

    /// Recent activity from people you actually follow.
    func recentActivities(limit: Int = 10) -> [FriendActivity] {
        activities
            .filter { friendIDs.contains($0.friendID) }
            .sorted { $0.daysAgo < $1.daysAgo }
            .prefix(limit)
            .map { $0 }
    }

    /// Find every friend whose activity references a place by the given name. Loose (normalized,
    /// case-insensitive) match on the place name, either direction.
    func friendsMatching(placeName: String, kind: FriendActivityKind? = nil) -> [Friend] {
        let normalizedTarget = placeName.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalizedTarget.isEmpty else { return [] }
        let matching = activities.filter { activity in
            guard friendIDs.contains(activity.friendID) else { return false }
            if let kind, activity.kind != kind { return false }
            let normalized = activity.placeName.lowercased().trimmingCharacters(in: .whitespaces)
            return normalized == normalizedTarget
        }
        let seen = Set(matching.map(\.friendID))
        return allPeople.filter { seen.contains($0.id) }
    }

    /// Places that at least `minFriends` of your friends have visited, ordered by friend count.
    func trendingPlaces(minFriends: Int = 2, limit: Int = 5) -> [FriendTrendingPlace] {
        let mine = activities.filter { $0.kind == .visited && friendIDs.contains($0.friendID) }
        let grouped = Dictionary(grouping: mine) { $0.placeName.lowercased() }
        let aggregated: [FriendTrendingPlace] = grouped.compactMap { _, group in
            let uniqueFriendIDs = Set(group.map(\.friendID))
            guard uniqueFriendIDs.count >= minFriends else { return nil }
            guard let first = group.first else { return nil }
            let matchedFriends = allPeople.filter { uniqueFriendIDs.contains($0.id) }
            return FriendTrendingPlace(
                placeName: first.placeName,
                category: first.category,
                neighborhood: first.neighborhood,
                friends: matchedFriends
            )
        }
        return aggregated
            .sorted { $0.friends.count > $1.friends.count }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Seed activity

    private static func makeSeed(
        alex: Friend, maya: Friend, sam: Friend, jordan: Friend,
        riley: Friend, nico: Friend, devon: Friend, priya: Friend
    ) -> [FriendActivity] {
        [
            FriendActivity(id: UUID(), friendID: alex.id, kind: .visited, placeName: "Joe's Pizza", category: .restaurant, neighborhood: "West Village", quote: "Never not perfect", tags: ["pizza", "late-night"], daysAgo: 2, rating: .loved),
            FriendActivity(id: UUID(), friendID: alex.id, kind: .visited, placeName: "Katz's Delicatessen", category: .restaurant, neighborhood: "LES", quote: "The pastrami is still the pastrami", tags: ["sandwich", "would-return"], daysAgo: 12, rating: .liked),
            FriendActivity(id: UUID(), friendID: alex.id, kind: .visited, placeName: "Via Carota", category: .restaurant, neighborhood: "West Village", quote: "Cacio e pepe hit exactly right", tags: ["italian", "date-night"], daysAgo: 20, rating: .loved),
            FriendActivity(id: UUID(), friendID: alex.id, kind: .wantToTry, placeName: "Superiority Burger", category: .restaurant, neighborhood: "East Village", quote: nil, tags: ["burgers"], daysAgo: 4, rating: nil),

            FriendActivity(id: UUID(), friendID: maya.id, kind: .visited, placeName: "Wildair", category: .restaurant, neighborhood: "LES", quote: "Natural wine list is unreal", tags: ["natural-wine", "small-plates"], daysAgo: 3, rating: .loved),
            FriendActivity(id: UUID(), friendID: maya.id, kind: .visited, placeName: "Katz's Delicatessen", category: .restaurant, neighborhood: "LES", quote: nil, tags: ["sandwich"], daysAgo: 30, rating: .liked),
            FriendActivity(id: UUID(), friendID: maya.id, kind: .visited, placeName: "Bar Six", category: .bar, neighborhood: "West Village", quote: "Late dinner + one more glass", tags: ["cocktails", "cozy"], daysAgo: 6, rating: .liked),
            FriendActivity(id: UUID(), friendID: maya.id, kind: .wantToTry, placeName: "Via Carota", category: .restaurant, neighborhood: "West Village", quote: nil, tags: ["italian"], daysAgo: 1, rating: nil),

            FriendActivity(id: UUID(), friendID: sam.id, kind: .visited, placeName: "Ippudo", category: .restaurant, neighborhood: "East Village", quote: "Broth deeper than expected", tags: ["ramen", "japanese"], daysAgo: 5, rating: .liked),
            FriendActivity(id: UUID(), friendID: sam.id, kind: .visited, placeName: "Totto Ramen", category: .restaurant, neighborhood: "Hell's Kitchen", quote: "Best chicken paitan in the city", tags: ["ramen"], daysAgo: 14, rating: .loved),
            FriendActivity(id: UUID(), friendID: sam.id, kind: .visited, placeName: "Xi'an Famous Foods", category: .restaurant, neighborhood: "East Village", quote: "Cumin lamb noodles, no notes", tags: ["chinese", "spicy"], daysAgo: 21, rating: .loved),
            FriendActivity(id: UUID(), friendID: sam.id, kind: .visited, placeName: "Joe's Pizza", category: .restaurant, neighborhood: "West Village", quote: nil, tags: ["pizza"], daysAgo: 9, rating: .liked),
            FriendActivity(id: UUID(), friendID: sam.id, kind: .wantToTry, placeName: "Nom Wah Tea Parlor", category: .restaurant, neighborhood: "Chinatown", quote: nil, tags: ["dumplings"], daysAgo: 7, rating: nil),

            FriendActivity(id: UUID(), friendID: jordan.id, kind: .visited, placeName: "Attaboy", category: .bar, neighborhood: "LES", quote: "No menu, all vibes", tags: ["cocktails", "late-night"], daysAgo: 1, rating: .loved),
            FriendActivity(id: UUID(), friendID: jordan.id, kind: .visited, placeName: "Employees Only", category: .bar, neighborhood: "West Village", quote: nil, tags: ["cocktails"], daysAgo: 11, rating: .liked),
            FriendActivity(id: UUID(), friendID: jordan.id, kind: .visited, placeName: "Roberta's", category: .restaurant, neighborhood: "Bushwick", quote: "Backyard slice + tinnies", tags: ["pizza", "outdoor"], daysAgo: 18, rating: .liked),
            FriendActivity(id: UUID(), friendID: jordan.id, kind: .visited, placeName: "Bar Six", category: .bar, neighborhood: "West Village", quote: nil, tags: ["cocktails", "cozy"], daysAgo: 22, rating: .liked),
            FriendActivity(id: UUID(), friendID: jordan.id, kind: .wantToTry, placeName: "Overstory", category: .bar, neighborhood: "FiDi", quote: nil, tags: ["cocktails", "view"], daysAgo: 3, rating: nil),

            FriendActivity(id: UUID(), friendID: riley.id, kind: .visited, placeName: "Devoción", category: .cafe, neighborhood: "Williamsburg", quote: "Airy sun-drenched morning", tags: ["coffee-shop", "work-friendly"], daysAgo: 2, rating: .loved),
            FriendActivity(id: UUID(), friendID: riley.id, kind: .visited, placeName: "Blue Bottle Coffee", category: .cafe, neighborhood: "Nolita", quote: nil, tags: ["coffee-shop"], daysAgo: 8, rating: .liked),
            FriendActivity(id: UUID(), friendID: riley.id, kind: .visited, placeName: "Levain Bakery", category: .bakery, neighborhood: "UWS", quote: "Chocolate chip walnut, warm", tags: ["dessert", "bakery"], daysAgo: 16, rating: .loved),
            FriendActivity(id: UUID(), friendID: riley.id, kind: .wantToTry, placeName: "Sey Coffee", category: .cafe, neighborhood: "Bushwick", quote: nil, tags: ["coffee-shop"], daysAgo: 5, rating: nil),

            FriendActivity(id: UUID(), friendID: nico.id, kind: .visited, placeName: "Lucali", category: .restaurant, neighborhood: "Carroll Gardens", quote: "Worth the two-hour wait", tags: ["pizza", "italian", "worth-the-wait"], daysAgo: 4, rating: .loved),
            FriendActivity(id: UUID(), friendID: nico.id, kind: .visited, placeName: "Via Carota", category: .restaurant, neighborhood: "West Village", quote: nil, tags: ["italian"], daysAgo: 24, rating: .liked),
            FriendActivity(id: UUID(), friendID: nico.id, kind: .visited, placeName: "Joe's Pizza", category: .restaurant, neighborhood: "West Village", quote: "A classic for a reason", tags: ["pizza"], daysAgo: 27, rating: .loved),

            FriendActivity(id: UUID(), friendID: devon.id, kind: .visited, placeName: "Overstory", category: .bar, neighborhood: "FiDi", quote: "Views for days", tags: ["cocktails", "view"], daysAgo: 6, rating: .loved),
            FriendActivity(id: UUID(), friendID: devon.id, kind: .visited, placeName: "Employees Only", category: .bar, neighborhood: "West Village", quote: nil, tags: ["cocktails"], daysAgo: 15, rating: .liked),
            FriendActivity(id: UUID(), friendID: devon.id, kind: .wantToTry, placeName: "Attaboy", category: .bar, neighborhood: "LES", quote: nil, tags: ["cocktails"], daysAgo: 2, rating: nil),

            FriendActivity(id: UUID(), friendID: priya.id, kind: .visited, placeName: "Nom Wah Tea Parlor", category: .restaurant, neighborhood: "Chinatown", quote: "The og soup dumpling spot", tags: ["dumplings"], daysAgo: 9, rating: .loved),
            FriendActivity(id: UUID(), friendID: priya.id, kind: .visited, placeName: "Xi'an Famous Foods", category: .restaurant, neighborhood: "East Village", quote: nil, tags: ["chinese", "spicy"], daysAgo: 19, rating: .liked),
            FriendActivity(id: UUID(), friendID: priya.id, kind: .wantToTry, placeName: "Ippudo", category: .restaurant, neighborhood: "East Village", quote: nil, tags: ["ramen"], daysAgo: 3, rating: nil)
        ]
    }
}
