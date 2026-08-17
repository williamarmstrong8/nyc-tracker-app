import SwiftUI

struct EditWriteUpView: View {
    @Bindable var coordinator: CaptureCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var tagsText: String = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case title, description, quote, tags, address, name, transcript
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LabeledField(title: "Title", text: $coordinator.draftTitle, placeholder: "Title")
                    .focused($focusedField, equals: .title)

                LabeledField(
                    title: "Description",
                    text: $coordinator.draftDescription,
                    placeholder: "Description",
                    axis: .vertical,
                    lineLimit: 5...20
                )
                .focused($focusedField, equals: .description)

                LabeledField(
                    title: "Top quote",
                    text: $coordinator.draftTopQuote,
                    placeholder: "Pull quote",
                    axis: .vertical,
                    lineLimit: 1...4
                )
                .focused($focusedField, equals: .quote)

                LabeledField(title: "Tags", text: $tagsText, placeholder: "comma separated")
                    .focused($focusedField, equals: .tags)
                    .onAppear { tagsText = coordinator.draftTags.joined(separator: ", ") }
                    .onChange(of: tagsText) { _, newValue in
                        coordinator.draftTags = newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                    }

                LabeledField(title: "Address", text: $coordinator.addressInput, placeholder: "Address")
                    .focused($focusedField, equals: .address)

                LabeledField(title: "Name override", text: $coordinator.nameInput, placeholder: "Name override")
                    .focused($focusedField, equals: .name)

                VStack(alignment: .leading, spacing: 8) {
                    labeledMenu("Type") {
                        Picker("Type", selection: $coordinator.draftCategory) {
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

                LabeledField(
                    title: "Transcript (verbatim)",
                    text: $coordinator.transcript,
                    placeholder: "Transcript",
                    axis: .vertical,
                    lineLimit: 4...20
                )
                .foregroundStyle(.secondary)
                .focused($focusedField, equals: .transcript)
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
                    dismiss()
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
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
        Binding(get: { coordinator.draftRating }, set: { coordinator.draftRating = $0 })
    }

    private func bindingForReturnIntent() -> Binding<ReturnIntent?> {
        Binding(get: { coordinator.draftReturnIntent }, set: { coordinator.draftReturnIntent = $0 })
    }
}
