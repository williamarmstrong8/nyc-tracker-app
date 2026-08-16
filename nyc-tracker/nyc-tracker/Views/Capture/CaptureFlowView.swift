import SwiftUI
import SwiftData
import PhotosUI

/// Full-screen capture flow presented once the user has already picked photos from the library.
/// Stages: details → processing → (venue picker) → write-up.
struct CaptureFlowView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var coordinator: CaptureCoordinator
    let enricher: EnricherProtocol
    var onConfirmedVisit: (Visit) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()

                switch coordinator.stage {
                case .details:
                    DetailsView(coordinator: coordinator, enricher: enricher)
                case .processing:
                    ProcessingOverlay()
                case .venuePicker:
                    VenuePickerView(
                        candidates: coordinator.venueCandidates,
                        biasCoordinate: coordinator.resolvedCoordinate
                    ) { picked in
                        coordinator.applyVenue(picked)
                    }
                case .writeUp:
                    WriteUpView(
                        coordinator: coordinator,
                        onConfirm: {
                            Task {
                                let repository = VisitRepository(context: modelContext)
                                let visit = await coordinator.confirm(using: repository)
                                onConfirmedVisit(visit)
                            }
                        }
                    )
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
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
            Text("Enriching…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}
