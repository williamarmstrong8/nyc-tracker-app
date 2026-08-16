import SwiftUI
import MapKit
import CoreLocation

/// Manual venue entry with MapKit as-you-type autocomplete.
/// Used as an escape hatch from `VenuePickerView` when the AI's suggestions don't include the
/// place the user is looking for.
struct ManualVenueEntryView: View {
    let biasCoordinate: CLLocationCoordinate2D?
    let onSelect: (VenueCandidate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var completer = PlaceCompletionSearch()
    @State private var query: String = ""
    @State private var isResolving: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            Divider()

            List {
                if completer.results.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty, !isResolving {
                    Section {
                        Text("No matches. Try adding a neighborhood, e.g. \"Katz's Delicatessen Houston St\".")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(completer.results, id: \.self) { result in
                    Button {
                        Task { await pick(result) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title).font(.headline).foregroundStyle(.primary)
                            if !result.subtitle.isEmpty {
                                Text(result.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(isResolving)
                }
            }
            .listStyle(.plain)
            .overlay {
                if isResolving {
                    ProgressView("Finding place…")
                        .padding()
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .navigationTitle("Search a place")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            completer.setBias(biasCoordinate)
            focused = true
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("e.g. Katz's Delicatessen", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .submitLabel(.search)
                .onChange(of: query) { _, newValue in
                    completer.update(query: newValue)
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    completer.update(query: "")
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
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

    private func pick(_ completion: MKLocalSearchCompletion) async {
        Haptics.tap()
        isResolving = true
        defer { isResolving = false }
        if let candidate = await PlaceCompletionSearch.resolve(completion) {
            onSelect(candidate)
            // We were pushed via NavigationLink; the parent flow may swap its root content
            // entirely once onSelect advances the stage, which doesn't reliably pop this pushed
            // screen on its own. Pop explicitly so the write-up shows right away.
            dismiss()
        }
    }
}
