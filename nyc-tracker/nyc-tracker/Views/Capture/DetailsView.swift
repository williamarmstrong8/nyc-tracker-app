import SwiftUI
import PhotosUI

struct DetailsView: View {
    @Bindable var coordinator: CaptureCoordinator
    let enricher: EnricherProtocol

    @State private var recorder: any RecorderProtocol = SpeechRecorder()
    @FocusState private var focusedField: Field?

    enum Field: Hashable { case address, name, tags }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                photoStrip

                voiceMemoSection

                fieldsSection

                submitButton

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .navigationTitle("New Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .keyboard) {
                Button("Done") { focusedField = nil }
            }
        }
        .task {
            // Prewarm the on-device model so the first submit is snappier.
            await enricher.prewarm()
        }
    }

    // MARK: - Sections

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(coordinator.selectedItems, id: \.itemIdentifier) { item in
                    PhotoView(source: .pickerItem(item), contentMode: .fill)
                        .frame(width: 140, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private var voiceMemoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HoldToRecordButton(recorder: recorder, hasRecording: !coordinator.transcript.isEmpty) { result in
                coordinator.transcript = result.transcript
                coordinator.hadVoiceNote = result.hadRecording
            }
            .frame(maxWidth: .infinity, alignment: coordinator.transcript.isEmpty ? .leading : .center)

            if !coordinator.transcript.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transcript")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(coordinator.transcript)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(uiColor: .secondarySystemBackground))
                        )
                }
            }
        }
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledField(title: "Name (optional)", text: $coordinator.nameInput,
                         placeholder: "e.g. Lucali")
                .focused($focusedField, equals: .name)

            LabeledField(title: "Address (optional)", text: $coordinator.addressInput,
                         placeholder: "e.g. 575 Henry St, Brooklyn")
                .focused($focusedField, equals: .address)

            LabeledField(title: "Tags (comma separated, optional)",
                         text: $coordinator.tagsInput,
                         placeholder: "pizza, date night")
                .focused($focusedField, equals: .tags)
        }
    }

    private var submitButton: some View {
        Button {
            Haptics.tap()
            Task { await coordinator.submitDetails(using: enricher) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                Text("Submit")
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.glassProminent)
    }
}


