import SwiftUI
import SwiftData

/// Two-level list view:
///   1. A grid of category tiles (Restaurants, Bars, Cafes, Bakeries, Other) showing counts.
///   2. Tapping a tile drills into the visits for that category.
/// The active `EntryFilter` still applies to both levels — so kind/tag filters carry through.
///
/// Visual language matches Explore and Profile: the photo is the surface,
/// type sits next to or under it, and nothing is wrapped in a card fill.
struct ListHome: View {
    let userID: UUID
    @Binding var openedVisit: Visit?
    @Bindable var filter: EntryFilter
    @Binding var path: NavigationPath

    @Environment(\.modelContext) private var modelContext
    @Environment(SyncEngine.self) private var sync
    @Query private var visits: [Visit]

    init(
        userID: UUID,
        openedVisit: Binding<Visit?>,
        filter: EntryFilter,
        path: Binding<NavigationPath>
    ) {
        self.userID = userID
        _openedVisit = openedVisit
        self.filter = filter
        _path = path
        _visits = Query(
            filter: LocalStore.visitsPredicate(for: userID),
            sort: [
                SortDescriptor(\Visit.visitedOn, order: .reverse),
                // Upload order breaks a tie. A user backfilling several
                // places to the same day would otherwise get an order
                // SwiftData is free to change between launches.
                SortDescriptor(\Visit.createdAt, order: .reverse)
            ]
        )
    }

    private var filteredVisits: [Visit] {
        visits.filter(filter.matches)
    }

    private var groupedByCategory: [PlaceCategory: [Visit]] {
        Dictionary(grouping: filteredVisits) { $0.place?.category ?? .other }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    // Room for the floating Map|List toggle + filter/search row above.
                    Color.clear.frame(height: 72)

                    if filteredVisits.isEmpty {
                        EmptyStateCard(filterActive: filter.isActive)
                            .padding(.top, 40)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                            spacing: 22
                        ) {
                            ForEach(orderedCategories, id: \.self) { category in
                                NavigationLink(value: category) {
                                    CategoryTile(
                                        category: category,
                                        count: groupedByCategory[category]?.count ?? 0,
                                        previewVisits: groupedByCategory[category] ?? []
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 1)
            }
            .background(Color(uiColor: .systemBackground))
            // The manual sync trigger. Pushes anything queued first, then pulls —
            // so a user who suspects something didn't upload has one gesture that
            // both retries and re-checks, rather than two invisible ones.
            .refreshable { await sync.refreshNow() }
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

// MARK: - Category tile

/// Photo as the surface, name and count as type underneath — the Explore
/// feed card, shrunk to a two-column grid. No wrapping fill.
private struct CategoryTile: View {
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
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    if let previewPhoto {
                        PhotoView(source: PhotoView.Source(photo: previewPhoto, wantsThumbnail: true), contentMode: .fill)
                    } else {
                        ZStack {
                            tint.opacity(0.18)
                            Image(systemName: symbol)
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(tint)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(count) \(count == 1 ? "place" : "places")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
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
    @Environment(SyncEngine.self) private var sync

    private var listedVisits: [Visit] {
        visits.filter { $0.place != nil }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if listedVisits.isEmpty {
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

                ForEach(Array(listedVisits.enumerated()), id: \.element.id) { index, visit in
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

                        if index < listedVisits.count - 1 {
                            Divider().padding(.leading, 86)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
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
        VisitRepository(context: modelContext, userID: visit.ownerUserID).delete(visit)
        sync.requestSync(reason: .newLocalWrite)
    }
}

// MARK: - Row

private struct ListRow: View {
    let place: Place
    let visit: Visit
    let thumbnail: Photo?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            thumbnailView
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    if visit.kind == .wantToTry {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.blue, lineWidth: 2.5)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(visit.title.isEmpty ? place.name : visit.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !place.neighborhood.isEmpty {
                    Text(place.neighborhood)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !visit.tags.isEmpty {
                    Text(visit.tags.prefix(3).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityValue(visit.kind == .wantToTry ? "Want to try" : "")
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            PhotoView(source: PhotoView.Source(photo: thumbnail, wantsThumbnail: true), contentMode: .fill)
        } else {
            ZStack {
                Color(uiColor: .secondarySystemFill)
                Image(systemName: visit.kind == .wantToTry ? "bookmark" : "photo")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
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
