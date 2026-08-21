import SwiftUI

/// The venue, then the two things you can do with it.
///
/// A sheet rather than a swipe action or a menu on the row, because the choice
/// deserves the address in front of it — "Prince Street Pizza" is four different
/// places and the user is picking one.
///
/// Shown from `MapHome` when the user taps an Apple Maps point of interest.
struct PlaceActionSheet: View {
    let candidate: VenueCandidate
    var onLogVisit: () -> Void
    var onWantToTry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(tint.opacity(0.15)))

                Text(candidate.name)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                if let address = candidate.address, !address.isEmpty {
                    Text(address)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .padding(.top, 44)

            VStack(spacing: 10) {
                Button {
                    Haptics.tap()
                    onLogVisit()
                } label: {
                    Label("Log a visit", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glassProminent)

                Button {
                    Haptics.tap()
                    onWantToTry()
                } label: {
                    Label("Want to try", systemImage: "bookmark.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: .systemBackground))
    }

    private var symbol: String {
        switch candidate.category {
        case .restaurant: "fork.knife"
        case .bar:        "wineglass.fill"
        case .cafe:       "cup.and.saucer.fill"
        case .bakery:     "birthday.cake.fill"
        case .other:      "mappin"
        }
    }

    private var tint: Color {
        switch candidate.category {
        case .restaurant: .orange
        case .bar:        .purple
        case .cafe:       .brown
        case .bakery:     .pink
        case .other:      .gray
        }
    }
}
