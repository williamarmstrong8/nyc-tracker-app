import SwiftUI
import SwiftData

/// Two-level list view:
///   1. A grid of category cards (Restaurants, Bars, Cafes, Bakeries, Other) showing counts.
///   2. Tapping a card drills into the visits for that category.
/// The active `EntryFilter` still applies to both levels — so kind/tag filters carry through.
struct ListHome: View {
    @Binding var openedVisit: Visit?
    @Bindable var filter: EntryFilter
    @Binding var path: NavigationPath

    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Visit.visitedOn, order: .reverse)]) private var visits: [Visit]

    private var filteredVisits: [Visit] {
        visits.filter(filter.matches)
    }

    private var groupedByCategory: [PlaceCategory: [Visit]] {
        Dictionary(grouping: filteredVisits) { $0.place?.category ?? .other }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Room for the floating Map|List toggle + filter/search row above.
                    Color.clear.frame(height: 72)

                    if filteredVisits.isEmpty {
                        EmptyStateCard(filterActive: filter.isActive)
                            .padding(.top, 40)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(orderedCategories, id: \.self) { category in
                                NavigationLink(value: category) {
                                    CategoryCard(
                                        category: category,
                                        count: groupedByCategory[category]?.count ?? 0,
                                        previewVisits: groupedByCategory[category] ?? []
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Room for floating bottom nav
                    Color.clear.frame(height: 120)
                }
                .padding(.horizontal, 16)
            }
            .background(Color(uiColor: .systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: PlaceCategory.self) { category in
                CategoryVisitsList(
                    category: category,
                    visits: groupedByCategory[category] ?? [],
                    openedVisit: $openedVisit
                )
            }
        }
    }

    /// Show only categories that currently have entries, in a stable, sensible order.
    private var orderedCategories: [PlaceCategory] {
        PlaceCategory.allCases.filter { (groupedByCategory[$0]?.count ?? 0) > 0 }
    }
}

// MARK: - Category card

private struct CategoryCard: View {
    let category: PlaceCategory
    let count: Int
    let previewVisits: [Visit]

    private var previewPhoto: Photo? {
        previewVisits
            .flatMap { $0.photos }
            .sorted(by: { $0.order < $1.order })
            .first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.gradient.opacity(0.28))
                if let previewPhoto {
                    PhotoView(source: PhotoView.Source(photo: previewPhoto), contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(count) \(count == 1 ? "place" : "places")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground).opacity(0.5))
        )
    }

    private var label: String {
        switch category {
        case .restaurant: "Restaurants"
        case .bar:        "Bars"
        case .cafe:       "Cafes"
        case .bakery:     "Bakeries"
        case .other:      "Other"
        }
    }

    private var symbol: String {
        switch category {
        case .restaurant: "fork.knife"
        case .bar:        "wineglass.fill"
        case .cafe:       "cup.and.saucer.fill"
        case .bakery:     "birthday.cake.fill"
        case .other:      "mappin"
        }
    }

    private var tint: Color {
        switch category {
        case .restaurant: .orange
        case .bar:        .purple
        case .cafe:       .brown
        case .bakery:     .pink
        case .other:      .gray
        }
    }
}

// MARK: - Drilled-in category list

private struct CategoryVisitsList: View {
    let category: PlaceCategory
    let visits: [Visit]
    @Binding var openedVisit: Visit?

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if visits.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("Nothing here yet")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }

                ForEach(visits) { visit in
                    if let place = visit.place {
                        Button {
                            Haptics.tap()
                            openedVisit = visit
                        } label: {
                            ListRow(
                                place: place,
                                visit: visit,
                                thumbnail: visit.photos.sorted(by: { $0.order < $1.order }).first
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                delete(visit)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }

                Color.clear.frame(height: 120) // clear the floating bottom nav
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(categoryLabel)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var categoryLabel: String {
        switch category {
        case .restaurant: "Restaurants"
        case .bar:        "Bars"
        case .cafe:       "Cafes"
        case .bakery:     "Bakeries"
        case .other:      "Other"
        }
    }

    private func delete(_ visit: Visit) {
        Haptics.tap()
        VisitRepository(context: modelContext).delete(visit)
    }
}

// MARK: - Row

private struct ListRow: View {
    let place: Place
    let visit: Visit
    let thumbnail: Photo?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .frame(width: 64, height: 64)
                .overlay {
                    if let thumbnail {
                        PhotoView(source: PhotoView.Source(photo: thumbnail), contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else if visit.kind == .wantToTry {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.blue.opacity(0.8))
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(visit.title.isEmpty ? place.name : visit.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if visit.kind == .wantToTry {
                        Text("Want to try")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.blue.opacity(0.15)))
                    }
                }

                Text(place.neighborhood)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !visit.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(visit.tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground).opacity(0.4))
        )
    }
}

// MARK: - Empty state

private struct EmptyStateCard: View {
    let filterActive: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: filterActive ? "line.3.horizontal.decrease.circle" : "map")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(filterActive ? "No entries match this filter" : "Nothing here yet")
                .font(.headline)
            Text(filterActive ? "Try clearing filters." : "Tap the + button to log your first place.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
