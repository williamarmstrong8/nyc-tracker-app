import SwiftUI

/// Small labeled text field used by the capture, want-to-try, and settings
/// flows. Uses a plain VStack layout instead of a `Form` so tapping in
/// doesn't cause row-height jumps.
struct LabeledField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    /// Left `nil` to get a single-line field (the original behavior).
    /// Pass `.vertical` (with `lineLimit`) for a growable text block, e.g. a bio.
    var axis: Axis? = nil
    var lineLimit: ClosedRange<Int>? = nil
    var showsBackground: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            field
                .textFieldStyle(.plain)
                .padding(.horizontal, showsBackground ? 14 : 0)
                .padding(.vertical, showsBackground ? 12 : 4)
                .background {
                    if showsBackground {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    }
                }
        }
    }

    @ViewBuilder
    private var field: some View {
        if let axis {
            let base = TextField(placeholder, text: $text, axis: axis)
            if let lineLimit {
                base.lineLimit(lineLimit)
            } else {
                base
            }
        } else {
            TextField(placeholder, text: $text)
        }
    }
}
