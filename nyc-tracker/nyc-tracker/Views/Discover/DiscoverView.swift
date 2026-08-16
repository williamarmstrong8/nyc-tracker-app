import SwiftUI
import SwiftData
import CoreLocation

/// Citywide "discover" feed — curated content beyond your own log and your friends' activity.
/// Each card can be added straight to your "want to try" list without leaving the page.
struct DiscoverView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var store = MockDiscoverStore.shared
    @Query private var places: [Place]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    header
                    section(title: "Trending this week", systemImage: "chart.line.uptrend.xyaxis", places: store.trending)
                    section(title: "New this month", systemImage: "sparkles", places: store.newOpenings)
                    section(title: "Editor's picks", systemImage: "star.fill", places: store.editorsPicks)
                    // Clear the floating bottom nav.
                    Color.clear.frame(height: 90)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Discover NYC")
                .font(.title3.weight(.semibold))
            Text("Curated spots beyond your own log and your friends' activity.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func section(title: String, systemImage: String, places sectionPlaces: [DiscoverPlace]) -> some View {
        Group {
            if !sectionPlaces.isEmpty {
                FriendsSectionCard(title: title, systemImage: systemImage) {
                    VStack(spacing: 12) {
                        ForEach(sectionPlaces) { place in
                            DiscoverPlaceCard(
                                place: place,
                                isAdded: isAlreadyAdded(place),
                                onAdd: { addToWantToTry(place) }
                            )
                        }
                    }
                }
            }
        }
    }

    /// Matched by normalized name, same loose logic `VisitRepository` uses elsewhere — good
    /// enough to avoid re-adding a place the user already has want-to-tried or visited.
    private func isAlreadyAdded(_ place: DiscoverPlace) -> Bool {
        let normalizedTarget = place.name.lowercased().trimmingCharacters(in: .whitespaces)
        return places.contains { $0.name.lowercased().trimmingCharacters(in: .whitespaces) == normalizedTarget }
    }

    private func addToWantToTry(_ discoverPlace: DiscoverPlace) {
        guard !isAlreadyAdded(discoverPlace) else { return }
        Haptics.tap()
        let place = Place(
            name: discoverPlace.name,
            category: discoverPlace.category,
            neighborhood: discoverPlace.neighborhood,
            lat: discoverPlace.coordinate.latitude,
            lng: discoverPlace.coordinate.longitude
        )
        let visit = Visit(
            title: discoverPlace.name,
            tags: discoverPlace.tags,
            enrichedDescription: discoverPlace.blurb,
            locationSource: .manual,
            kind: .wantToTry,
            place: place
        )
        VisitRepository(context: modelContext).insert(place: place, visit: visit, photos: [])
        Haptics.success()
    }
}

// MARK: - Card

private struct DiscoverPlaceCard: View {
    let place: DiscoverPlace
    let isAdded: Bool
    var onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.15))
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(place.neighborhood)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(place.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button {
                onAdd()
            } label: {
                Image(systemName: isAdded ? "checkmark" : "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(isAdded)
            .accessibilityLabel(isAdded ? "Already on your want to try list" : "Add to want to try")
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private var symbol: String {
        switch place.category {
        case .restaurant: "fork.knife"
        case .bar:        "wineglass.fill"
        case .cafe:       "cup.and.saucer.fill"
        case .bakery:     "birthday.cake.fill"
        case .other:      "mappin"
        }
    }

    private var tint: Color {
        switch place.category {
        case .restaurant: .orange
        case .bar:        .purple
        case .cafe:       .brown
        case .bakery:     .pink
        case .other:      .gray
        }
    }
}

#Preview {
    DiscoverView()
        .modelContainer(LocalStore.shared)
}
