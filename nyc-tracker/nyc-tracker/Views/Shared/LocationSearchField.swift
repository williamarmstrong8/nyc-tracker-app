import SwiftUI
import MapKit

/// Inline "where were you" search — as-you-type venue suggestions via
/// `MKLocalSearchCompleter`, shown as a floating list over the form instead of
/// pushing to a separate screen. Shared by the capture flow's `DetailsView` and
/// `WantToTryView`, so both surfaces resolve a typed venue name the same way.
///
/// Picking a suggestion resolves it to a full `VenueCandidate` and writes it to
/// `selectedVenue`, which callers use to skip photo-GPS resolution entirely and
/// trust the confirmed pick. Editing the text after a pick clears that selection
/// so the normal name-hint resolution path takes back over.
///
/// Focus is owned entirely inside this view — `@FocusState` can only drive a
/// `.focused` modifier on a view it's declared in, so there's no clean way to
/// share one enum-based `FocusState` between this and a parent's other fields.
/// A parent's keyboard-toolbar "Done" button should resign first responder
/// globally (`UIResponder.resignFirstResponder`) rather than reach into this
/// view's focus state.
struct LocationSearchField: View {
    @Binding var nameInput: String
    @Binding var addressInput: String
    @Binding var selectedVenue: VenueCandidate?

    @State private var completer = PlaceCompletionSearch()
    @State private var searchFieldHeight: CGFloat = 44
    @FocusState private var isFocused: Bool

    /// Capped at 5 — this list floats up over the form above the field, and a
    /// taller list would reach past the top of the scroll view and get clipped.
    private var visibleResults: [MKLocalSearchCompletion] {
        Array(completer.results.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Location")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            searchField
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear {
                                searchFieldHeight = geometry.size.height
                            }
                            .onChange(of: geometry.size.height) { _, newHeight in
                                searchFieldHeight = newHeight
                            }
                    }
                }
                .overlay(alignment: .bottom) {
                    if isFocused, !visibleResults.isEmpty {
                        resultsList
                            .fixedSize(horizontal: false, vertical: true)
                            .offset(y: -(searchFieldHeight + 8))
                            .zIndex(1)
                    }
                }
        }
    }

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleResults.enumerated()), id: \.offset) { index, result in
                Button {
                    Task { await select(result) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The text only fills as much of the row as it needs; without an
                    // explicit shape the empty space to its right isn't hit-testable
                    // and the row reads as "only the words are tappable".
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < visibleResults.count - 1 {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search for a place (optional)", text: $nameInput)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .submitLabel(.search)
                .onChange(of: nameInput) { _, newValue in
                    if let venue = selectedVenue, newValue != venue.name {
                        selectedVenue = nil
                    }
                    completer.update(query: newValue)
                }
            if !nameInput.isEmpty {
                Button {
                    nameInput = ""
                    addressInput = ""
                    selectedVenue = nil
                    completer.update(query: "")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private func select(_ completion: MKLocalSearchCompletion) async {
        Haptics.tap()
        guard let candidate = await PlaceCompletionSearch.resolve(completion) else { return }
        selectedVenue = candidate
        nameInput = candidate.name
        addressInput = candidate.address ?? addressInput
        completer.update(query: "")
        isFocused = false
    }
}
