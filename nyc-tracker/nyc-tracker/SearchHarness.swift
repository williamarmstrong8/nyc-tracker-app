// TEMPORARY DIAGNOSTIC HARNESS — delete before committing.
// Launch the app with the `-searchHarness` argument to get here.

import SwiftUI

struct SearchHarnessRoot: View {
    @State private var variant: HarnessVariant?

    /// `-harnessVariant A` etc. Auto-presents so the presentation can be caught
    /// on a screenshot burst without anyone tapping anything.
    private static var requested: HarnessVariant {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-harnessVariant"), i + 1 < args.count,
              let v = HarnessVariant(rawValue: args[i + 1]) else { return .appSearchableSheet }
        return v
    }

    var body: some View {
        ZStack { Color.red.ignoresSafeArea() }
            .preferredColorScheme(.dark)
            .sheet(item: $variant) { v in v.view }
            .task {
                // Present / dismiss on a loop so a screenshot burst catches the
                // presentation no matter when the burst starts.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2.5))
                    variant = Self.requested
                    try? await Task.sleep(for: .seconds(2.5))
                    variant = nil
                }
            }
    }
}

enum HarnessVariant: String, CaseIterable, Identifiable {
    case appSearchableSheet = "A"
    case plainSearchableSheet = "B"
    case groupSwapSheet = "C"
    case scrollEdgeOnly = "D"
    case toolbarBGOnly = "E"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appSearchableSheet: return "A appSearchable"
        case .plainSearchableSheet: return "B plain searchable"
        case .groupSwapSheet: return "C group swap"
        case .scrollEdgeOnly: return "D edge hidden only"
        case .toolbarBGOnly: return "E toolbar bg only"
        }
    }

    @ViewBuilder var view: some View {
        switch self {
        case .appSearchableSheet: HarnessA()
        case .plainSearchableSheet: HarnessB()
        case .groupSwapSheet: HarnessC()
        case .scrollEdgeOnly: HarnessD()
        case .toolbarBGOnly: HarnessE()
        }
    }
}

private struct Rows: View {
    var body: some View {
        List {
            ForEach(0..<30, id: \.self) { i in
                Text("Row \(i)")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

// A: exactly what AddFriendsView does today.
private struct HarnessA: View {
    @State private var query = ""
    var body: some View {
        NavigationStack {
            Rows()
                .background(Color.black)
                .navigationTitle("A appSearchable")
                .navigationBarTitleDisplayMode(.inline)
                .appSearchable(text: $query, prompt: "Name or username")
        }
        .preferredColorScheme(.dark)
        .presentationBackground(.black)
    }
}

// B: stock .searchable, no toolbar/edge overrides at all.
private struct HarnessB: View {
    @State private var query = ""
    var body: some View {
        NavigationStack {
            Rows()
                .background(Color.black)
                .navigationTitle("B plain")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or username")
        }
        .preferredColorScheme(.dark)
        .presentationBackground(.black)
    }
}

// C: FriendsView's shape — no scroll view for the first second, then a List.
private struct HarnessC: View {
    @State private var query = ""
    @State private var loaded = false
    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Rows()
                }
            }
            .background(Color.black)
            .navigationTitle("C group swap")
            .navigationBarTitleDisplayMode(.inline)
            .appSearchable(text: $query, prompt: "Search friends")
        }
        .preferredColorScheme(.dark)
        .presentationBackground(.black)
        .task {
            try? await Task.sleep(for: .seconds(1.2))
            loaded = true
        }
    }
}

// D: only the scroll-edge-effect suppression.
private struct HarnessD: View {
    @State private var query = ""
    var body: some View {
        NavigationStack {
            Rows()
                .background(Color.black)
                .navigationTitle("D edge hidden")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or username")
                .scrollEdgeEffectHidden(true, for: .top)
        }
        .preferredColorScheme(.dark)
        .presentationBackground(.black)
    }
}

// E: only the forced opaque toolbar background.
private struct HarnessE: View {
    @State private var query = ""
    var body: some View {
        NavigationStack {
            Rows()
                .background(Color.black)
                .navigationTitle("E toolbar bg")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or username")
                .toolbarBackground(.black, for: .navigationBar)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .presentationBackground(.black)
    }
}
