import SwiftUI
import SwiftData

/// Edit a Visit that's already been saved to SwiftData. Bound directly to the model, so autosave
/// keeps changes without needing an explicit repository call.
struct EditPersistedVisitView: View {
    @Bindable var visit: Visit
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncEngine.self) private var sync
    @Environment(\.dismiss) private var dismiss

    @State private var tagsText: String = ""

    var body: some View {
        Form {
            Section("Title") {
                TextField("Title", text: $visit.title)
            }

            Section("Description") {
                TextField("Description", text: $visit.enrichedDescription, axis: .vertical)
                    .lineLimit(5...20)
            }

            Section("Top quote") {
                TextField("Pull quote", text: $visit.topQuote, axis: .vertical)
                    .lineLimit(1...4)
            }

            Section("Tags") {
                TextField("comma separated", text: $tagsText)
                    .onAppear { tagsText = visit.tags.joined(separator: ", ") }
                    .onChange(of: tagsText) { _, newValue in
                        visit.tags = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }
            }

            Section("Address / Name") {
                TextField(
                    "Address",
                    text: Binding(get: { visit.address ?? "" }, set: { visit.address = $0.isEmpty ? nil : $0 })
                )
                TextField(
                    "Name override",
                    text: Binding(get: { visit.nameOverride ?? "" }, set: { visit.nameOverride = $0.isEmpty ? nil : $0 })
                )
            }

            Section("Rating") {
                Picker("Rating", selection: bindingForRating()) {
                    Text("None").tag(Optional<Rating>.none)
                    ForEach(Rating.allCases) { rating in
                        Text(rating.label).tag(Optional(rating))
                    }
                }
                .pickerStyle(.segmented)

                Picker("Return", selection: bindingForReturnIntent()) {
                    Text("None").tag(Optional<ReturnIntent>.none)
                    ForEach(ReturnIntent.allCases) { intent in
                        Text(intent.label).tag(Optional(intent))
                    }
                }
            }

            Section("Kind") {
                Picker("Kind", selection: bindingForKind()) {
                    ForEach(VisitKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            }

            if !visit.transcript.isEmpty {
                Section("Transcript (verbatim)") {
                    TextField("Transcript", text: $visit.transcript, axis: .vertical)
                        .lineLimit(4...20)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Haptics.tap()
                    // `saveEdit` rather than `context.save()`: an edit that is
                    // persisted but not re-queued looks correct on this device
                    // forever and simply never reaches any other one.
                    VisitRepository(context: modelContext).saveEdit(to: visit)
                    sync.requestSync(reason: .newLocalWrite)
                    dismiss()
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    modelContext.rollback()
                    dismiss()
                }
            }
        }
    }

    private func bindingForRating() -> Binding<Rating?> {
        Binding(get: { visit.rating }, set: { visit.rating = $0 })
    }
    private func bindingForReturnIntent() -> Binding<ReturnIntent?> {
        Binding(get: { visit.returnIntent }, set: { visit.returnIntent = $0 })
    }
    private func bindingForKind() -> Binding<VisitKind> {
        Binding(get: { visit.kind }, set: { visit.kind = $0 })
    }
}
