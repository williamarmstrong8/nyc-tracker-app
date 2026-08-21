import SwiftUI
import PhotosUI
import MapKit
import UIKit

struct DetailsView: View {
    @Bindable var coordinator: CaptureCoordinator

    @State private var recorder: any RecorderProtocol = SpeechRecorder()
    @State private var showTagPeople = false
    @FocusState private var focusedField: Field?

    enum Field: Hashable { case note }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                photoStrip

                TagPeopleField(tagged: coordinator.taggedPeople) {
                    showTagPeople = true
                }

                LocationSearchField(
                    nameInput: $coordinator.nameInput,
                    addressInput: $coordinator.addressInput,
                    selectedVenue: $coordinator.preselectedVenue
                )
                .zIndex(10)

                noteSection

                VenueTagField(selection: $coordinator.draftTags)

                RatingField(rating: $coordinator.draftRating)

                VisitDateField(date: $coordinator.visitedOn)

                submitButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .navigationTitle("New Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .keyboard) {
                Button("Done") {
                    focusedField = nil
                    // LocationSearchField owns its own FocusState, so this is
                    // the only way "Done" can also dismiss that field's keyboard.
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .sheet(isPresented: $showTagPeople) {
            TagPeoplePicker(initialSelection: coordinator.taggedPeople) { picked in
                coordinator.taggedPeople = picked
            }
        }
    }

    // MARK: - Sections

    private var photoStrip: some View {
        ReorderablePhotoStrip(
            items: $coordinator.selectedItems,
            thumbnailWidth: 140,
            thumbnailHeight: 140 * 4 / 3,
            cornerRadius: 16
        )
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Dictating fills this in, but it's an ordinary text field — typing
            // here instead of (or on top of) recording is equally valid input,
            // and either way the text is saved exactly as it reads.
            LabeledField(
                title: "Description",
                text: $coordinator.note,
                placeholder: "Record below, or type what you want to remember about this place…",
                axis: .vertical,
                lineLimit: 3...10
            )
            .focused($focusedField, equals: .note)

            // Appended, not assigned: the field is now the entry's description,
            // and the user may well have typed into it before reaching for the
            // mic. Silently replacing that is the one thing dictation must not do.
            HoldToRecordButton(recorder: recorder, hasRecording: coordinator.hadVoiceNote) { result in
                let spoken = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !spoken.isEmpty {
                    coordinator.note = coordinator.note.isEmpty ? spoken : "\(coordinator.note)\n\n\(spoken)"
                }
                coordinator.hadVoiceNote = result.hadRecording
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var submitButton: some View {
        Button {
            Haptics.tap()
            Task { await coordinator.submitDetails() }
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

