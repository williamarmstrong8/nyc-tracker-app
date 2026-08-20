import SwiftUI
import MapKit
import CoreLocation

/// Rich venue picker used by both the capture flow (`CaptureFlowView`) and the "want to try"
/// flow (`WantToTryView`).
///
/// Shows the top 3 candidates + a "search manually" fallback. Tapping any candidate immediately
/// invokes `onSelect`; the caller advances to its own confirm/edit screen.
///
/// The caller owns the NavigationStack context. Present this view inside a `NavigationStack` (a
/// `.sheet` wrapper works well).
struct VenuePickerView: View {
    let candidates: [VenueCandidate]
    let biasCoordinate: CLLocationCoordinate2D?
    /// What the user typed as the name, if anything. Pre-fills the pin-drop
    /// screen so they don't type it twice.
    var typedName: String? = nil
    /// Called with the confirmed candidate (or nil to explicitly keep the user's typed name).
    let onSelect: (VenueCandidate?) -> Void

    private var topCandidates: [VenueCandidate] {
        Array(candidates.prefix(3))
    }

    var body: some View {
        List {
            Section {
                ForEach(topCandidates) { candidate in
                    Button {
                        Haptics.tap()
                        onSelect(candidate)
                    } label: {
                        VenueRow(candidate: candidate, biasCoordinate: biasCoordinate)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                if !topCandidates.isEmpty {
                    Text("Suggested nearby")
                }
            } footer: {
                if topCandidates.isEmpty {
                    Text("No matches found. Search for the place manually below.")
                }
            }

            Section {
                NavigationLink {
                    ManualVenueEntryView(biasCoordinate: biasCoordinate) { candidate in
                        onSelect(candidate)
                    }
                } label: {
                    Label("Search for a different place", systemImage: "magnifyingglass")
                }
                NavigationLink {
                    DropPinView(
                        initialCoordinate: biasCoordinate,
                        initialName: typedName ?? ""
                    ) { candidate in
                        onSelect(candidate)
                    }
                } label: {
                    Label("Drop a pin on the map", systemImage: "mappin.and.ellipse")
                }
                Button {
                    Haptics.tap()
                    onSelect(nil)
                } label: {
                    Label("None of these — keep my name", systemImage: "square.and.pencil")
                }
            } footer: {
                // Named rather than left to be discovered: this is the only path
                // for a venue MapKit does not have, and "search harder" is the
                // wrong advice for a food truck.
                Text("Somewhere that isn't on the map — a truck, a stall, a pop-up — can be pinned by hand.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Confirm the place")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Row

private struct VenueRow: View {
    let candidate: VenueCandidate
    let biasCoordinate: CLLocationCoordinate2D?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: categorySymbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(Circle().fill(tint.opacity(0.15)))

            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.name).font(.headline).foregroundStyle(.primary)
                if let address = candidate.address {
                    Text(address).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(categoryLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    if let dist = distanceString {
                        Text("•").foregroundStyle(.tertiary)
                        Text(dist).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var distanceString: String? {
        guard let bias = biasCoordinate else { return nil }
        let a = CLLocation(latitude: bias.latitude, longitude: bias.longitude)
        let b = CLLocation(latitude: candidate.coordinate.latitude, longitude: candidate.coordinate.longitude)
        let meters = a.distance(from: b)
        if meters < 1000 { return "\(Int(meters)) m" }
        return String(format: "%.1f km", meters / 1000)
    }

    private var categoryLabel: String {
        candidate.category.rawValue.prefix(1).uppercased() + candidate.category.rawValue.dropFirst()
    }

    private var categorySymbol: String {
        switch candidate.category {
        case .restaurant: "fork.knife"
        case .bar:        "wineglass"
        case .cafe:       "cup.and.saucer"
        case .bakery:     "birthday.cake"
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
