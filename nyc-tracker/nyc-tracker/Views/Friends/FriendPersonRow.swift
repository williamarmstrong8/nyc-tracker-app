import SwiftUI

/// Layout constants for `FriendPersonRow`. Kept outside the generic view —
/// Swift doesn't allow static stored properties on generic types.
enum FriendPersonRowMetrics {
    static let avatarSize: CGFloat = 56
    static let minHeight: CGFloat = 72
}

/// Shared people-list row for Friends, Requests, and Add.
///
/// One layout everywhere so avatar / type / row height stay locked together.
/// Bio is intentionally omitted — these lists are for identity + action, not
/// profile copy.
struct FriendPersonRow<Trailing: View>: View {
    let person: PersonSummary
    /// Replaces the @handle line when set (e.g. "Wants to be friends").
    var subtitle: String? = nil
    var showsPaletteRing: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    init(
        person: PersonSummary,
        subtitle: String? = nil,
        showsPaletteRing: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.person = person
        self.subtitle = subtitle
        self.showsPaletteRing = showsPaletteRing
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 14) {
            PersonAvatar(
                person: person,
                size: FriendPersonRowMetrics.avatarSize,
                showsPaletteRing: showsPaletteRing
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(person.bestName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(secondaryLine.isEmpty ? " " : secondaryLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .opacity(secondaryLine.isEmpty ? 0 : 1)
            }

            Spacer(minLength: 0)
            trailing()
        }
        .frame(minHeight: FriendPersonRowMetrics.minHeight)
        .padding(.vertical, 4)
    }

    private var secondaryLine: String {
        if let subtitle, !subtitle.isEmpty { return subtitle }
        return person.handle ?? ""
    }
}

extension FriendPersonRow where Trailing == EmptyView {
    init(
        person: PersonSummary,
        subtitle: String? = nil,
        showsPaletteRing: Bool = false
    ) {
        self.init(
            person: person,
            subtitle: subtitle,
            showsPaletteRing: showsPaletteRing
        ) {
            EmptyView()
        }
    }
}
