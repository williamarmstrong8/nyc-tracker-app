import SwiftUI
import MapKit
import CoreLocation

/// Find a venue in Apple Maps and turn it into an entry.
///
/// The other two entry points start from something the user already has — a
/// batch of photos, or a name they type from memory — and work backwards to a
/// venue. This one starts from the venue. It is the right shape for the two
/// cases the app previously handled badly: somewhere you walked past and want to
/// remember, and somewhere you went but did not photograph.
///
/// Search is `MKLocalSearchCompleter` (as-you-type suggestions) resolved through
/// `MKLocalSearch` on tap, which is the same pair `ManualVenueEntryView` uses
/// from inside the capture flow. Resolving lazily — on tap rather than per
/// keystroke — is what keeps typing to one lightweight request instead of one
/// full search per character.
struct PlaceSearchView: View {
    /// Start the capture flow at this venue. Photos are still required, so the
    /// caller opens the picker first; this sheet only names the place.
    var onLogVisit: (VenueCandidate) -> Void
    /// Save the venue as a want-to-try immediately. Nothing else is needed —
    /// MapKit already supplied everything the entry holds.
    var onWantToTry: (VenueCandidate) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var completer = PlaceCompletionSearch()
    @State private var query = ""
    @State private var picked: VenueCandidate?
    @State private var resolvingID: String?
    @State private var resolutionFailed = false

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            List {
                if resolutionFailed {
                    Text("Couldn't load that place. Try another result.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if completer.results.isEmpty {
                    emptyRow
                } else {
                    ForEach(completer.results, id: \.self) { result in
                        resultRow(result)
                    }
                }

                dropPinRow
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Find a place")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Restaurant, bar, cafe…"
            )
            .onChange(of: query) { _, newValue in
                resolutionFailed = false
                completer.update(query: newValue)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationBackground(Color(uiColor: .systemBackground))
        .sheet(item: $picked) { candidate in
            PlaceActionSheet(
                candidate: candidate,
                onLogVisit: {
                    picked = nil
                    // Dismiss this sheet too: the caller's next move is to open
                    // the photo picker, and presenting it over two stacked
                    // sheets is how you get a picker nobody can dismiss.
                    dismiss()
                    onLogVisit(candidate)
                },
                onWantToTry: {
                    picked = nil
                    dismiss()
                    onWantToTry(candidate)
                }
            )
        }
        .task {
            // Bias results toward wherever the user actually is. Best-effort —
            // a denied location permission just means NYC-centred results, which
            // is the completer's default.
            completer.setBias(await LocationProvider.shared.currentLocation()?.coordinate)
        }
    }

    // MARK: - Rows

    private func resultRow(_ result: MKLocalSearchCompletion) -> some View {
        Button {
            Task { await resolve(result) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if resolvingID == identifier(for: result) {
                    ProgressView().controlSize(.small)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .disabled(resolvingID != nil)
    }

    /// Always present, not only on an empty result set. A food truck two doors
    /// down from a restaurant returns *results* — just not the right one — so
    /// hiding this behind "no matches" would hide it exactly when it is needed.
    private var dropPinRow: some View {
        NavigationLink {
            DropPinView(
                initialCoordinate: nil,
                initialName: trimmedQuery,
                // The action sheet presents on top of this screen; popping it in
                // the same turn would race that presentation. Whichever action
                // the user picks dismisses the whole search sheet anyway.
                dismissesOnDone: false
            ) { candidate in
                picked = candidate
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Can't find it? Drop a pin")
                        .font(.body.weight(.medium))
                    Text("For trucks, stalls and pop-ups Apple Maps doesn't list")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var emptyRow: some View {
        if trimmedQuery.isEmpty {
            promptState
        } else {
            Text("No matches. Adding a street or neighborhood usually helps — \u{201C}Lucali Carroll Gardens\u{201D} — or pin it by hand below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
    }

    private var promptState: some View {
        VStack(spacing: 10) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Search Apple Maps")
                .font(.headline)
            Text("Find somewhere you've been or want to go, then log it or save it for later.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .listRowSeparator(.hidden)
    }

    // MARK: - Resolution

    /// `MKLocalSearchCompletion` is a suggestion, not a place: it has no
    /// coordinate and no identifier. Turning one into something we can pin takes
    /// a second request, which is why this happens on tap.
    private func resolve(_ result: MKLocalSearchCompletion) async {
        Haptics.tap()
        resolutionFailed = false
        resolvingID = identifier(for: result)
        defer { resolvingID = nil }

        guard let candidate = await PlaceCompletionSearch.resolve(result) else {
            resolutionFailed = true
            return
        }
        picked = candidate
    }

    /// Completions carry no id of their own, and title alone collides across
    /// chains ("Joe's Coffee" three times). Title + subtitle is unique enough to
    /// track which row is spinning.
    private func identifier(for result: MKLocalSearchCompletion) -> String {
        "\(result.title)|\(result.subtitle)"
    }
}

// MARK: - Action sheet

/// The venue, then the two things you can do with it.
///
/// A sheet rather than a swipe action or a menu on the row, because the choice
/// deserves the address in front of it — "Prince Street Pizza" is four different
/// places and the user is picking one.
private struct PlaceActionSheet: View {
    let candidate: VenueCandidate
    var onLogVisit: () -> Void
    var onWantToTry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(tint.opacity(0.15)))

                Text(candidate.name)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                if let address = candidate.address, !address.isEmpty {
                    Text(address)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .padding(.top, 24)

            VStack(spacing: 10) {
                Button {
                    Haptics.tap()
                    onLogVisit()
                } label: {
                    Label("Log a visit", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glassProminent)

                Button {
                    Haptics.tap()
                    onWantToTry()
                } label: {
                    Label("Want to try", systemImage: "bookmark.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glass)

                Text("Logging a visit asks for photos next. Want to try saves it straight to the map.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(340)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: .systemBackground))
    }

    private var symbol: String {
        switch candidate.category {
        case .restaurant: "fork.knife"
        case .bar:        "wineglass.fill"
        case .cafe:       "cup.and.saucer.fill"
        case .bakery:     "birthday.cake.fill"
        case .other:      "mappin"
        }
    }

    private var tint: Color {
        switch candidate.category {
        case .restaurant: .orange
        case .bar:        .purple
        case .cafe:       .brown
        case .bakery:     .pink
        case .other:      .gray
        }
    }
}
