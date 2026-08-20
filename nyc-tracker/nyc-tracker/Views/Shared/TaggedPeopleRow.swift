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
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    // MARK: - Avatars

    /// Overlapped by a third of their width, drawn first-on-top via `zIndex` so
    /// the stack reads left to right the same way the names do.
    private var avatarStack: some View {
        HStack(spacing: -Self.avatarSize / 3) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, person in
                PersonAvatar(person: person, size: Self.avatarSize)
                    .overlay {
                        Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1.5)
                    }
                    .zIndex(Double(shown.count - index))
            }

            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.avatarSize, height: Self.avatarSize)
                    .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
                    .overlay {
                        Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1.5)
                    }
            }
        }
    }

    private static let avatarSize: CGFloat = 22

    // MARK: - Names

    /// Names are tappable individually, which is why this is a run of views and
    /// not one interpolated `Text`: "with Maya and Dev" has two destinations in
    /// it, and a single string can only have one.
    @ViewBuilder
    private var label: some View {
        HStack(spacing: 0) {
            Text("with ")
                .font(font)
                .foregroundStyle(.secondary)

            ForEach(Array(named.enumerated()), id: \.offset) { index, person in
                nameText(person)
                if let separator = separator(at: index) {
                    Text(separator)
                        .font(font)
                        .foregroundStyle(.secondary)
                }
            }

            if overflowNames > 0 {
                Text(" and \(overflowNames) more")
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

    /// Two names spelled out, then a count. Three or more full names in a row
    /// wraps on a narrow phone and pushes the card's title down a line, which is
    /// worse than "and 2 more".
    private var named: [PersonSummary] { Array(people.prefix(2)) }
    private var overflowNames: Int { max(0, people.count - named.count) }

    private func separator(at index: Int) -> String? {
        // Only ever between two names, and only when nothing is being counted
        // after them — "Maya, Dev and 2 more" would double up on conjunctions.
        guard named.count == 2, index == 0 else { return nil }
        return overflowNames > 0 ? ", " : " and "
    }

    private func name(for person: PersonSummary) -> String {
        person.id == viewerID ? "you" : person.shortName
    }

    private var accessibilityLabel: String {
        let names = people.map { name(for: $0) }
        return "With " + ListFormatter.localizedString(byJoining: names)
    }
}
