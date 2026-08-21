import Foundation
import SwiftUI

/// "with Maya and Dev" — overlapping avatars followed by names.
///
/// One view for every surface that shows a tag set (feed card, write-up, place
/// sheet) so the truncation rule, the overlap and the copy cannot drift between
/// them. It renders nothing at all when nobody is tagged, so callers can place
/// it unconditionally instead of wrapping every use in an `if`.
struct TaggedPeopleRow: View {
    let people: [PersonSummary]
    /// How many avatars to draw before collapsing the rest into "+N". Names are
    /// summarised separately — see `label`.
    var maxAvatars: Int = 3
    var avatarSize: CGFloat = 30
    var font: Font = .subheadline
    /// The signed-in user, when known. Their name is replaced with "you", which
    /// is how a person refers to themselves in a sentence about themselves.
    var viewerID: UUID?
    /// Opens the tagged person's profile. Omitted where there is no navigation
    /// stack to push onto, in which case the row is inert text.
    var onSelect: ((PersonSummary) -> Void)?

    private var shown: [PersonSummary] { Array(people.prefix(maxAvatars)) }
    private var overflow: Int { max(0, people.count - shown.count) }

    var body: some View {
        if !people.isEmpty {
            HStack(spacing: 8) {
                avatarStack
                label
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    // MARK: - Avatars

    /// Overlapped by a third of their width, drawn first-on-top via `zIndex` so
    /// the stack reads left to right the same way the names do. The ring is the
    /// page background rather than a light or dark constant, so the overlap
    /// reads as a gap between faces in both appearances.
    private var avatarStack: some View {
        HStack(spacing: -avatarSize / 3) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, person in
                PersonAvatar(person: person, size: avatarSize)
                    .overlay { ring }
                    .zIndex(Double(shown.count - index))
            }

            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: avatarSize * 0.36, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: avatarSize, height: avatarSize)
                    .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
                    .overlay { ring }
            }
        }
    }

    private var ring: some View {
        Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 2)
    }

    // MARK: - Names

    /// Names come after the whole avatar stack, and as many are spelled out as
    /// the row is wide enough to hold: `ViewThatFits` walks from every name down
    /// to one name plus "+3 others", and settles on the last candidate when even
    /// that overflows. Measuring beats a fixed cut — the same two names fit on a
    /// write-up and not on a feed card sitting next to a save button.
    @ViewBuilder
    private var label: some View {
        ViewThatFits(in: .horizontal) {
            names(spellingOut: people.count)
            names(spellingOut: 3)
            names(spellingOut: 2)
            names(spellingOut: 1)
        }
    }

    /// Names are tappable individually, which is why this is a run of views and
    /// not one interpolated `Text`: "with Maya and Dev" has two destinations in
    /// it, and a single string can only have one.
    private func names(spellingOut limit: Int) -> some View {
        let spelled = Array(people.prefix(max(1, min(limit, people.count))))
        let rest = people.count - spelled.count

        return HStack(spacing: 0) {
            Text("with ")
                .font(font)
                .foregroundStyle(.secondary)

            ForEach(Array(spelled.enumerated()), id: \.element.id) { index, person in
                nameText(person)
                if let separator = separator(at: index, of: spelled.count, rest: rest) {
                    Text(separator)
                        .font(font)
                        .foregroundStyle(.secondary)
                }
            }

            if rest > 0 {
                Text(" +\(rest) \(rest == 1 ? "other" : "others")")
                    .font(font)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func nameText(_ person: PersonSummary) -> some View {
        let text = Text(name(for: person))
            .font(font.weight(.semibold))
            .foregroundStyle(.primary)

        if let onSelect {
            Button { onSelect(person) } label: { text }
                .buttonStyle(.plain)
        } else {
            text
        }
    }

    private func separator(at index: Int, of total: Int, rest: Int) -> String? {
        guard index < total - 1 else { return nil }
        // "Maya, Dev +2 others" — a conjunction before a name that isn't the
        // last one reads as if the list ended there.
        if rest == 0, index == total - 2 { return " and " }
        return ", "
    }

    private func name(for person: PersonSummary) -> String {
        person.id == viewerID ? "you" : person.shortName
    }

    private var accessibilityLabel: String {
        let names = people.map { name(for: $0) }
        return "With " + ListFormatter.localizedString(byJoining: names)
    }
}
