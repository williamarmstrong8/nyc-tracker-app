import Foundation

/// The eight things worth saying about a place.
///
/// Deliberately short. This was a ~50-case vocabulary covering cuisine, time of
/// day, setting and practicals, which made sense while a model was picking tags
/// off a transcript and nobody had to read the list. Now that the user taps them
/// by hand, the list has to fit on one screen and every option has to be worth a
/// tap — so it is one row of things you'd actually tell a friend, and nothing
/// that duplicates a field the entry already has (the category covers "cafe",
/// the date covers "brunch").
///
/// The raw values are what land in `Visit.tags` and in `visits.tags` upstream.
/// They stay kebab-case and lowercase: they are stored data, and rewording a
/// label should never orphan the entries already tagged with it.
enum VenueTag: String, CaseIterable, Identifiable, Sendable {
    case amazingAmbience = "amazing-ambience"
    case amazingFood     = "amazing-food"
    case amazingDrinks   = "amazing-drinks"
    case fastIshFood     = "fast-ish-food"
    case greatCoffee     = "great-coffee"
    case goodHealthy     = "good-healthy"
    case delishDessert   = "delish-dessert"
    case dateNight       = "date-night"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .amazingAmbience: "Amazing ambience"
        case .amazingFood:     "Amazing food"
        case .amazingDrinks:   "Amazing drinks"
        case .fastIshFood:     "Fast-ish food"
        case .greatCoffee:     "Great coffee"
        case .goodHealthy:     "Good healthy"
        case .delishDessert:   "Delish dessert"
        case .dateNight:       "Date night"
        }
    }

    var symbol: String {
        switch self {
        case .amazingAmbience: "sparkles"
        case .amazingFood:     "fork.knife"
        case .amazingDrinks:   "wineglass"
        case .fastIshFood:     "bolt"
        case .greatCoffee:     "cup.and.saucer"
        case .goodHealthy:     "leaf"
        case .delishDessert:   "birthday.cake"
        case .dateNight:       "heart"
        }
    }

    /// Turn free text into the kebab-case form stored in `Visit.tags`.
    ///
    /// Returns nil for blank input or strings with no letters or digits. Spaces
    /// and punctuation collapse to hyphens; the result is lowercased. Typing
    /// "Natural wine" lands as `natural-wine`, the same shape as the curated
    /// vocabulary uses.
    static func normalize(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        let raw = parts.joined(separator: "-")
        guard raw.count <= 40 else { return nil }
        return raw
    }

    /// How to display a tag string that came out of the database.
    ///
    /// Falls back to a de-kebabed version of the raw value rather than dropping
    /// it, because entries tagged under the old vocabulary are still on the map
    /// and a chip reading nothing is worse than one reading "natural wine".
    static func label(forRawValue raw: String) -> String {
        if let known = VenueTag(rawValue: raw) {
            return known.label
        }
        let words = raw.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Selected tags in vocabulary order, so a set of chips reads the same way
    /// every time regardless of the order they were tapped in.
    static func sorted(_ raw: [String]) -> [String] {
        let ranks = Dictionary(
            uniqueKeysWithValues: allCases.enumerated().map { ($0.element.rawValue, $0.offset) }
        )
        return raw.sorted { lhs, rhs in
            // Unknown (legacy) tags sort after the curated ones, then alphabetically.
            let l = ranks[lhs] ?? allCases.count
            let r = ranks[rhs] ?? allCases.count
            return l == r ? lhs < rhs : l < r
        }
    }
}
