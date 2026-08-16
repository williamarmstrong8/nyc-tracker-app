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

    var body: some Scene {
        WindowGroup {
            // RootView is the auth gate. ContentView — the existing app — is only
            // reachable from inside it, and only with a session and a username.
            RootView()
                .environment(auth)
        }
        // SwiftData stays exactly as it was: the app is still local-first and the
        // capture flow is untouched by this task. Sync lands later.
        .modelContainer(LocalStore.shared)
    }
}
