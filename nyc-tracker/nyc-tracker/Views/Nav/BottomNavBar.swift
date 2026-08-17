import SwiftUI
import UIKit

/// The app's persistent top-level destinations. `Map`/`Discover`/`Friends`/`Profile` are real
/// pages that swap into the main content area (see `ContentView`) rather than modal pop-ups —
/// the floating bottom bar just indicates and switches which one is active.
enum AppTab: Equatable {
    case home
    case discover
    case friends
    case profile
}

struct BottomNavBar: View {
    /// Capsule height — icon-only, matching a compact floating dock.
    static let barHeight: CGFloat = 68
    /// Raised white plus — larger than the bar so it overhangs like BeReal's camera.
    static let plusSize: CGFloat = 76
    /// Gap from the physical screen bottom once the home-indicator inset is
    /// cancelled. Resting and plus-open share this; the bar must not jump.
    static let bottomPadding: CGFloat = 22

    /// Inner horizontal padding of the capsule. Slots are laid out inside it, and the
    /// selector's travel math reads the same number, so the two can't drift apart.
    private static let barInset: CGFloat = 4
    private static let iconSize: CGFloat = 21
    private static let profileAvatar: CGFloat = 26
    /// How much smaller the selector is than the slot it sits in.
    private static let pillInsetX: CGFloat = 4
    private static let pillInsetY: CGFloat = 5
    /// Breathing room between the raised plus disc and the adjacent tab icons.
    private static let plusSideClearance: CGFloat = 10
    /// Middle well — wider than a tab slot so the 76pt disc doesn't crowd Discover/Friends.
    private static var centerSlotWidth: CGFloat { plusSize + plusSideClearance * 2 }

    /// How far above the layout bottom the capsule's vertical center sits.
    ///
    /// Used as extra bottom safe-area padding so the last row can scroll clear
    /// of the dock. Pages themselves stay full-bleed under the glass.
    static var contentClearance: CGFloat {
        max(
            16,
            bottomPadding + (plusSize - barHeight) / 2 + barHeight / 2 - homeIndicatorInset
        )
    }

    var activeTab: AppTab
    /// Pending items awaiting the user's response: incoming friend requests
    /// and unread messages.
    var friendsBadgeCount: Int = 0
    var onMap: () -> Void
    var onDiscover: () -> Void
    var onFriends: () -> Void
    var onLogVisit: () -> Void
    var onWantToTry: () -> Void
    var onProfile: () -> Void

    @Environment(AuthManager.self) private var auth
    @State private var showNewEntryOptions = false
    /// Selector center while a drag is in flight, in bar coordinates. `nil` means the
    /// selector rests on `activeTab`.
    @State private var dragCenterX: CGFloat?
    /// Slot the in-flight drag would land on. Drives the highlight so icons light up
    /// under the finger before the page actually switches on release.
    @State private var dragSlot: Int?
    @Namespace private var glassNamespace

    // MARK: - Slots

    /// One entry per bar position, in layout order. The middle slot has no tab — it's the
    /// well the raised plus sits in — but the selector still travels across it, which is
    /// what makes a drag from Discover to Friends read as one continuous slide.
    private struct Slot: Identifiable {
        let id: Int
        let tab: AppTab?
        let symbol: String?
        let label: String
    }

    private static let slots: [Slot] = [
        Slot(id: 0, tab: .home, symbol: "map.fill", label: "Map"),
        Slot(id: 1, tab: .discover, symbol: "safari.fill", label: "Discover"),
        Slot(id: 2, tab: nil, symbol: nil, label: ""),
        Slot(id: 3, tab: .friends, symbol: "paperplane.fill", label: "Friends"),
        Slot(id: 4, tab: .profile, symbol: nil, label: "Profile")
    ]

    var body: some View {
        VStack(spacing: 16) {
            if showNewEntryOptions {
                GlassEffectContainer(spacing: 12) {
                    newEntryCards
                }
                .padding(.horizontal, 20)
                .transition(
                    .move(edge: .bottom)
                    .combined(with: .opacity)
                    .combined(with: .scale(scale: 0.94, anchor: .bottom))
                )
            }

            // Plus is not glass — a solid white disc — so it lives outside the
            // bar's GlassEffectContainer and won't bleed tint into the pill.
            ZStack {
                GlassEffectContainer(spacing: 20) { navBar }
                plusButton
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, Self.bottomPadding)
        // Pull the compact dock into the home-indicator inset. Do not expand
        // to full-screen to get there — a full-screen child is what made the
        // bar drop when plus opened.
        .offset(y: Self.homeIndicatorInset)
        .ignoresSafeArea(.container, edges: .bottom)
        .background {
            if showNewEntryOptions {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { dismissNewEntryOptions() }
                    .accessibilityLabel("Dismiss")
                    .accessibilityAddTraits(.isButton)
            }
        }
        .animation(.smooth(duration: 0.32), value: showNewEntryOptions)
    }

    /// Home-indicator inset of the key window. Read from UIKit so measuring it
    /// in this view's own GeometryReader cannot feedback (offset → inset 0 → jump).
    private static var homeIndicatorInset: CGFloat {
        let inset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom
        return inset ?? 34
    }

    private var newEntryCards: some View {
        HStack(spacing: 12) {
            newEntryCard(
                title: "Log a visit",
                systemImage: "photo.on.rectangle.angled",
                glassID: "action-log"
            ) {
                dismissNewEntryOptions()
                onLogVisit()
            }

            newEntryCard(
                title: "Want to try",
                systemImage: "bookmark.fill",
                glassID: "action-want"
            ) {
                dismissNewEntryOptions()
                onWantToTry()
            }
        }
    }

    private func newEntryCard(
        title: String,
        systemImage: String,
        glassID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.soft()
            action()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle)
        .glassEffectID(glassID, in: glassNamespace)
    }

    /// Floating pill with five slots; the middle well is wider than the tabs so the
    /// raised plus doesn't steal space from the icons beside it.
    ///
    /// Slot widths are measured rather than left to `maxWidth: .infinity` because the
    /// drag gesture needs the exact same geometry the layout used to decide where the
    /// selector is and which slot the finger is over.
    private var navBar: some View {
        GeometryReader { proxy in
            let barWidth = proxy.size.width

            ZStack(alignment: .leading) {
                selectionPill(barWidth: barWidth)

                HStack(spacing: 0) {
                    ForEach(Self.slots) { slot in
                        slotView(slot)
                            .frame(width: Self.slotWidth(slot.id, in: barWidth))
                    }
                }
                .padding(.horizontal, Self.barInset)
            }
            .frame(width: barWidth, height: proxy.size.height)
            .contentShape(Capsule())
            .gesture(selectorDrag(barWidth: barWidth))
        }
        .frame(height: Self.barHeight)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID("nav-bar", in: glassNamespace)
    }

    @ViewBuilder
    private func slotView(_ slot: Slot) -> some View {
        if let tab = slot.tab {
            let isHighlighted = highlightedSlot == slot.id
            Button {
                Haptics.tap()
                dismissNewEntryOptions()
                select(tab)
            } label: {
                slotGlyph(slot)
                    .badgeOverlay(tab == .friends ? friendsBadgeCount : 0)
                    .foregroundStyle(isHighlighted ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel(for: slot))
            .accessibilityAddTraits(activeTab == tab ? [.isSelected] : [])
        } else {
            // Well for the raised plus, which is drawn above the bar.
            Color.clear.allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func slotGlyph(_ slot: Slot) -> some View {
        if let symbol = slot.symbol {
            Image(systemName: symbol)
                .font(.system(size: Self.iconSize, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .frame(height: Self.iconSize + 4)
        } else {
            profileAvatarView
                .frame(height: Self.iconSize + 4)
        }
    }

    @ViewBuilder
    private var profileAvatarView: some View {
        if let profile = auth.state.profile {
            PersonAvatar(
                person: PersonSummary(
                    id: profile.id,
                    username: profile.username,
                    displayName: profile.displayName,
                    avatarURL: profile.avatarURL
                ),
                size: Self.profileAvatar
            )
        } else {
            Image("Logo")
                .resizable()
                .scaledToFill()
                .frame(width: Self.profileAvatar, height: Self.profileAvatar)
                .clipShape(Circle())
        }
    }

    // MARK: - Layout

    private static func innerBarWidth(_ barWidth: CGFloat) -> CGFloat {
        max(1, barWidth - barInset * 2)
    }

    private static func tabSlotWidth(in barWidth: CGFloat) -> CGFloat {
        max(1, (innerBarWidth(barWidth) - centerSlotWidth) / 4)
    }

    private static func slotWidth(_ id: Int, in barWidth: CGFloat) -> CGFloat {
        id == 2 ? centerSlotWidth : tabSlotWidth(in: barWidth)
    }

    private static func slotLeading(_ id: Int, in barWidth: CGFloat) -> CGFloat {
        (0..<id).reduce(into: 0) { partial, index in
            partial += slotWidth(index, in: barWidth)
        }
    }

    private static func slotCenter(_ id: Int, in barWidth: CGFloat) -> CGFloat {
        slotLeading(id, in: barWidth) + slotWidth(id, in: barWidth) / 2
    }

    // MARK: - Selector

    /// A real lens of glass rather than a flat tint, and a single persistent view rather
    /// than one pill per tab — so switching tabs isn't a crossfade, it's the same piece of
    /// glass sliding to the new slot, refracting whatever it passes over. Living inside the
    /// bar's `GlassEffectContainer` is what lets the two surfaces blend as it travels.
    private func selectionPill(barWidth: CGFloat) -> some View {
        let tabSlot = Self.tabSlotWidth(in: barWidth)
        let width = tabSlot - Self.pillInsetX * 2
        let center = pillCenter(barWidth: barWidth)

        return Color.clear
            .frame(width: width, height: Self.barHeight - Self.pillInsetY * 2)
            .glassEffect(.clear.interactive(), in: .capsule)
            .glassEffectID("tab-selector", in: glassNamespace)
            // Squished along the direction of travel while dragging, so the glass reads
            // as something being pulled rather than teleported.
            .scaleEffect(x: isDragging ? 1.05 : 1, y: isDragging ? 0.94 : 1)
            .offset(x: center - width / 2 + Self.barInset)
            .animation(selectorAnimation, value: center)
            .animation(.snappy(duration: 0.22), value: isDragging)
            .allowsHitTesting(false)
    }

    private var isDragging: Bool { dragCenterX != nil }

    /// Following a finger wants no smoothing beyond a touch of lag; landing wants a
    /// spring that overshoots slightly, which is what makes the glass feel liquid.
    private var selectorAnimation: Animation {
        isDragging
            ? .interactiveSpring(response: 0.16, dampingFraction: 0.82)
            : .spring(response: 0.38, dampingFraction: 0.72)
    }

    /// Slot the selector currently sits over: the drag target while dragging, the
    /// committed tab otherwise.
    private var highlightedSlot: Int { dragSlot ?? activeSlot }

    private var activeSlot: Int {
        Self.slots.first { $0.tab == activeTab }?.id ?? 0
    }

    private func pillCenter(barWidth: CGFloat) -> CGFloat {
        dragCenterX ?? Self.slotCenter(activeSlot, in: barWidth)
    }

    /// Closest slot that actually has a tab, so the selector never comes to rest in the
    /// plus well even though it can slide across it.
    private func nearestTabSlot(to x: CGFloat, barWidth: CGFloat) -> Int {
        Self.slots
            .filter { $0.tab != nil }
            .min {
                abs(Self.slotCenter($0.id, in: barWidth) - x)
                    < abs(Self.slotCenter($1.id, in: barWidth) - x)
            }?
            .id ?? activeSlot
    }

    /// Grab the selector (from anywhere on the bar) and drag it. The tab commits on
    /// release — pages here are expensive enough that switching mid-drag would stutter —
    /// but the highlight and haptics track the finger the whole way.
    private func selectorDrag(barWidth: CGFloat) -> some Gesture {
        let travel = Self.slots.compactMap { slot -> CGFloat? in
            guard slot.tab != nil else { return nil }
            return Self.slotCenter(slot.id, in: barWidth)
        }
        let lowerBound = travel.min() ?? 0
        let upperBound = travel.max() ?? Self.tabSlotWidth(in: barWidth)

        return DragGesture(minimumDistance: 8)
            .onChanged { value in
                if dragCenterX == nil {
                    dismissNewEntryOptions()
                    dragSlot = activeSlot
                }
                let anchor = Self.slotCenter(activeSlot, in: barWidth)
                let x = min(max(anchor + value.translation.width, lowerBound), upperBound)
                dragCenterX = x

                let target = nearestTabSlot(to: x, barWidth: barWidth)
                if target != dragSlot {
                    dragSlot = target
                    Haptics.tap()
                }
            }
            .onEnded { _ in
                let target = dragSlot
                dragCenterX = nil
                dragSlot = nil
                if let target, let tab = Self.slots[target].tab, tab != activeTab {
                    select(tab)
                }
            }
    }

    private func select(_ tab: AppTab) {
        switch tab {
        case .home: onMap()
        case .discover: onDiscover()
        case .friends: onFriends()
        case .profile: onProfile()
        }
    }

    private func accessibilityLabel(for slot: Slot) -> String {
        guard slot.tab == .friends, friendsBadgeCount > 0 else { return slot.label }
        return "\(slot.label), \(pluralized(friendsBadgeCount, "pending item"))"
    }

    /// Solid raised center control — white disc with a dark plus, sitting on the pill.
    private var plusButton: some View {
        Button {
            Haptics.tap()
            showNewEntryOptions.toggle()
        } label: {
                Image(systemName: showNewEntryOptions ? "xmark" : "plus")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: Self.plusSize, height: Self.plusSize)
                .background(Circle().fill(.white))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .accessibilityLabel(showNewEntryOptions ? "Close" : "New entry")
    }

    private func dismissNewEntryOptions() {
        guard showNewEntryOptions else { return }
        showNewEntryOptions = false
    }
}
