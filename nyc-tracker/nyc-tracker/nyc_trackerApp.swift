//
//  nyc_trackerApp.swift
//  nyc-tracker
//

import SwiftUI
import SwiftData

@main
struct nyc_trackerApp: App {
    /// Created once, for the lifetime of the app. Owns the auth session and the
    /// profile, and is injected so any view can read `AuthState` without passing
    /// it down by hand.
    @State private var auth = AuthManager()

    /// Also app-lifetime. It has to outlive any individual screen — an upload
    /// started from the capture flow must keep going after that flow is
    /// dismissed, and a sync engine owned by a view would be torn down mid-upload
    /// every time the user navigated away.
    @State private var sync = SyncEngine()

    /// The friend graph. App-lifetime alongside the others so the friends badge is
    /// live on every screen without each one fetching it, and so a request
    /// accepted on the friends page is reflected on the map without a reload.
    @State private var social = SocialGraph()

    /// Direct messages. App-lifetime for a harder reason than the others: it
    /// owns a realtime channel, and a channel is registered with the shared
    /// client rather than with whatever view created it. A store that died with
    /// a screen would leave that subscription open and still delivering.
    @State private var chat = ChatStore()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Backstop for a recording whose transcription never completed because
        // the app was killed. `SpeechRecorder.stop()` deletes the file itself on
        // every normal path; this makes "no voice memo audio survives a launch"
        // true even when the last session ended abnormally.
        FileStorage.purgeAudioDirectory()
    }

    var body: some Scene {
        WindowGroup {
            // RootView is the auth gate. ContentView — the existing app — is only
            // reachable from inside it, and only with a session and a username.
            Group {
                if ProcessInfo.processInfo.arguments.contains("-navDelayHarness") {
                    NavDelayHarnessRoot()
                } else if ProcessInfo.processInfo.arguments.contains("-searchHarness") {
                    SearchHarnessRoot()
                } else {
                    RootView()
                }
            }
                .environment(auth)
                .environment(sync)
                .environment(social)
                .environment(chat)
                // App-wide: no scroll indicators anywhere. Set once here rather
                // than on every individual ScrollView/List/Form, since this
                // environment value is inherited by every descendant scrollable
                // view — including those inside sheets and pushed screens.
                .scrollIndicators(.hidden)
        }
        .modelContainer(LocalStore.shared)
        .onChange(of: scenePhase) { _, phase in
            // Foreground is one of the three retry triggers (the others are the
            // network becoming reachable and an explicit pull-to-refresh). It
            // covers the common case: the upload was interrupted by the user
            // switching apps, and resumes the moment they come back.
            if phase == .active {
                sync.requestSync(reason: .appForeground)
                // A request accepted on another device while this one was
                // backgrounded should be visible on return, and the graph has no
                // realtime subscription. Cheap: one indexed query.
                social.refresh()
                // Chat does have one, but a socket dropped while backgrounded
                // reconnects without replaying what it missed. One thread fetch
                // on return is what makes the badge honest.
                chat.refreshThreads()
            }
        }
    }
}
