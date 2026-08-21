import SwiftUI

struct TagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color(uiColor: .secondarySystemBackground))
            )
    }
}

/// Read-only chips for the tags on an entry.
///
/// Takes raw `VenueTag` values — what the model and the database store — and
/// renders their labels, so "amazing-ambience" reads as "Amazing ambience"
/// everywhere without every call site remembering to convert.
struct TagChipRow: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(VenueTag.sorted(tags), id: \.self) { tag in
                TagChip(text: VenueTag.label(forRawValue: tag))
            }
        }
    }
}

/// Minimal wrapping HStack for chips.
///
/// SwiftUI has no built-in wrapping stack. A `LazyVGrid` with fixed columns
/// can't size to text, and a horizontal `ScrollView` hides overflow.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if lineWidth > 0 && lineWidth + size.width > maxWidth {
                totalHeight += lineHeight + spacing
                lineWidth = size.width + spacing
                lineHeight = size.height
            } else {
                lineWidth += size.width + spacing
                lineHeight = max(lineHeight, size.height)
            }
        }
        totalHeight += lineHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : lineWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
