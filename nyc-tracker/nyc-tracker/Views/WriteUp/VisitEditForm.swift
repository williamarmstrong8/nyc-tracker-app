import SwiftUI
import PhotosUI
import UIKit

/// Every editable field on an entry, in one place.
///
/// Bound by `EditPersistedVisitView`. Passing bindings in means the form itself
/// never decides where to save.
///
/// Optional bindings are the fields a given screen genuinely doesn't have:
/// `category` needs a resolved place, and only a saved entry can be moved
/// between visited and want-to-try.
struct VisitEditForm: View {
    @Binding var title: String
    @Binding var note: String
    @Binding var tags: [String]
    @Binding var rating: Rating?
    @Binding var visitedOn: Date
    @Binding var address: String
    @Binding var nameOverride: String
    var category: Binding<PlaceCategory>?
    var kind: Binding<VisitKind>?

    /// The entry's photos, already in display order. Deletion, reordering and
    /// ingestion are handed back through closures rather than a `Binding`
    /// because the two callers hold genuinely different photo types
    /// underneath — see `EditablePhotoStrip`.
    var photoSources: [PhotoView.Source]
    var onDeletePhoto: (Int) -> Void
    var onMovePhoto: (IndexSet, Int) -> Void
    var onAddPhotos: ([PhotosPickerItem]) -> Void

    var taggedPeople: [PersonSummary]
    var onEditTaggedPeople: () -> Void

    @State private var selectedVenue: VenueCandidate?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case note
    }

    /// A want-to-try has no verdict — the whole point is that nobody has been
    /// yet. Read through the binding so flipping the kind below updates this in
    /// place instead of on the next present.
    private var showsRating: Bool {
        (kind?.wrappedValue ?? .visited) == .visited
    }

    /// The location search field doubles as the entry's headline. This used to
    /// be three separate fields — title, address, name override — kept in sync
    /// by hand; now it's one field, exactly like the capture flow's
    /// `DetailsView`, and typed or picked text still falls straight through to
    /// both `title` and `nameOverride` the way it always has.
    private var locationNameBinding: Binding<String> {
        Binding(
            get: { title },
            set: { newValue in
                title = newValue
                nameOverride = newValue
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                EditablePhotoStrip(
                    sources: photoSources,
                    thumbnailWidth: 140,
                    thumbnailHeight: 140 * 4 / 3,
                    cornerRadius: 16,
                    onDelete: onDeletePhoto,
                    onMove: onMovePhoto,
                    onAdd: onAddPhotos
                )

                LocationSearchField(
                    nameInput: locationNameBinding,
                    addressInput: $address,
                    selectedVenue: $selectedVenue
                )
                .zIndex(10)

                LabeledField(
                    title: "Description",
                    text: $note,
                    placeholder: "What do you want to remember about this place?",
                    axis: .vertical,
                    lineLimit: 5...20
                )
                .focused($focusedField, equals: .note)

                VenueTagField(selection: $tags)

                if showsRating {
                    RatingField(rating: $rating)
                }

                VisitDateField(date: $visitedOn)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Tagged")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TagPeopleField(tagged: taggedPeople, onTap: onEditTaggedPeople)
                }

                if let category {
                    VStack(alignment: .leading, spacing: 8) {
                        labeledMenu("Type") {
                            Picker("Type", selection: category) {
                                ForEach(PlaceCategory.allCases, id: \.self) { option in
                                    Text(option.rawValue.capitalized).tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .tint(.primary)
                        }
                        Text("Set from Apple Maps. Fix it here if it came back wrong — a restaurant that shows up as a cafe.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let kind {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Kind")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Picker("Kind", selection: kind) {
                            ForEach(VisitKind.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .keyboard) {
                Button("Done") {
                    focusedField = nil
                    // LocationSearchField owns its own FocusState, so this is
                    // the only way "Done" can also dismiss its keyboard.
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
    }

    private func labeledMenu<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
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
}
