import Foundation
import FoundationModels

// MARK: - Protocol

struct EnricherInput: Sendable {
    var nameHint: String?
    var addressHint: String?
    var venueName: String?
    var venueCategory: PlaceCategory?
    var tagHints: [String]
    var transcript: String
}

struct EnricherOutput: Sendable {
    var title: String
    var tags: [String]
    var enrichedDescription: String
    var topQuote: String
    var suggestedRating: Rating?
    var dish: String?
    var companions: String?
}

/// Protocol so the real on-device enricher (FoundationModels) can drop in without touching the UI.
/// The `FoundationModelsEnricher` implementation checks availability at call time and falls back to
/// the stub, so callers never need to handle availability themselves.
protocol EnricherProtocol: Sendable {
    func enrich(_ input: EnricherInput) async throws -> EnricherOutput
    /// Optionally warm up any underlying resources when we know the user is about to ask for enrichment.
    func prewarm() async
}

extension EnricherProtocol {
    func prewarm() async { }
}

// MARK: - Curated tag vocabulary

/// A closed set of tags the model must pick from. Kept as a `@Generable` enum so guided generation
/// enforces the vocabulary at decode time — the model literally cannot invent a new tag.
///
/// Cases are grouped by concept in the raw values so future callers can filter (e.g. only vibe
/// tags) without brittle string matching.
@Generable
enum VenueTag: String, CaseIterable, Sendable {
    // Overall vibe
    case cozy, lively, quiet, loud, romantic, casual, upscale, hiddenGem = "hidden-gem"
    // Occasion / who it's for
    case dateNight = "date-night", groupFriendly = "group-friendly", solo, workFriendly = "work-friendly", specialOccasion = "special-occasion"
    // Time of day
    case brunch, lunch, dinner, lateNight = "late-night", coffee, drinks
    // Food style
    case pizza, pasta, italian, sushi, seafood, steak, burgers, tacos, bbq, ramen, dumplings
    case bakery, dessert, breakfast, sandwich, mediterranean, korean, japanese, chinese, thai, indian
    case american, french, mexican
    // Drinks
    case cocktails, wine, naturalWine = "natural-wine", beer, coffeeShop = "coffee-shop"
    // Setting
    case outdoor, rooftop, view, spacious, tiny
    // Practicals
    case cashOnly = "cash-only", reservationsHard = "reservations-hard", walkInOnly = "walk-in-only", worthTheWait = "worth-the-wait", priceyButWorthIt = "pricey-but-worth-it"
    // Verdict
    case wouldReturn = "would-return", oneAndDone = "one-and-done"

    var label: String { rawValue }
}

// MARK: - Guided-generation schema

@Generable
struct VisitEnrichment {
    @Guide(description: "A short, evocative title (2-6 words). Prefer the venue name if given.")
    var title: String

    @Guide(description: "A calm, observant 2-3 sentence PARAPHRASE of what the transcript says — never a direct copy. Strip every filler word (um, uh, like, you know, I mean, kind of, sort of, so yeah). Rewrite in clean, complete sentences with a personal-journal tone. Only use facts the transcript states; do not invent details.")
    var enrichedDescription: String

    @Guide(description: "3-5 tags picked from the enum that best describe this visit.", .maximumCount(5))
    var tags: [VenueTag]

    @Guide(description: "A SINGLE short phrase lifted from the transcript — at most 10 words, with filler words removed. Just the sharpest highlight or complaint, never a full sentence, never the whole transcript. Empty string if nothing fits.")
    var topQuote: String

    @Guide(description: "The signature dish or drink mentioned. Leave empty if unclear.")
    var dish: String?

    @Guide(description: "Who the person was with, if the transcript says. Leave empty if unclear.")
    var companions: String?

    @Guide(description: "Overall feeling based on transcript tone.")
    var suggestedRating: SuggestedRating?
}

@Generable
enum SuggestedRating: String, Sendable {
    case loved, liked, fine, no

    var asRating: Rating {
        switch self {
        case .loved: .loved
        case .liked: .liked
        case .fine:  .fine
        case .no:    .no
        }
    }
}

// MARK: - Real enricher

/// Wraps a `LanguageModelSession` for a single enrichment call. Falls back to `StubEnricher` when
/// Apple Intelligence isn't available (e.g. simulator, older devices, model still downloading).
final class FoundationModelsEnricher: EnricherProtocol {
    private let fallback: EnricherProtocol
    private let model: SystemLanguageModel

    init(fallback: EnricherProtocol = StubEnricher()) {
        self.fallback = fallback
        self.model = SystemLanguageModel.default
    }

    func prewarm() async {
        guard case .available = model.availability else { return }
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        session.prewarm()
    }

    func enrich(_ input: EnricherInput) async throws -> EnricherOutput {
        guard case .available = model.availability else {
            return try await fallback.enrich(input)
        }
        do {
            let session = LanguageModelSession(model: model, instructions: Self.instructions)
            let response = try await session.respond(to: Self.prompt(for: input), generating: VisitEnrichment.self)
            let content = response.content

            let userTags = input.tagHints
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            let modelTags = content.tags.map(\.rawValue)
            let mergedTags = (modelTags + userTags).uniqued()

            let title: String = {
                if let venue = input.venueName?.trimmed.nonEmpty { return venue }
                if let modelTitle = content.title.trimmed.nonEmpty { return modelTitle }
                if let hint = input.nameHint?.trimmed.nonEmpty { return hint }
                return "New Spot"
            }()

            let description = TranscriptCleaner.polishDescription(
                content.enrichedDescription,
                transcript: input.transcript
            )

            return EnricherOutput(
                title: title,
                tags: mergedTags,
                enrichedDescription: description,
                topQuote: Self.trimQuote(content.topQuote, transcript: input.transcript),
                suggestedRating: content.suggestedRating?.asRating,
                dish: content.dish?.trimmed.nonEmpty,
                companions: content.companions?.trimmed.nonEmpty
            )
        } catch {
            // Any generation error → graceful fallback.
            return try await fallback.enrich(input)
        }
    }

    /// Safety-net for the top quote: if the model dumped too much text, clip to the first short
    /// phrase (or first ~12 words). We don't want the "quote" to be the whole transcript.
    private static func trimQuote(_ raw: String, transcript: String) -> String {
        let cleaned = raw.trimmed
        guard !cleaned.isEmpty else { return "" }
        let words = cleaned.split(whereSeparator: { $0.isWhitespace })
        if words.count <= 12 { return cleaned }
        // Look for the first natural break: sentence terminator or comma.
        let terminators: Set<Character> = [".", "!", "?", ",", ";"]
        if let breakIdx = cleaned.firstIndex(where: { terminators.contains($0) }) {
            let phrase = String(cleaned[..<breakIdx]).trimmed
            if !phrase.isEmpty { return phrase }
        }
        // Fall back to the first ~12 words.
        return words.prefix(12).joined(separator: " ") + "…"
    }

    // MARK: - Prompt building

    private static let instructions = Instructions(
        """
        You turn quick spoken voice notes about NYC restaurants, bars, and cafes into a short, \
        calm write-up for a personal food journal.

        Follow these rules exactly:

        • Do NOT parrot the transcript. REWRITE it in your own calm, observant voice. The \
          description must read like a journal entry, not a transcription.
        • REMOVE every filler word and false start: "um", "uh", "like", "you know", "I mean", \
          "kind of", "sort of", "so yeah", "what was it", "let me think", repeated words, \
          self-corrections such as "wait no", stray "and yeah" tail-offs.
        • Keep only substance: what was ordered, how it tasted, the vibe, service, who was \
          there, the verdict. Drop meta-commentary about the recording itself.
        • Use ONLY facts that appear in the transcript. Do not invent dishes, prices, decor, \
          companions, or opinions the user didn't express.
        • Tone: observant, honest, understated. No marketing copy, no effusive adjectives.
        • Length: 2-3 clean sentences. If the transcript is one line or nearly empty, keep the \
          description to one clean sentence. Never quote-wrap the description.
        • Write in complete sentences with proper capitalization and punctuation.
        • The top quote is at most 10 words — one short phrase from the transcript with fillers \
          stripped. Pick a single highlight or complaint. NEVER return the whole transcript. If \
          nothing fits, return an empty string.
        • Tags must be picked from the provided enum. Choose 3-5 that fit; do not force tags \
          the transcript doesn't support.
        • Prefer the given venue name (if provided) as the title over anything else.

        Example
        Transcript: "um so like we went to this pizza place, i think it was joe's, and yeah, \
        the slice was, uh, really good, super crispy, and we ate like three each. would \
        definitely come back."
        Description: "Joe's for a classic slice — crispy, exactly right, and we each put away \
        three. Easy call to come back."
        Top quote: "really good, super crispy"
        """
    )

    private static func prompt(for input: EnricherInput) -> String {
        var lines: [String] = []
        if let venue = input.venueName, !venue.isEmpty {
            lines.append("Venue: \(venue)")
        } else if let name = input.nameHint, !name.isEmpty {
            lines.append("Venue (user provided): \(name)")
        }
        if let category = input.venueCategory {
            lines.append("Category: \(category.rawValue)")
        }
        if let address = input.addressHint, !address.isEmpty {
            lines.append("Address: \(address)")
        }
        if !input.tagHints.isEmpty {
            lines.append("User hints (may or may not be in the tag vocabulary): \(input.tagHints.joined(separator: ", "))")
        }
        lines.append("")
        lines.append("Transcript:")
        lines.append(input.transcript.isEmpty ? "(no transcript captured)" : input.transcript)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Stub enricher

struct StubEnricher: EnricherProtocol {
    var artificialDelay: Duration = .milliseconds(600)

    func enrich(_ input: EnricherInput) async throws -> EnricherOutput {
        try? await Task.sleep(for: artificialDelay)

        let title = input.venueName?.trimmed.nonEmpty
            ?? input.nameHint?.trimmed.nonEmpty
            ?? "New Spot"
        let mockTags = [VenueTag.wouldReturn.rawValue, VenueTag.cozy.rawValue]
        let combinedTags = (mockTags + input.tagHints).uniqued()

        let cleanedBody: String = {
            let raw = input.transcript.trimmed
            if raw.isEmpty {
                return "A quick stop worth remembering. Bright room, good energy, easy to fall into a long conversation here."
            }
            return TranscriptCleaner.polishDescription(raw, transcript: raw)
        }()

        let quote = TranscriptCleaner.stripFillers(input.transcript.firstSentence() ?? "")

        return EnricherOutput(
            title: title,
            tags: combinedTags,
            enrichedDescription: cleanedBody,
            topQuote: quote,
            suggestedRating: nil,
            dish: nil,
            companions: nil
        )
    }
}

// MARK: - Transcript cleaning

/// Safety-net cleanup applied to whatever the enricher returns (or the raw transcript, in the
/// stub case). Removes common spoken-filler words and tightens punctuation so descriptions never
/// look like a raw transcription.
enum TranscriptCleaner {
    private static let fillerPatterns: [String] = [
        // Multi-word first so they match before their fragments.
        "you know", "i mean", "kind of", "sort of", "so yeah", "what was it",
        "let me think", "or something", "or whatever", "i guess",
        // Single-word fillers.
        "um", "uh", "erm", "hmm", "like", "basically", "literally", "actually",
        "just", "well", "so", "yeah", "okay", "ok", "right"
    ]

    /// Strip filler words from a fragment and normalize whitespace/punctuation.
    static func stripFillers(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        var s = trimmed
        for filler in fillerPatterns {
            // Case-insensitive whole-word match, tolerating a trailing comma.
            let escaped = NSRegularExpression.escapedPattern(for: filler)
            let pattern = "(?i)\\b\(escaped)\\b,?"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(s.startIndex..., in: s)
                s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
            }
        }

        // Collapse runs of whitespace, tidy stray spaces before punctuation and doubled commas.
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " ,", with: ",")
        s = s.replacingOccurrences(of: " \\.", with: ".", options: .regularExpression)
        s = s.replacingOccurrences(of: ",\\s*,+", with: ",", options: .regularExpression)
        s = s.replacingOccurrences(of: "^[,\\s]+", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Full description cleanup: strip fillers, fix capitalization, ensure terminal punctuation.
    /// If the model returned something that looks like a near-verbatim copy of the transcript,
    /// still apply filler removal so it doesn't ship as-is.
    static func polishDescription(_ raw: String, transcript: String) -> String {
        var s = stripFillers(raw)
        guard !s.isEmpty else { return s }

        // Capitalize the first character.
        s = s.prefix(1).uppercased() + s.dropFirst()

        // Ensure trailing sentence punctuation.
        if let last = s.last, !".!?".contains(last) {
            s += "."
        }
        return s
    }
}

// MARK: - String helpers

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var nonEmpty: String? { isEmpty ? nil : self }

    func firstSentence() -> String? {
        let trimmed = self.trimmed
        guard !trimmed.isEmpty else { return nil }
        let terminators: Set<Character> = [".", "!", "?"]
        var end = trimmed.startIndex
        for idx in trimmed.indices {
            end = idx
            if terminators.contains(trimmed[idx]) { break }
        }
        let sentence = String(trimmed[trimmed.startIndex...end]).trimmed
        return sentence.isEmpty ? nil : sentence
    }

    /// Very light polish: capitalize first letter, ensure trailing period.
    func polishedParagraph() -> String {
        var s = trimmed
        guard !s.isEmpty else { return s }
        s = s.prefix(1).uppercased() + s.dropFirst()
        if let last = s.last, !".!?".contains(last) {
            s += "."
        }
        return s
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
