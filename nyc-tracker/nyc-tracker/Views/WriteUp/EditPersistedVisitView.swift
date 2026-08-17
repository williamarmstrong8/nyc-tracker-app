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
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case title, description, quote, tags, address, name, transcript
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LabeledField(title: "Title", text: $visit.title, placeholder: "Title")
                    .focused($focusedField, equals: .title)

                LabeledField(
                    title: "Description",
                    text: $visit.enrichedDescription,
                    placeholder: "Description",
                    axis: .vertical,
                    lineLimit: 5...20
                )
                .focused($focusedField, equals: .description)

                LabeledField(
                    title: "Top quote",
                    text: $visit.topQuote,
                    placeholder: "Pull quote",
                    axis: .vertical,
                    lineLimit: 1...4
                )
                .focused($focusedField, equals: .quote)

                LabeledField(title: "Tags", text: $tagsText, placeholder: "comma separated")
                    .focused($focusedField, equals: .tags)
                    .onAppear { tagsText = visit.tags.joined(separator: ", ") }
                    .onChange(of: tagsText) { _, newValue in
                        visit.tags = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }

                LabeledField(
                    title: "Address",
                    text: Binding(get: { visit.address ?? "" }, set: { visit.address = $0.isEmpty ? nil : $0 }),
                    placeholder: "Address"
                )
                .focused($focusedField, equals: .address)

                LabeledField(
                    title: "Name override",
                    text: Binding(get: { visit.nameOverride ?? "" }, set: { visit.nameOverride = $0.isEmpty ? nil : $0 }),
                    placeholder: "Name override"
                )
                .focused($focusedField, equals: .name)

                if let place = visit.place {
                    VStack(alignment: .leading, spacing: 8) {
                        labeledMenu("Type") {
                            Picker("Type", selection: bindingForCategory(of: place)) {
                                ForEach(PlaceCategory.allCases, id: \.self) { category in
                                    Text(category.rawValue.capitalized).tag(category)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .tint(.primary)
                        }
                        Text("Fix it here if Apple mistagged this venue — for example a restaurant that shows up as a cafe.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Rating")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Rating", selection: bindingForRating()) {
                        Text("None").tag(Optional<Rating>.none)
                        ForEach(Rating.allCases) { rating in
                            Text(rating.label).tag(Optional(rating))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                labeledMenu("Return") {
                    Picker("Return", selection: bindingForReturnIntent()) {
                        Text("None").tag(Optional<ReturnIntent>.none)
                        ForEach(ReturnIntent.allCases) { intent in
                            Text(intent.label).tag(Optional(intent))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(.primary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Kind")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Kind", selection: bindingForKind()) {
                        ForEach(VisitKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if !visit.transcript.isEmpty {
                    LabeledField(
                        title: "Transcript (verbatim)",
                        text: $visit.transcript,
                        placeholder: "Transcript",
                        axis: .vertical,
                        lineLimit: 4...20
                    )
                    .foregroundStyle(.secondary)
                    .focused($focusedField, equals: .transcript)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.black)
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarBackgroundVisibility(.visible, for: .navigationBar)
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
            ToolbarItem(placement: .keyboard) {
                Button("Done") { focusedField = nil }
            }
        }
    }

    private func labeledMenu<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
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
    private func bindingForCategory(of place: Place) -> Binding<PlaceCategory> {
        Binding(get: { place.category }, set: { place.correctCategory(to: $0) })
    }
}
