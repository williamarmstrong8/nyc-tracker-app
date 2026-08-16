import SwiftUI

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
    var activeTab: AppTab
    var onMap: () -> Void
    var onDiscover: () -> Void
    var onFriends: () -> Void
    var onLogVisit: () -> Void
    var onWantToTry: () -> Void
    var onProfile: () -> Void

    @State private var showNewEntryOptions = false
    @Namespace private var glassNamespace

    var body: some View {
        ZStack(alignment: .bottom) {
            if showNewEntryOptions {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { dismissNewEntryOptions() }
                    .accessibilityLabel("Dismiss")
                    .accessibilityAddTraits(.isButton)
            }

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

                // The bar and the plus are deliberately in separate glass containers — otherwise
                // Liquid Glass blends/merges shapes that are close together, and the plus
                // button's tint bleeds onto the plain bar underneath it.
                ZStack {
                    GlassEffectContainer { navBar }
                    GlassEffectContainer { plusButton }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 8)
        }
        .animation(.smooth(duration: 0.32), value: showNewEntryOptions)
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

    /// The bar itself is one glass surface; the icon buttons inside are plain so we don't stack
    /// glass on glass.
    private var navBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 30) {
                navIcon("map.fill", label: "Map", isActive: activeTab == .home, action: onMap)
                navIcon("safari.fill", label: "Discover", isActive: activeTab == .discover, action: onDiscover)
            }
            Spacer(minLength: 76)
            HStack(spacing: 30) {
                navIcon("person.2.fill", label: "Friends", isActive: activeTab == .friends, action: onFriends)
                navIcon("person.fill", label: "Profile", isActive: activeTab == .profile, action: onProfile)
            }
        }
        .padding(.horizontal, 26)
        .frame(height: 58)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .capsule)
        .glassEffectID("nav-bar", in: glassNamespace)
    }

    private func navIcon(_ symbol: String, label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            dismissNewEntryOptions()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    /// Raised, centered on top of the bar — deliberately taller than the bar so it protrudes
    /// above (and slightly below) it, like a thumb sitting on a track.
    private var plusButton: some View {
        Button {
            Haptics.tap()
            showNewEntryOptions.toggle()
        } label: {
            Image(systemName: showNewEntryOptions ? "xmark" : "plus")
                .font(.title.weight(.semibold))
                .frame(width: 72, height: 72)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .glassEffectID("nav-plus", in: glassNamespace)
        .accessibilityLabel(showNewEntryOptions ? "Close" : "New entry")
    }

    private func dismissNewEntryOptions() {
        guard showNewEntryOptions else { return }
        showNewEntryOptions = false
    }
}
