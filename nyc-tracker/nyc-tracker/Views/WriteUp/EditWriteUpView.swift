import SwiftUI

struct EditWriteUpView: View {
    @Bindable var coordinator: CaptureCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var tagsText: String = ""

    var body: some View {
        Form {
            Section("Title") {
                TextField("Title", text: $coordinator.draftTitle)
            }

            Section("Description") {
                TextField("Description", text: $coordinator.draftDescription, axis: .vertical)
                    .lineLimit(5...20)
            }

            Section("Top quote") {
                TextField("Pull quote", text: $coordinator.draftTopQuote, axis: .vertical)
                    .lineLimit(1...4)
            }

            Section("Tags") {
                TextField("comma separated", text: $tagsText)
                    .onAppear { tagsText = coordinator.draftTags.joined(separator: ", ") }
                    .onChange(of: tagsText) { _, newValue in
                        coordinator.draftTags = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }
            }

            Section("Address / Name") {
                TextField("Address", text: $coordinator.addressInput)
                TextField("Name override", text: $coordinator.nameInput)
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

            Section("Transcript (verbatim)") {
                TextField("Transcript", text: $coordinator.transcript, axis: .vertical)
                    .lineLimit(4...20)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Haptics.tap()
                    dismiss()
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func bindingForRating() -> Binding<Rating?> {
        Binding(get: { coordinator.draftRating }, set: { coordinator.draftRating = $0 })
    }

    private func bindingForReturnIntent() -> Binding<ReturnIntent?> {
        Binding(get: { coordinator.draftReturnIntent }, set: { coordinator.draftReturnIntent = $0 })
    }
}
