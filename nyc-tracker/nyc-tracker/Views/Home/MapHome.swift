import SwiftUI
import SwiftData
import MapKit

struct MapHome: View {
    @Binding var openedVisit: Visit?
    /// Set from outside (e.g. "View on Map" in the write-up) to recenter the camera on a visit
    /// and open its callout. Cleared once handled.
    @Binding var focusVisitID: Visit.ID?
    @Bindable var filter: EntryFilter
    let mapScope: Namespace.ID

    @Query private var visits: [Visit]

    /// Commissioners' Plan of 1811: Manhattan avenues run ~29° east of true north.
    /// Heading the camera that way makes the "vertical" streets run up the screen.
    private static let manhattanGridHeading: Double = 29
    private static let nycCenter = CLLocationCoordinate2D(latitude: 40.7300, longitude: -73.9950)

    @State private var camera: MapCameraPosition = .camera(
        MapCamera(
            centerCoordinate: nycCenter,
            distance: 28_000,
            heading: manhattanGridHeading,
            pitch: 0
        )
    )

    @State private var selectedVisitID: Visit.ID?

    private var filteredVisits: [Visit] {
        visits.filter(filter.matches)
    }

    var body: some View {
        Map(position: $camera, selection: $selectedVisitID, scope: mapScope) {
            // Blue "you are here" dot + heading arrow.
            UserAnnotation()

            ForEach(filteredVisits) { visit in
                if let place = visit.place {
                    Marker(place.name, systemImage: markerSymbol(for: visit), coordinate: place.coordinate)
                        .tint(markerTint(for: visit))
                        .tag(visit.id)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        // HomeView renders its own compass + user-location button bound to `mapScope`; suppress
        // MapKit's automatic default controls so they don't double up with (and overlap) those.
        .mapControls {}
        .task {
            // Request When-In-Use permission the first time the map appears so the blue dot can show.
            _ = await LocationProvider.shared.currentLocation()
        }
        .safeAreaInset(edge: .top) {
            // Reserve room for the floating Map|List toggle so map controls don't collide.
            Color.clear.frame(height: 52)
        }
        .overlay(alignment: .bottom) {
            if let visit = selectedVisit, let place = visit.place {
                MapCalloutCard(place: place, visit: visit) {
                    openedVisit = visit
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 140) // clear the floating bottom nav
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: selectedVisitID)
        .task(id: focusVisitID) {
            guard let id = focusVisitID else { return }
            if let place = visits.first(where: { $0.id == id })?.place {
                withAnimation(.easeInOut(duration: 0.6)) {
                    camera = .camera(MapCamera(
                        centerCoordinate: place.coordinate,
                        distance: 900,
                        heading: Self.manhattanGridHeading,
                        pitch: 0
                    ))
                }
            }
            selectedVisitID = id
            focusVisitID = nil
        }
    }

    private var selectedVisit: Visit? {
        guard let id = selectedVisitID else { return nil }
        return filteredVisits.first(where: { $0.id == id })
    }

    private func markerSymbol(for visit: Visit) -> String {
        if visit.kind == .wantToTry { return "bookmark.fill" }
        return categorySymbol(for: visit.place?.category ?? .other)
    }

    private func markerTint(for visit: Visit) -> Color {
        if visit.kind == .wantToTry { return .blue }
        return categoryTint(for: visit.place?.category ?? .other)
    }

    private func categorySymbol(for category: PlaceCategory) -> String {
        switch category {
        case .restaurant: "fork.knife"
        case .bar:        "wineglass.fill"
        case .cafe:       "cup.and.saucer.fill"
        case .bakery:     "birthday.cake.fill"
        case .other:      "mappin"
        }
    }

    private func categoryTint(for category: PlaceCategory) -> Color {
        switch category {
        case .restaurant: .orange
        case .bar:        .purple
        case .cafe:       .brown
        case .bakery:     .pink
        case .other:      .gray
        }
    }
}

// MARK: - Callout

private struct MapCalloutCard: View {
    let place: Place
    let visit: Visit
    var onOpen: () -> Void

    private var firstPhoto: Photo? {
        visit.photos.sorted(by: { $0.order < $1.order }).first
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 12) {
                thumbnail
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(visit.title.isEmpty ? place.name : visit.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if visit.kind == .wantToTry {
                            Image(systemName: "bookmark.fill")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }

                    Text(visit.address ?? place.neighborhood)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if !visit.tags.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(visit.tags.prefix(3), id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                            }
                        }
                        .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.glass)
        .accessibilityHint("Opens the write-up")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let photo = firstPhoto {
            PhotoView(source: PhotoView.Source(photo: photo), contentMode: .fill)
        } else {
            ZStack {
                Color(uiColor: .tertiarySystemFill)
                Image(systemName: visit.kind == .wantToTry ? "bookmark.fill" : categoryFallbackSymbol)
                    .font(.title3)
                    .foregroundStyle(visit.kind == .wantToTry ? .blue : Color.secondary)
            }
        }
    }

    private var categoryFallbackSymbol: String {
        switch place.category {
        case .restaurant: "fork.knife"
        case .bar:        "wineglass"
        case .cafe:       "cup.and.saucer"
        case .bakery:     "birthday.cake"
        case .other:      "mappin"
        }
    }
}
