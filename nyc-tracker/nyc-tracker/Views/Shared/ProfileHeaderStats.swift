import SwiftUI

/// Three-column stats row under a profile header — friends, been, want to try.
/// Pass tap handlers to make a stat tappable; omit them for display-only counts.
struct ProfileHeaderStats: View {
    let friendCount: Int
    let beenCount: Int
    let wantToTryCount: Int
    var onFriendsTap: (() -> Void)? = nil
    var onBeenTap: (() -> Void)? = nil
    var onWantToTryTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            stat(count: friendCount, label: friendCount == 1 ? "friend" : "friends", action: onFriendsTap)
            divider
            stat(count: beenCount, label: "been", action: onBeenTap)
            divider
            stat(count: wantToTryCount, label: "want to try", action: onWantToTryTap)
        }
        .padding(.top, 6)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(width: 1, height: 32)
            .opacity(0.5)
    }

    @ViewBuilder
    private func stat(count: Int, label: String, action: (() -> Void)?) -> some View {
        let content = VStack(spacing: 2) {
            Text("\(count)")
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(label)")

        if let action {
            Button {
                Haptics.tap()
                action()
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }
}
