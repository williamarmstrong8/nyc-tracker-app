import SwiftUI

/// Pick the tags for an entry. The same section on the new-entry screen, the
/// want-to-try sheet and both edit screens.
///
/// The eight curated options are on screen at once; anything else is typed in
/// below and stored the same way — kebab-case in `Visit.tags`.
struct VenueTagField: View {
    /// Raw tag values, kept in vocabulary order via `VenueTag.sorted`.
    @Binding var selection: [String]
    var title: String = "Tags"
    var hint: String? = "Optional — tap any that fit, or add your own."

    @State private var customDraft = ""
    @FocusState private var customFieldFocused: Bool

    /// Selected tags that aren't one of the eight curated options — custom tags
    /// the user typed, or legacy vocabulary from before the list shrank.
    private var customTags: [String] {
        selection.filter { VenueTag(rawValue: $0) == nil }
    }

    private var canAddCustom: Bool {
        guard let raw = VenueTag.normalize(customDraft) else { return false }
        return !selection.contains(raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 8) {
                ForEach(VenueTag.allCases) { tag in
                    chip(label: tag.label, symbol: tag.symbol, rawValue: tag.rawValue)
                }
                ForEach(customTags, id: \.self) { raw in
                    chip(label: VenueTag.label(forRawValue: raw), symbol: "tag", rawValue: raw)
                }
            }

            HStack(spacing: 8) {
                TextField("Add your own…", text: $customDraft)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .focused($customFieldFocused)
                    .submitLabel(.done)
                    .onSubmit { addCustomTag() }

                Button {
                    addCustomTag()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canAddCustom ? Color.accentColor : Color.secondary.opacity(0.35))
                .disabled(!canAddCustom)
                .accessibilityLabel("Add tag")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )

            if let hint, selection.isEmpty {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func chip(label: String, symbol: String, rawValue: String) -> some View {
        let isSelected = selection.contains(rawValue)
        return Button {
            toggle(rawValue)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                Text(label)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func toggle(_ rawValue: String) {
        Haptics.tap()
        var picked = Set(selection)
        if picked.contains(rawValue) {
            picked.remove(rawValue)
        } else {
            picked.insert(rawValue)
        }
        selection = VenueTag.sorted(Array(picked))
    }

    private func addCustomTag() {
        guard let raw = VenueTag.normalize(customDraft) else { return }
        guard !selection.contains(raw) else {
            customDraft = ""
            return
        }
        Haptics.tap()
        var picked = Set(selection)
        picked.insert(raw)
        selection = VenueTag.sorted(Array(picked))
        customDraft = ""
    }
}
