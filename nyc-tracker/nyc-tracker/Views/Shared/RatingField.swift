import SwiftUI

/// Did you like it — two cards, because there are exactly two answers.
///
/// A segmented control would be smaller, but this is the one judgement the entry
/// records and it earns the space. Tapping the selected card clears it: the
/// verdict is optional, and with only two options there is nowhere else for the
/// selection to go.
struct RatingField: View {
    @Binding var rating: Rating?
    var title: String = "Verdict"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                card(.liked)
                card(.notLiked)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func card(_ value: Rating) -> some View {
        let isSelected = rating == value
        return Button {
            Haptics.tap()
            rating = isSelected ? nil : value
        } label: {
            VStack(spacing: 8) {
                Image(systemName: value.symbol)
                    .font(.title3)
                Text(value.label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 88)
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        isSelected
                            ? AnyShapeStyle(tint(value))
                            : AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Green and red rather than the accent color for both: the two cards sit
    /// side by side and the fill is the fastest way to read which one is on.
    private func tint(_ value: Rating) -> Color {
        switch value {
        case .liked:    .green
        case .notLiked: .red
        }
    }
}
