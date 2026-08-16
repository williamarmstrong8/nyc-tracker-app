import SwiftUI
import SwiftData
import Charts

/// Stats dashboard over the user's logged visits. The stats are still derived from the local
/// SwiftData rows — this task added auth, not sync — but the identity at the top is now the real
/// signed-in profile rather than a mock.
struct ProfileView: View {
    @Query(sort: [SortDescriptor(\Visit.visitedOn, order: .reverse)]) private var visits: [Visit]
    @Environment(AuthManager.self) private var auth

    @State private var showSettings = false

    private var profile: Profile? { auth.state.profile }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    identityHeader
                    heroStatCard
                    if stats.totalVisited == 0 && stats.totalWantToTry == 0 {
                        emptyState
                    } else {
                        overviewGrid
                        categoriesSection
                        cadenceSection
                        topNeighborhoodsSection
                        topTagsSection
                        ratingsSection
                        milestonesSection
                    }
                    signInFooter
                    // Clear the floating bottom nav.
                    Color.clear.frame(height: 90)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.tap()
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    // MARK: - Derived stats

    private var stats: VisitStats { VisitStats(visits: visits) }

    // MARK: - Sections

    private var identityHeader: some View {
        HStack(spacing: 16) {
            avatar
                .frame(width: 68, height: 68)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 3))
                .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile?.bestName ?? "—")
                    .font(.title3.weight(.semibold))
                Text(profile?.handle ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let firstDate = stats.firstVisitedOn {
                    Text("Tracking since \(firstDate.formatted(.dateTime.month(.abbreviated).year()))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("No visits yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// Uploaded avatar when there is one, app logo as the fallback (also used
    /// while the remote image loads, so the header never jumps).
    @ViewBuilder
    private var avatar: some View {
        if let urlString = profile?.avatarURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image("Logo").resizable().scaledToFill()
            }
        } else {
            Image("Logo").resizable().scaledToFill()
        }
    }

    /// One hero number, front and center — the single stat someone opening their profile cares
    /// about most before drilling into the breakdowns below.
    private var heroStatCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                Text("Total places logged")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(.white.opacity(0.9))

            Text("\(stats.uniquePlaces)")
                .font(.system(size: 60, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()

            Text(heroCaption)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        )
    }

    private var heroCaption: String {
        guard stats.totalVisited > 0 else { return "Nothing logged yet — go eat something." }
        return "\(stats.totalVisited) visits across \(stats.uniquePlaces) unique spots"
    }

    private var overviewGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            StatCard(
                title: "Visited",
                value: "\(stats.totalVisited)",
                caption: "unique places: \(stats.uniquePlaces)",
                symbol: "checkmark.seal.fill",
                tint: .green
            )
            StatCard(
                title: "Want to try",
                value: "\(stats.totalWantToTry)",
                caption: stats.totalWantToTry == 0 ? "add a bookmark" : "on your list",
                symbol: "bookmark.fill",
                tint: .blue
            )
            StatCard(
                title: "This month",
                value: "\(stats.thisMonthCount)",
                caption: monthCaption,
                symbol: "calendar",
                tint: .orange
            )
            StatCard(
                title: "Photos",
                value: "\(stats.totalPhotos)",
                caption: String(format: "%.1f per visit", stats.averagePhotosPerVisit),
                symbol: "photo.on.rectangle",
                tint: .purple
            )
        }
    }

    private var monthCaption: String {
        let delta = stats.thisMonthCount - stats.lastMonthCount
        if delta > 0 { return "+\(delta) vs last month" }
        if delta < 0 { return "\(delta) vs last month" }
        return "same as last month"
    }

    private var categoriesSection: some View {
        SectionCard(title: "By category", systemImage: "chart.pie.fill") {
            VStack(spacing: 12) {
                ForEach(stats.categoryBreakdown, id: \.category) { row in
                    CategoryBar(
                        label: row.category.rawValue.capitalized,
                        count: row.count,
                        total: max(stats.totalVisited, 1),
                        tint: categoryTint(for: row.category),
                        symbol: categorySymbol(for: row.category)
                    )
                }
                if stats.categoryBreakdown.isEmpty {
                    subtleEmpty("No visits yet")
                }
            }
        }
    }

    private var cadenceSection: some View {
        SectionCard(title: "Last 12 months", systemImage: "chart.bar.fill") {
            Chart(stats.monthlyCadence) { bucket in
                BarMark(
                    x: .value("Month", bucket.date, unit: .month),
                    y: .value("Visits", bucket.count)
                )
                .cornerRadius(4)
                .foregroundStyle(Color.accentColor.gradient)
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month, count: 2)) { value in
                    AxisValueLabel(format: .dateTime.month(.narrow))
                }
            }
            .frame(height: 140)
        }
    }

    private var topNeighborhoodsSection: some View {
        SectionCard(title: "Top neighborhoods", systemImage: "map.fill") {
            VStack(spacing: 8) {
                if stats.topNeighborhoods.isEmpty {
                    subtleEmpty("No neighborhoods yet")
                } else {
                    ForEach(stats.topNeighborhoods, id: \.name) { row in
                        LeaderboardRow(rank: row.rank, name: row.name, count: row.count)
                    }
                }
            }
        }
    }

    private var topTagsSection: some View {
        SectionCard(title: "Most-used tags", systemImage: "tag.fill") {
            if stats.topTags.isEmpty {
                subtleEmpty("No tags yet")
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(stats.topTags, id: \.tag) { row in
                        TagCountChip(tag: row.tag, count: row.count)
                    }
                }
            }
        }
    }

    private var ratingsSection: some View {
        SectionCard(title: "Ratings", systemImage: "heart.fill") {
            VStack(spacing: 8) {
                if stats.ratingBreakdown.allSatisfy({ $0.count == 0 }) {
                    subtleEmpty("No ratings yet")
                } else {
                    ForEach(stats.ratingBreakdown, id: \.rating) { row in
                        RatingBar(
                            rating: row.rating,
                            count: row.count,
                            total: max(stats.ratedCount, 1)
                        )
                    }
                    if stats.wouldReturnPercent != nil {
                        Divider().padding(.vertical, 4)
                        HStack {
                            Label("Would return", systemImage: "arrow.uturn.forward")
                                .font(.subheadline)
                            Spacer()
                            Text("\(stats.wouldReturnPercent ?? 0)%")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
    }

    private var milestonesSection: some View {
        SectionCard(title: "Milestones", systemImage: "sparkles") {
            VStack(spacing: 10) {
                MilestoneRow(
                    icon: "clock.arrow.circlepath",
                    label: "Days tracking",
                    value: stats.daysTracking.map(String.init) ?? "—"
                )
                MilestoneRow(
                    icon: "flame.fill",
                    label: "Active weeks (last 12)",
                    value: "\(stats.activeWeeksLast12)"
                )
                MilestoneRow(
                    icon: "camera.fill",
                    label: "Visits with photos",
                    value: "\(stats.visitsWithPhotos)"
                )
                MilestoneRow(
                    icon: "waveform",
                    label: "Voice notes",
                    value: "\(stats.visitsWithAudio)"
                )
                if let mostRecent = stats.mostRecentVisit {
                    MilestoneRow(
                        icon: "mappin.circle.fill",
                        label: "Latest",
                        value: mostRecent.formatted(.relative(presentation: .named))
                    )
                }
            }
        }
    }

    /// The old "Sign in to sync" placeholder is gone — you can't reach this screen
    /// without a session any more. What's left is the honest status: the account
    /// exists, but visits still live only on this device until the sync layer lands.
    private var signInFooter: some View {
        VStack(spacing: 8) {
            Label("Signed in", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Text("Your places are stored on this device. Syncing and publishing arrive in a future update.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("No stats yet")
                .font(.headline)
            Text("Log a place to start seeing patterns here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func subtleEmpty(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Style helpers

    private func categoryTint(for category: PlaceCategory) -> Color {
        switch category {
        case .restaurant: .orange
        case .bar:        .purple
        case .cafe:       .brown
        case .bakery:     .pink
        case .other:      .gray
        }
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
}

// MARK: - Stats model

/// Pure derivation over `[Visit]`. Recomputed each time SwiftData yields a fresh snapshot.
private struct VisitStats {
    let visits: [Visit]

    var visited: [Visit] { visits.filter { $0.kind == .visited } }
    var wantToTry: [Visit] { visits.filter { $0.kind == .wantToTry } }

    var totalVisited: Int { visited.count }
    var totalWantToTry: Int { wantToTry.count }
    var totalPhotos: Int { visited.reduce(0) { $0 + $1.photos.count } }
    var averagePhotosPerVisit: Double {
        guard totalVisited > 0 else { return 0 }
        return Double(totalPhotos) / Double(totalVisited)
    }
    var uniquePlaces: Int {
        Set(visited.compactMap { $0.place?.id }).count
    }
    var visitsWithPhotos: Int { visited.filter { !$0.photos.isEmpty }.count }
    var visitsWithAudio: Int { visited.filter { $0.audioRelativePath != nil }.count }

    var firstVisitedOn: Date? { visited.map(\.visitedOn).min() }
    var mostRecentVisit: Date? { visited.map(\.visitedOn).max() }
    var daysTracking: Int? {
        guard let first = firstVisitedOn else { return nil }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: first), to: Date()).day
    }

    var thisMonthCount: Int {
        let cal = Calendar.current
        let now = Date()
        return visited.filter { cal.isDate($0.visitedOn, equalTo: now, toGranularity: .month) }.count
    }
    var lastMonthCount: Int {
        let cal = Calendar.current
        guard let lastMonth = cal.date(byAdding: .month, value: -1, to: Date()) else { return 0 }
        return visited.filter { cal.isDate($0.visitedOn, equalTo: lastMonth, toGranularity: .month) }.count
    }

    struct CategoryRow { let category: PlaceCategory; let count: Int }
    var categoryBreakdown: [CategoryRow] {
        let grouped = Dictionary(grouping: visited, by: { $0.place?.category ?? .other })
        return PlaceCategory.allCases
            .map { CategoryRow(category: $0, count: grouped[$0]?.count ?? 0) }
            .filter { $0.count > 0 }
            .sorted { $0.count > $1.count }
    }

    struct NeighborhoodRow { let rank: Int; let name: String; let count: Int }
    var topNeighborhoods: [NeighborhoodRow] {
        let grouped = Dictionary(grouping: visited.compactMap { $0.place?.neighborhood }.filter { !$0.isEmpty },
                                 by: { $0 })
        return grouped
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .enumerated()
            .map { NeighborhoodRow(rank: $0.offset + 1, name: $0.element.0, count: $0.element.1) }
    }

    struct TagRow { let tag: String; let count: Int }
    var topTags: [TagRow] {
        let all = visited.flatMap { $0.tags }
        let grouped = Dictionary(grouping: all, by: { $0 })
        return grouped
            .map { TagRow(tag: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(8)
            .map { $0 }
    }

    struct RatingRow { let rating: Rating; let count: Int }
    var ratingBreakdown: [RatingRow] {
        let grouped = Dictionary(grouping: visited.compactMap { $0.rating }, by: { $0 })
        return Rating.allCases.map { RatingRow(rating: $0, count: grouped[$0]?.count ?? 0) }
    }
    var ratedCount: Int { visited.compactMap { $0.rating }.count }

    var wouldReturnPercent: Int? {
        let withIntent = visited.compactMap { $0.returnIntent }
        guard !withIntent.isEmpty else { return nil }
        let yes = withIntent.filter { $0 == .immediately || $0 == .whenNearby }.count
        return Int((Double(yes) / Double(withIntent.count)) * 100)
    }

    struct MonthBucket: Identifiable {
        let date: Date
        let count: Int
        var id: Date { date }
    }
    /// One entry per month for the last 12 months (oldest first), zero-filled for empty months.
    var monthlyCadence: [MonthBucket] {
        let cal = Calendar.current
        let now = Date()
        let startOfThisMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let months: [Date] = (0..<12).compactMap {
            cal.date(byAdding: .month, value: -(11 - $0), to: startOfThisMonth)
        }
        let counts = Dictionary(grouping: visited) { visit -> Date in
            cal.date(from: cal.dateComponents([.year, .month], from: visit.visitedOn)) ?? visit.visitedOn
        }.mapValues(\.count)
        return months.map { MonthBucket(date: $0, count: counts[$0] ?? 0) }
    }

    /// Number of ISO weeks in the last 12 weeks with at least one visit.
    var activeWeeksLast12: Int {
        let cal = Calendar.current
        let now = Date()
        guard let twelveWeeksAgo = cal.date(byAdding: .weekOfYear, value: -12, to: now) else { return 0 }
        let recent = visited.filter { $0.visitedOn >= twelveWeeksAgo }
        let weekKeys = Set(recent.compactMap { visit -> Int? in
            cal.component(.weekOfYear, from: visit.visitedOn)
        })
        return weekKeys.count
    }
}

// MARK: - Reusable stat components

private struct StatCard: View {
    let title: String
    let value: String
    let caption: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }
}

private struct CategoryBar: View {
    let label: String
    let count: Int
    let total: Int
    let tint: Color
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text("\(count)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(uiColor: .tertiarySystemFill))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: geo.size.width * fraction, height: 6)
                }
            }
            .frame(height: 6)
        }
    }

    private var fraction: CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(count) / CGFloat(total)
    }
}

private struct LeaderboardRow: View {
    let rank: Int
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

private struct TagCountChip: View {
    let tag: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(tag)
                .font(.subheadline.weight(.medium))
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(uiColor: .tertiarySystemBackground)))
    }
}

private struct RatingBar: View {
    let rating: Rating
    let count: Int
    let total: Int

    var body: some View {
        HStack(spacing: 10) {
            Label {
                Text(rating.label).font(.subheadline)
            } icon: {
                Image(systemName: rating.symbol)
                    .foregroundStyle(color)
            }
            .frame(width: 90, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(uiColor: .tertiarySystemFill)).frame(height: 6)
                    Capsule().fill(color.gradient)
                        .frame(width: geo.size.width * fraction, height: 6)
                }
            }
            .frame(height: 6)

            Text("\(count)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(width: 28, alignment: .trailing)
        }
    }

    private var fraction: CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(count) / CGFloat(total)
    }

    private var color: Color {
        switch rating {
        case .loved: .pink
        case .liked: .green
        case .fine:  .yellow
        case .no:    .red
        }
    }
}

private struct MilestoneRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }
}
