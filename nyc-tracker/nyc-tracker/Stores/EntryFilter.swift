import Foundation
import Observation

/// Shared filter state for the Map + List views. A single instance is created in ContentView and
/// injected into HomeView; both MapHome and ListHome read from it.
@Observable
final class EntryFilter {
    /// Empty set means "all". Non-empty means "must match one of these".
    var categories: Set<PlaceCategory> = []
    var tags: Set<String> = []
    var kinds: Set<VisitKind> = []

    var isActive: Bool {
        !categories.isEmpty || !tags.isEmpty || !kinds.isEmpty
    }

    func matches(_ visit: Visit) -> Bool {
        if !kinds.isEmpty, !kinds.contains(visit.kind) { return false }
        if !categories.isEmpty {
            guard let category = visit.place?.category, categories.contains(category) else {
                return false
            }
        }
        if !tags.isEmpty {
            let visitTags = Set(visit.tags)
            if visitTags.isDisjoint(with: tags) { return false }
        }
        return true
    }

    /// Same rules against a friend's visit.
    ///
    /// A separate overload rather than a shared protocol: `Visit` is a SwiftData
    /// class whose category lives on a relationship, `FriendVisit` is a flat wire
    /// struct, and a protocol bridging them would exist solely to satisfy this
    /// one function. The rules are eight lines; the abstraction would be longer
    /// than the duplication.
    ///
    /// Applying the filter to friend pins as well is deliberate — a category or
    /// tag filter that silently only narrowed half the map would look broken.
    func matches(_ visit: FriendVisit) -> Bool {
        if !kinds.isEmpty, !kinds.contains(visit.visitKind) { return false }
        if !categories.isEmpty, !categories.contains(visit.category) { return false }
        if !tags.isEmpty, Set(visit.tags).isDisjoint(with: tags) { return false }
        return true
    }

    func reset() {
        categories.removeAll()
        tags.removeAll()
        kinds.removeAll()
    }
}
