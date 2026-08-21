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
    /// Forwarded straight to `MapHome` — a venue tapped on the map can log a
    /// visit or save as want-to-try.
    var onLogVisit: (VenueCandidate) -> Void
    var onWantToTry: (VenueCandidate) -> Void

    @State private var isSearching = false
    @State private var searchQuery = ""
    @State private var includeAppleMapsSearch = false
    @State private var hasLocalSearchMatches = false
    @State private var showOtherLocationsPrompt = false
    @State private var listPath = NavigationPath()
    @FocusState private var isSearchFieldFocused: Bool
    @Namespace private var floatingControls

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
                        searchQuery: $searchQuery,
                        includeAppleMapsSearch: $includeAppleMapsSearch,
                        hasLocalSearchMatches: $hasLocalSearchMatches,
                        filter: filter,
                        onLogVisit: onLogVisit,
                        onWantToTry: onWantToTry
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
                GlassEffectContainer(spacing: 12) {
                    ZStack {
                        if isSearching {
                            HomeSearchBar(
                                text: $searchQuery,
                                isFocused: $isSearchFieldFocused
                            ) {
                                closeSearch()
                            }
                            .glassEffectID("search", in: floatingControls)
                            .padding(.horizontal, 16)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        } else {
                            HomeModeToggle(mode: $mode)
                                .glassEffectID("home-mode", in: floatingControls)

                            HStack {
                                FilterButton(filter: filter, showsAudience: mode == .map)
                                    .glassEffectID("filter", in: floatingControls)
                                Spacer()
                                SearchButton {
                                    Haptics.tap()
                                    withAnimation(.smooth(duration: 0.36)) {
                                        mode = .map
                                        isSearching = true
                                    }
                                }
                                .glassEffectID("search", in: floatingControls)
                            }
                            .padding(.horizontal, 16)
                            .transition(.opacity)
                        }
                    }
                }
                // Matches the vertical offset of the toolbar buttons on every
                // other tab (Explore/Friends/Profile), which sit inside a
                // compact inline nav bar right at the safe-area line rather
                // than 20pt below it.
                .padding(.top, 8)
                .transition(.opacity)

                if isSearching, showOtherLocationsPrompt, hasLocalSearchMatches, !includeAppleMapsSearch {
                    SearchOtherLocationsButton {
                        Haptics.tap()
                        isSearchFieldFocused = false
                        withAnimation(.smooth(duration: 0.32)) {
                            includeAppleMapsSearch = true
                            showOtherLocationsPrompt = false
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 68)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.default, value: showFloatingControls)
        .animation(.smooth(duration: 0.36), value: isSearching)
        .animation(.smooth(duration: 0.32), value: showOtherLocationsPrompt)
        .onChange(of: searchQuery) { _, _ in
            includeAppleMapsSearch = false
            showOtherLocationsPrompt = false
        }
        .task(id: otherLocationsPromptTaskID) {
            guard isSearching, hasLocalSearchMatches, !includeAppleMapsSearch else {
                showOtherLocationsPrompt = false
                return
            }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            showOtherLocationsPrompt = true
        }
    }

    private var otherLocationsPromptTaskID: String {
        "\(searchQuery)|\(hasLocalSearchMatches)|\(includeAppleMapsSearch)|\(isSearching)"
    }

    private func closeSearch() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isSearchFieldFocused = false
        }
        withAnimation(.smooth(duration: 0.36)) {
            isSearching = false
            searchQuery = ""
            includeAppleMapsSearch = false
            showOtherLocationsPrompt = false
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
                ForEach(VenueTag.allCases) { tag in
                    Button {
                        toggle(tag: tag.rawValue)
                    } label: {
                        Label(
                            tag.label,
                            systemImage: filter.tags.contains(tag.rawValue) ? "checkmark" : tag.symbol
                        )
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

// MARK: - Expanded search bar

private struct HomeSearchBar: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search your places", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .submitLabel(.search)

            Button {
                Haptics.tap()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .glassEffect(.regular.interactive(), in: .capsule)
        .onTapGesture { isFocused = true }
        .task { isFocused = true }
    }
}

// MARK: - Search other locations

private struct SearchOtherLocationsButton: View {
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Label("Search other locations", systemImage: "mappin.and.ellipse")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .accessibilityHint("Shows matching places from Apple Maps on the map")
    }
}
