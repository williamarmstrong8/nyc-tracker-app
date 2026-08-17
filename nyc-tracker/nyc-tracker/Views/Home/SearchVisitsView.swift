import SwiftUI
import SwiftData
import FoundationModels

/// Modal search over the user's logged visits. Live text-matching runs on every keystroke;
/// the "Ask AI" button re-ranks/filters the same set using FoundationModels when Apple
/// Intelligence is available. Tapping a result dismisses the sheet and opens the write-up.
struct SearchVisitsView: View {
    @Binding var openedVisit: Visit?

    @Environment(\.dismiss) private var dismiss
    @Query private var visits: [Visit]

    init(userID: UUID, openedVisit: Binding<Visit?>) {
        _openedVisit = openedVisit
        _visits = Query(
            filter: LocalStore.visitsPredicate(for: userID),
            sort: [SortDescriptor(\Visit.visitedOn, order: .reverse)]
        )
    }

    @State private var query: String = ""
    @State private var aiOrderedIDs: [UUID]?
    @State private var isAskingAI: Bool = false
    @State private var aiError: String?

    private let model = SystemLanguageModel.default

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !trimmedQuery.isEmpty && aiAvailable {
                        askAIRow
                        if let aiError {
                            Text(aiError)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 12)
                        }
                        if !displayResults.isEmpty {
                            Divider().padding(.leading, 86)
                        }
                    }

                    if displayResults.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(displayResults.enumerated()), id: \.element.id) { index, visit in
                            Button {
                                Haptics.tap()
                                openedVisit = visit
                                dismiss()
                            } label: {
                                SearchResultRow(
                                    visit: visit,
                                    tightTop: index == 0 && (trimmedQuery.isEmpty || !aiAvailable)
                                )
                            }
                            .buttonStyle(.plain)

                            if index < displayResults.count - 1 {
                                Divider().padding(.leading, 86)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .contentMargins(.top, 0, for: .scrollContent)
            .background(Color.black)
            .appSearchable(text: $query, prompt: "Name, tag, vibe, dish, description…")
            .onChange(of: query) { _, _ in
                aiOrderedIDs = nil
                aiError = nil
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var askAIRow: some View {
        Button {
            Task { await askAI() }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 64, height: 64)
                Text(isAskingAI ? "Thinking…" : "Ask AI to find the best match")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if isAskingAI {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAskingAI)
    }

    // MARK: - Filtering

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var aiAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    private var displayResults: [Visit] {
        if let aiOrderedIDs {
            let byID = Dictionary(uniqueKeysWithValues: visits.map { ($0.id, $0) })
            return aiOrderedIDs.compactMap { byID[$0] }
        }
        if trimmedQuery.isEmpty { return visits }
        return visits.filter { matches($0, query: trimmedQuery) }
    }

    private func matches(_ visit: Visit, query: String) -> Bool {
        let q = query.lowercased()
        if visit.title.lowercased().contains(q) { return true }
        if visit.enrichedDescription.lowercased().contains(q) { return true }
        if visit.transcript.lowercased().contains(q) { return true }
        if visit.topQuote.lowercased().contains(q) { return true }
        if visit.tags.contains(where: { $0.lowercased().contains(q) }) { return true }
        if let place = visit.place {
            if place.name.lowercased().contains(q) { return true }
            if place.neighborhood.lowercased().contains(q) { return true }
            if place.category.rawValue.lowercased().contains(q) { return true }
        }
        if let address = visit.address, address.lowercased().contains(q) { return true }
        return false
    }

    // MARK: - AI ranking

    /// Give the on-device model a compact catalog of the user's visits plus their natural-language
    /// query, and let it pick the best matches. Guided generation ensures we get integer indices back.
    private func askAI() async {
        guard aiAvailable, !trimmedQuery.isEmpty else { return }
        isAskingAI = true
        aiError = nil
        defer { isAskingAI = false }

        // Snapshot in case @Query updates mid-flight.
        let snapshot = Array(visits.prefix(80))
        let catalog = snapshot.enumerated().map { (idx, v) -> String in
            let name = v.place?.name.nonBlank ?? v.title.nonBlank ?? "Untitled"
            let neighborhood = v.place?.neighborhood ?? ""
            let category = v.place?.category.rawValue ?? ""
            let tags = v.tags.joined(separator: ", ")
            let desc = v.enrichedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(idx)] \(name) (\(category), \(neighborhood)) — tags: \(tags) — \(desc)"
        }.joined(separator: "\n")

        let prompt = """
        The user is searching their personal log of NYC restaurants, bars, and cafes. Their query:
        "\(trimmedQuery)"

        From the numbered entries below, return the indices of entries that plausibly match the query, \
        ordered from best to worst match. Only include an entry if it's a genuine match — not just a \
        loose word overlap. If nothing matches, return an empty list.

        Entries:
        \(catalog)
        """

        do {
            let instructions = Instructions(
                """
                You match natural-language search queries against a personal food log. \
                Return only indices from the provided list. Prefer semantic matches — vibes, cuisine, \
                dishes, occasion, verdict — over literal word overlap. Be strict: exclude entries that \
                don't genuinely match.
                """
            )
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(to: prompt, generating: AISearchResult.self)
            let ids = response.content.indices.compactMap { idx -> UUID? in
                guard idx >= 0 && idx < snapshot.count else { return nil }
                return snapshot[idx].id
            }
            aiOrderedIDs = ids
            if ids.isEmpty {
                aiError = "AI didn't find a match. Try a different phrasing."
            }
        } catch {
            aiError = "AI couldn't run right now."
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: trimmedQuery.isEmpty ? "magnifyingglass" : "questionmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text(trimmedQuery.isEmpty ? "Search your places" : "No matches")
                .font(.headline)
            Text(trimmedQuery.isEmpty
                 ? "Type a name, tag, vibe, or describe what you're in the mood for."
                 : "Try a different word, or tap Ask AI above.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

// MARK: - AI schema

@Generable
private struct AISearchResult {
    @Guide(description: "Indices of matching entries in best-to-worst order. Empty if nothing matches.", .maximumCount(20))
    var indices: [Int]
}

// MARK: - Row

private struct SearchResultRow: View {
    let visit: Visit
    var tightTop: Bool = false

    private var place: Place? { visit.place }
    private var thumbnail: Photo? {
        visit.photos.sorted(by: { $0.order < $1.order }).first
    }

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
                Text(visit.title.isEmpty ? (place?.name ?? "Untitled") : visit.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let neighborhood = place?.neighborhood, !neighborhood.isEmpty {
                    Text(neighborhood)
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
        .padding(.top, tightTop ? 2 : 12)
        .padding(.bottom, 12)
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

private extension String {
    var nonBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
