import SwiftUI

/// The wishlist, on the profile.
///
/// Two lists, not one: places still to go, and places that were on the list and
/// got visited. The second one is the point of the whole feature — someone
/// recommended somewhere, you went, and the app can show you that happened. An
/// item that silently disappears the moment it resolves never demonstrates that
/// the loop closed, and users read the disappearance as a bug.
struct WishlistSection: View {
    @Environment(WishlistStore.self) private var wishlist

    @State private var openedPlace: PlaceSummary?
    @State private var showResolved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !wishlist.hasLoaded && wishlist.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if wishlist.entries.isEmpty {
                emptyState
            } else {
                if wishlist.active.isEmpty {
                    Text("Nothing on the list right now.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(wishlist.active) { entry in
                        row(entry)
                    }
                }

                if !wishlist.resolved.isEmpty {
                    resolvedDisclosure
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .sheet(item: $openedPlace) { place in
            RecommendedPlaceSheet(place: place)
        }
        .task { wishlist.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bookmark.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Wishlist")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()

            // The map layer toggle lives here rather than only on the map: this
            // is where the user is thinking about the list, and it is the most
            // discoverable place to learn the pins exist at all.
            Text("On map")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Show wishlist on map", isOn: Binding(
                get: { wishlist.showsOnMap },
                set: { wishlist.setShowsOnMap($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)
        }
    }

    // MARK: - Rows

    private func row(_ entry: WishlistEntry) -> some View {
        Button {
            Haptics.tap()
            openedPlace = entry.place
        } label: {
            HStack(spacing: 12) {
                Image(systemName: categorySymbol(entry.place.category))
                    .font(.subheadline)
                    .foregroundStyle(categoryTint(entry.place.category))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(categoryTint(entry.place.category).opacity(0.15)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.place.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(caption(for: entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if !entry.recommenders.isEmpty {
                    HStack(spacing: -8) {
                        ForEach(entry.recommenders.prefix(3)) { recommender in
                            PersonAvatar(person: recommender.person, size: 24)
                                .overlay(
                                    Circle().stroke(
                                        Color(uiColor: .secondarySystemGroupedBackground),
                                        lineWidth: 2
                                    )
                                )
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Long-press, not swipe: this section lives in a `ScrollView` on the
        // profile, and `swipeActions` silently does nothing outside a `List`.
        .contextMenu {
            Button(role: .destructive) {
                Task { await wishlist.remove(itemID: entry.id) }
            } label: {
                Label("Remove from wishlist", systemImage: "bookmark.slash")
            }
        }
    }

    /// Who put it there, and when. Attribution first — the useful part of a
    /// recommendation is whose it was.
    private func caption(for entry: WishlistEntry) -> String {
        var parts: [String] = []

        if let attribution = entry.recommenders.attributionText {
            parts.append("\(attribution) recommended")
        } else if let neighborhood = entry.place.neighborhood, !neighborhood.isEmpty {
            parts.append(neighborhood)
        }

        if let created = entry.createdAt {
            parts.append(created.formatted(.relative(presentation: .named)))
        }

        return parts.isEmpty ? "Saved" : parts.joined(separator: " · ")
    }

    // MARK: - Resolved

    private var resolvedDisclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            Button {
                withAnimation(.snappy) { showResolved.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("Been there (\(wishlist.resolved.count))")
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(showResolved ? 0 : -90))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if showResolved {
                ForEach(wishlist.resolved) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.green.opacity(0.12)))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.place.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(resolvedCaption(entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func resolvedCaption(_ entry: WishlistEntry) -> String {
        let who = entry.recommenders.attributionText
        let when = entry.resolvedAt?.formatted(date: .abbreviated, time: .omitted)

        switch (who, when) {
        case let (who?, when?): return "\(who) recommended · went \(when)"
        case let (who?, nil):   return "\(who) recommended · you went"
        case let (nil, when?):  return "Went \(when)"
        default:                return "You've been"
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Nothing saved yet")
                .font(.subheadline.weight(.semibold))
            Text("Save places from a pin, or let friends send you somewhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func categorySymbol(_ category: PlaceCategory) -> String {
        switch category {
        case .restaurant: "fork.knife"
        case .bar:        "wineglass.fill"
        case .cafe:       "cup.and.saucer.fill"
        case .bakery:     "birthday.cake.fill"
        case .other:      "mappin"
        }
    }

    private func categoryTint(_ category: PlaceCategory) -> Color {
        switch category {
        case .restaurant: .orange
        case .bar:        .purple
        case .cafe:       .brown
        case .bakery:     .pink
        case .other:      .gray
        }
    }
}
