// TEMPORARY DIAGNOSTIC HARNESS — delete before committing.
// Launch with `-navDelayHarness` to get here.

import SwiftUI

private let harnessPeople: [PersonSummary] = (0..<12).map { i in
    PersonSummary(
        id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!,
        username: "user\(i)",
        displayName: ["Maya Chen", "Dev Patel", "Sam Rivera", "Alex Kim"][i % 4] + " \(i)",
        avatarURL: nil
    )
}

/// Which of ContentView's traits are switched on. Bisecting these is the point.
private struct HarnessFlags {
    /// ContentView's `.animation(.smooth(duration: 0.28), value: showsBottomBar)`
    /// wrapping the whole page + the dock's insert/remove transition.
    static var bottomBarAnimation: Bool { on("-hBar") }
    /// FriendsListScreen's `Group { ProgressView / List }` swap.
    static var groupSwap: Bool { on("-hSwap") }
    /// ChatView's `Group { switch loadState }` swap, which flips from
    /// ProgressView to the thread a beat after the push lands.
    static var chatLoadSwap: Bool { on("-hLoad") }
    /// Applies the toolbar to a stable wrapper instead of to the switching
    /// Group — the candidate fix.
    static var stableToolbarHost: Bool { on("-hStable") }
    /// ChatView wraps the header in a `NavigationLink` to the profile.
    static var headerIsLink: Bool { on("-hLink") }
    /// ChatView's glass composer in a bottom `safeAreaInset`.
    static var composer: Bool { on("-hComposer") }
    /// Burns main-thread time as the chat page appears, standing in for the
    /// real `open()` — network callback, JSON decode, snapshot encode — all of
    /// which are main-actor isolated in this project.
    static var busyMainThread: Bool { on("-hBusy") }
    /// ChatView's real scroll setup: bottom-anchored, content only after load.
    static var bottomAnchored: Bool { on("-hAnchor") }
    /// The candidate fix: pin the nav bar background so it does not wait on
    /// scroll-content measurement, exactly as `appSearchable` does.
    static var pinnedBar: Bool { on("-hPin") }
    private static func on(_ f: String) -> Bool { ProcessInfo.processInfo.arguments.contains(f) }
}

/// Mirrors ContentView: a Group-switch between tabs (so the friends stack is
/// built fresh on every entry), a floating dock that chat hides, and the
/// animation that flips with it.
struct NavDelayHarnessRoot: View {
    enum Tab { case home, friends }
    @State private var tab: Tab = .home
    @State private var pushTick = 0
    @State private var hidesBottomBar = false

    private var showsBottomBar: Bool { !hidesBottomBar }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .home:
                    ZStack { Color.red.ignoresSafeArea(); Text("HOME").font(.largeTitle) }
                case .friends:
                    HarnessFriendsStack(pushTick: pushTick, hidesBottomBar: $hidesBottomBar)
                }
            }
            .safeAreaPadding(.bottom, showsBottomBar ? 80 : 0)

            if showsBottomBar {
                Text("DOCK")
                    .font(.headline)
                    .padding()
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            }
        }
        .modifier(ConditionalBarAnimation(enabled: HarnessFlags.bottomBarAnimation, value: showsBottomBar))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                tab = .friends            // A: search bar background on frame 1?
                try? await Task.sleep(for: .seconds(2))
                pushTick += 1             // B: chat header on frame 1?
                try? await Task.sleep(for: .seconds(3))
                tab = .home
                hidesBottomBar = false
            }
        }
    }
}

private struct ConditionalBarAnimation: ViewModifier {
    let enabled: Bool
    let value: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.animation(.smooth(duration: 0.28), value: value)
        } else {
            content
        }
    }
}

private struct HarnessFriendsStack: View {
    let pushTick: Int
    @Binding var hidesBottomBar: Bool

    @State private var path: [PersonSummary] = []
    @State private var query = ""
    @State private var loaded = !HarnessFlags.groupSwap

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .appSearchable(text: $query, prompt: "Search friends")
            .navigationDestination(for: PersonSummary.self) { p in
                HarnessChatPage(person: p)
            }
        }
        .onAppear { hidesBottomBar = !path.isEmpty }
        .onChange(of: path) { _, newPath in hidesBottomBar = !newPath.isEmpty }
        .onChange(of: pushTick) { _, _ in
            if pushTick > 0, path.isEmpty { path = [harnessPeople[0]] }
        }
        .task {
            if HarnessFlags.groupSwap {
                try? await Task.sleep(for: .milliseconds(400))
                loaded = true
            }
        }
    }

    private var list: some View {
        List {
            ForEach(harnessPeople) { p in
                NavigationLink(value: p) {
                    HStack(spacing: 12) {
                        PersonAvatar(person: p, size: 44)
                        PersonLabel(person: p)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// Mirrors ChatView's header: principal toolbar item with avatar + name,
/// over a `Group` whose branch flips once the thread loads.
private struct HarnessChatPage: View {
    let person: PersonSummary

    @State private var ready = !HarnessFlags.chatLoadSwap

    var body: some View {
        if HarnessFlags.stableToolbarHost {
            // Candidate fix: the switching Group is a *child* of a view with
            // stable identity, and the toolbar hangs off that stable view.
            ZStack { content }
                .modifier(ChatChrome(person: person))
                .task { await flip() }
        } else {
            content
                .modifier(ChatChrome(person: person))
                .task { await flip() }
        }
    }

    private func flip() async {
        guard HarnessFlags.chatLoadSwap else { return }
        try? await Task.sleep(for: .milliseconds(450))
        ready = true
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if !ready {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                thread
            }
        }
    }

    private var thread: some View {
        ScrollViewReader { _ in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(0..<40, id: \.self) { i in
                        Text("Message \(i)")
                            .frame(maxWidth: .infinity, alignment: i.isMultiple(of: 2) ? .leading : .trailing)
                            .padding(.horizontal, 20)
                    }
                }
                .padding(.vertical, 20)
            }
            .modifier(AnchorBottom(enabled: HarnessFlags.bottomAnchored))
        }
    }
}

/// ChatView's chrome, verbatim, so it is applied identically in both arms.
private struct ChatChrome: ViewModifier {
    let person: PersonSummary

    func body(content: Content) -> some View {
        content
            .background(Color(uiColor: .systemGroupedBackground))
            .modifier(PinnedBar(enabled: HarnessFlags.pinnedBar))
            .navigationTitle(person.bestName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if HarnessFlags.headerIsLink {
                        NavigationLink(value: person) { headerLabel }
                            .buttonStyle(.plain)
                    } else {
                        headerLabel
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if HarnessFlags.composer { HarnessComposer() }
            }
            // The A/B: the identical header, drawn as ordinary page content.
            // Whichever of the two appears first is the answer.
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    Text("INLINE:")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red)
                    headerLabel
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.yellow)
            }
            .onAppear {
                guard HarnessFlags.busyMainThread else { return }
                // Synchronous, on the main actor, exactly like a decode.
                let deadline = Date().addingTimeInterval(0.30)
                var sink = 0
                while Date() < deadline { sink &+= 1 }
                _ = sink
            }
    }

    private var headerLabel: some View {
        HStack(spacing: 8) {
            PersonAvatar(person: person, size: 30)
            Text(person.bestName)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}

/// ChatView's composer shape: two glass surfaces in a GlassEffectContainer.
private struct HarnessComposer: View {
    @State private var text = ""

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Send a place")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect(.regular.interactive(), in: .capsule)
                HStack {
                    TextField("Message", text: $text, axis: .vertical)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    Image(systemName: "arrow.up.circle.fill").padding(.trailing, 8)
                }
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}


private struct AnchorBottom: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            content
        }
    }
}

private struct PinnedBar: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content
                .scrollEdgeEffectHidden(true, for: .top)
                .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        } else {
            content
        }
    }
}
