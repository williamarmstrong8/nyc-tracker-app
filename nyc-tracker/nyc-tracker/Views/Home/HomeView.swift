import SwiftUI
import MapKit

enum HomeMode: String, CaseIterable, Identifiable {
    case map
    case list
    var id: String { rawValue }
    var label: String { self == .map ? "Map" : "List" }
    var symbol: String { self == .map ? "map.fill" : "list.bullet" }
}

struct HomeView: View {
    let userID: UUID
    @Binding var mode: HomeMode
    @Binding var openedVisit: Visit?
    @Binding var focusVisitID: Visit.ID?
    @Bindable var filter: EntryFilter

    @State private var showSearch = false
    @State private var listPath = NavigationPath()
    @Namespace private var mapScope

    /// Hide the floating toggle/filter/search row once the list has drilled into a category —
    /// it would otherwise sit on top of that screen's title and back button.
    private var showFloatingControls: Bool {
        mode == .map || listPath.isEmpty
    }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                switch mode {
                case .map:
                    MapHome(
                        userID: userID,
                        openedVisit: $openedVisit,
                        focusVisitID: $focusVisitID,
                        filter: filter,
                        mapScope: mapScope
                    )
                    .ignoresSafeArea()
                case .list:
                    ListHome(userID: userID, openedVisit: $openedVisit, filter: filter, path: $listPath)
                }
            }

            // Unobtrusive, and only present when there is something to say —
            // pending uploads, a failure, or a legacy migration in progress.
            SyncStatusBar()
                // Clears the audience row too when the map is showing, which
                // adds a second row of floating controls above it.
                .padding(.top, showFloatingControls ? (mode == .map ? 126 : 80) : 20)
                .allowsHitTesting(true)

            if showFloatingControls {
                VStack(spacing: 10) {
                    ZStack {
                        HomeModeToggle(mode: $mode)
                        HStack {
                            FilterButton(filter: filter)
                            Spacer()
                            SearchButton { showSearch = true }
                        }
                        .padding(.horizontal, 16)
                    }

                    // Its own row rather than squeezed alongside the toggle: the
                    // label is variable-width (it can be a friend's name) and
                    // would push the centred toggle off-centre as it changed.
                    // Map only — the list is always the user's own entries.
                    if mode == .map {
                        HStack {
                            MapAudienceControl()
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 20)
                .transition(.opacity)
            }

            if mode == .map {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        MapUserLocationButton(scope: mapScope)
                            .buttonBorderShape(.circle)
                            .controlSize(.regular)
                        MapCompass(scope: mapScope)
                            .mapControlVisibility(.visible)
                    }
                }
                // Clear the toggle/filter/search row above (20pt top inset + 52pt row + gap)
                // so the user-location button doesn't sit on top of the search button.
                .padding(.top, 84)
                .padding(.trailing, 16)
            }
        }
        .animation(.default, value: showFloatingControls)
        .mapScope(mapScope)
        .sheet(isPresented: $showSearch) {
            SearchVisitsView(userID: userID, openedVisit: $openedVisit)
        }
    }
}

// MARK: - Toggle

struct HomeModeToggle: View {
    @Binding var mode: HomeMode
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HomeMode.allCases) { candidate in
                Button {
                    Haptics.tap()
                    withAnimation(.snappy) { mode = candidate }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: candidate.symbol)
                        Text(candidate.label)
                    }
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .frame(maxHeight: .infinity)
                    .foregroundStyle(mode == candidate ? Color.white : Color.secondary)
                    .background {
                        if mode == candidate {
                            Capsule()
                                .fill(Color.accentColor)
                                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 1)
                                .matchedGeometryEffect(id: "home-mode-thumb", in: selection)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == candidate ? [.isSelected] : [])
            }
        }
        .padding(4)
        .frame(height: 52)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View mode")
    }
}

// MARK: - Filter button

private struct FilterButton: View {
    @Bindable var filter: EntryFilter

    /// A curated list of tags to offer. In practice these are drawn from `VenueTag`, but presented
    /// as their raw values so they line up with what enrichment writes to `Visit.tags`.
    private let offeredTags: [String] = VenueTag.allCases.map(\.rawValue)

    var body: some View {
        Menu {
            Section("Kind") {
                ForEach(VisitKind.allCases) { kind in
                    Button {
                        toggle(kind: kind)
                    } label: {
                        Label(kind.label, systemImage: filter.kinds.contains(kind) ? "checkmark" : kind.symbol)
                    }
                }
            }
            Section("Category") {
                ForEach(PlaceCategory.allCases, id: \.self) { category in
                    Button {
                        toggle(category: category)
                    } label: {
                        Label(category.rawValue.capitalized, systemImage: filter.categories.contains(category) ? "checkmark" : "circle")
                    }
                }
            }
            Menu("Tags") {
                ForEach(offeredTags, id: \.self) { tag in
                    Button {
                        toggle(tag: tag)
                    } label: {
                        Label(tag, systemImage: filter.tags.contains(tag) ? "checkmark" : "tag")
                    }
                }
            }
            if filter.isActive {
                Section {
                    Button(role: .destructive) {
                        Haptics.tap()
                        filter.reset()
                    } label: {
                        Label("Clear filters", systemImage: "xmark.circle")
                    }
                }
            }
        } label: {
            Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .font(.subheadline.weight(.semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Filter entries")
    }

    private func toggle(kind: VisitKind) {
        Haptics.tap()
        if filter.kinds.contains(kind) { filter.kinds.remove(kind) } else { filter.kinds.insert(kind) }
    }
    private func toggle(category: PlaceCategory) {
        Haptics.tap()
        if filter.categories.contains(category) { filter.categories.remove(category) } else { filter.categories.insert(category) }
    }
    private func toggle(tag: String) {
        Haptics.tap()
        if filter.tags.contains(tag) { filter.tags.remove(tag) } else { filter.tags.insert(tag) }
    }
}

// MARK: - Search button

private struct SearchButton: View {
    var onTap: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            onTap()
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Search entries")
    }
}
