//
//  nyc_trackerApp.swift
//  nyc-tracker
//

import SwiftUI
import SwiftData

@main
struct nyc_trackerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(LocalStore.shared)
    }
}
