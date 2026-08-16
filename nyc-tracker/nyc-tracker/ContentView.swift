//
//  ContentView.swift
//  nyc-tracker
//

import SwiftUI
import SwiftData
import PhotosUI

struct ContentView: View {
    @State private var activeTab: AppTab = .home
    @State private var homeMode: HomeMode = .map
    @State private var openedVisit: Visit?
    @State private var mapFocusVisitID: Visit.ID?

    @State private var captureCoordinator = CaptureCoordinator()
    @State private var filter = EntryFilter()

    /// Bindings that drive the "log a visit" and "want to try" entry points.
    @State private var showPhotosPicker = false
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var showWantToTry = false

    private let enricher: EnricherProtocol = FoundationModelsEnricher()

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch activeTab {
                case .home:
                    HomeView(mode: $homeMode, openedVisit: $openedVisit, focusVisitID: $mapFocusVisitID, filter: filter)
                case .discover:
                    DiscoverView()
                case .friends:
                    FriendsView()
                case .profile:
                    ProfileView()
                }
            }

            BottomNavBar(
                activeTab: activeTab,
                onMap: {
                    activeTab = .home
                    homeMode = .map
                },
                onDiscover: { activeTab = .discover },
                onFriends: { activeTab = .friends },
                onLogVisit: {
                    pickerSelection = []
                    showPhotosPicker = true
                },
                onWantToTry: { showWantToTry = true },
                onProfile: { activeTab = .profile }
            )
        }
        // Photos picker sheet fires directly — no more placeholder screen in front of it.
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $pickerSelection,
            maxSelectionCount: 8,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: showPhotosPicker) { _, isShown in
            // When the picker closes with photos selected, start the capture flow.
            guard !isShown else { return }
            if !pickerSelection.isEmpty {
                captureCoordinator.begin(with: pickerSelection)
                pickerSelection = []
            }
        }
        .fullScreenCover(isPresented: bindingForCapture()) {
            CaptureFlowView(
                coordinator: captureCoordinator,
                enricher: enricher,
                onConfirmedVisit: { visit in
                    openedVisit = nil
                    activeTab = .home
                    homeMode = .map
                    mapFocusVisitID = visit.id
                }
            )
        }
        .sheet(isPresented: $showWantToTry) {
            WantToTryView()
        }
        .sheet(item: $openedVisit) { visit in
            NavigationStack {
                ReadOnlyWriteUpView(
                    visit: visit,
                    onDismiss: { openedVisit = nil },
                    onShowOnMap: {
                        let id = visit.id
                        openedVisit = nil
                        activeTab = .home
                        homeMode = .map
                        mapFocusVisitID = id
                    }
                )
            }
        }
    }

    private func bindingForCapture() -> Binding<Bool> {
        Binding(
            get: { captureCoordinator.isPresented },
            set: { captureCoordinator.isPresented = $0 }
        )
    }
}

#Preview {
    ContentView()
        .modelContainer(LocalStore.shared)
}
