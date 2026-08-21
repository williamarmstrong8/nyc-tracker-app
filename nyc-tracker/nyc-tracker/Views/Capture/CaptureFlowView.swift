import SwiftUI
import SwiftData
import PhotosUI

/// Full-screen capture flow presented once the user has already picked photos from the library.
/// Stages: details → processing → (venue picker) → save.
struct CaptureFlowView: View {
    let userID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(SyncEngine.self) private var sync
    @Bindable var coordinator: CaptureCoordinator
    var onConfirmedVisit: (Visit) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()

                switch coordinator.stage {
                case .details:
                    DetailsView(coordinator: coordinator)
                case .processing:
                    ProcessingOverlay(message: "Finding place…")
                case .venuePicker:
                    VenuePickerView(
                        candidates: coordinator.venueCandidates,
                        biasCoordinate: coordinator.resolvedCoordinate,
                        typedName: coordinator.nameInput.isEmpty ? nil : coordinator.nameInput
                    ) { picked in
                        coordinator.applyVenue(picked)
                    }
                case .saving:
                    ProcessingOverlay(message: "Saving…")
                        .task {
                            let repository = VisitRepository(context: modelContext, userID: userID)
                            let visit = await coordinator.confirm(using: repository)
                            onConfirmedVisit(visit)
                            // Confirm already returned and the map is showing
                            // the new pin; this just wakes the queue. Nothing
                            // above it awaited the network.
                            sync.requestSync(reason: .newLocalWrite)
                        }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        coordinator.isPresented = false
                    }
                }
            }
        }
    }
}

// MARK: - Processing overlay

struct ProcessingOverlay: View {
    var message: String = "Finding place…"

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
            Text(message)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}
