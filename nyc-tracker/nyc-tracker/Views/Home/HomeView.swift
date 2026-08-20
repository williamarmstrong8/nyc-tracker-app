import SwiftUI

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
                        filter: filter
                    )
                    .ignoresSafeArea()
                case .list:
                    ListHome(userID: userID, openedVisit: $openedVisit, filter: filter, path: $listPath)
                }
            }

            // Unobtrusive, and only present when there is something to say —
            // pending uploads, a failure, or a legacy migration in progress.
            SyncStatusBar()
                .padding(.top, showFloatingControls ? 68 : 20)
                .allowsHitTesting(true)

            if showFloatingControls {
                ZStack {
                    HomeModeToggle(mode: $mode)
                    HStack {
                        FilterButton(filter: filter, showsAudience: mode == .map)
                        Spacer()
                        SearchButton { showSearch = true }
                    }
                    .padding(.horizontal, 16)
                }
                // Matches the vertical offset of the toolbar buttons on every
                // other tab (Explore/Friends/Profile), which sit inside a
                // compact inline nav bar right at the safe-area line rather
                // than 20pt below it.
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .animation(.default, value: showFloatingControls)
        .sheet(isPresented: $showSearch) {
            SearchVisitsView(userID: userID, openedVisit: $openedVisit)
                .presentationBackground(Color(uiColor: .systemBackground))
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
    /// Audience belongs on the map only — the list is always the user's own entries.
    var showsAudience: Bool

    @Environment(MapAudienceStore.self) private var audience
    @Environment(SocialGraph.self) private var graph

    @State private var showAudiencePicker = false

    /// A curated list of tags to offer. In practice these are drawn from `VenueTag`, but presented
    /// as their raw values so they line up with what enrichment writes to `Visit.tags`.
    private let offeredTags: [String] = VenueTag.allCases.map(\.rawValue)

    private var isAudienceFiltered: Bool {
        showsAudience && audience.audience != .mine
    }

    private var isActive: Bool { filter.isActive || isAudienceFiltered }

    var body: some View {
        Menu {
            if showsAudience {
                Section("Show") {
                    Button {
                        Haptics.tap()
                        audience.select(.mine)
                    } label: {
                        Label("My places", systemImage: audience.audience == .mine ? "checkmark" : "person.fill")
                    }
                    Button {
                        Haptics.tap()
                        audience.select(.allFriends)
                    } label: {
                        Label("Friends", systemImage: audience.audience == .allFriends ? "checkmark" : "person.2.fill")
                    }
                    .disabled(graph.friends.isEmpty)
                    if !graph.friends.isEmpty {
                        Button {
                            Haptics.tap()
                            // Menu dismissal races a same-turn sheet present;
                            // hop a turn so the picker actually appears.
                            Task { @MainActor in
                                showAudiencePicker = true
                            }
                        } label: {
                            Label(oneFriendLabel, systemImage: isOneFriendSelected ? "checkmark" : "person.crop.circle")
                        }
                    }
                }
            }
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
            if isActive {
                Section {
                    Button(role: .destructive) {
                        Haptics.tap()
                        filter.reset()
                        if showsAudience { audience.select(.mine) }
                    } label: {
                        Label("Clear filters", systemImage: "xmark.circle")
                    }
                }
            }
        } label: {
            Image(systemName: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .font(.subheadline.weight(.semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Filter entries")
        .sheet(isPresented: $showAudiencePicker) {
            MapAudiencePicker()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var isOneFriendSelected: Bool {
        if case .friend = audience.audience { return true }
        return false
    }

    private var oneFriendLabel: String {
        if case .friend(let id) = audience.audience {
            return graph.friend(withID: id)?.person.shortName ?? "One friend"
        }
        return "One friend"
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
