import SwiftUI

/// The two halves of a profile: what someone logged, and what they were tagged in.
///
/// Shared by the signed-in profile and a friend's, because they answer the same
/// question about different people and should not drift apart in wording or
/// order.
enum ProfileTab: String, CaseIterable, Identifiable {
    /// Entries this person wrote.
    case activity
    /// Entries someone else wrote and tagged this person in.
    case tagged

    var id: String { rawValue }

    var label: String {
        switch self {
        case .activity: "Activity"
        case .tagged:   "Tagged"
        }
    }

    var symbol: String {
        switch self {
        case .activity: "square.grid.3x3.fill"
        case .tagged:   "person.2.fill"
        }
    }
}

/// Icon-only segmented control, the way a photo grid is usually tabbed.
///
/// Icons rather than words because the two labels sit above a full-bleed grid
/// and a text segmented control at that width reads as a form field. The words
/// survive as accessibility labels.
struct ProfileTabPicker: View {
    @Binding var selection: ProfileTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ProfileTab.allCases) { tab in
                Button {
                    guard selection != tab else { return }
                    Haptics.tap()
                    withAnimation(.snappy(duration: 0.2)) { selection = tab }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)

                        // The indicator is a full-width rule under the selected
                        // half rather than a pill around it, so the control
                        // reads as a divider the grid hangs off.
                        Rectangle()
                            .fill(selection == tab ? Color.primary : Color.clear)
                            .frame(height: 1.5)
                    }
                    .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label)
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 0.5)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }
}
