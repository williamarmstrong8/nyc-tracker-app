import Foundation

/// Text matching for the map search bar — logged places only, by venue name.
enum VisitSearch {
    static func trimmed(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ group: MapPlaceGroup, query: String) -> Bool {
        group.name.localizedStandardContains(query)
    }
}
