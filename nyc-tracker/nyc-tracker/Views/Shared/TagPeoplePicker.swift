import Foundation
import SwiftUI

/// "Who were you with?" — multi-select over the signed-in user's friends.
///
/// Friends only, and that is a server rule this sheet merely reflects: the
/// insert policy on `visit_tags` refuses a tag naming anyone the author is not
/// accepted friends with. Offering user search here would build a picker whose
/// results mostly 403 on save.
///
/// Selection is committed on Done rather than live, so backing out of the sheet
/// leaves the entry as it was.
struct TagPeoplePicker: View {
    /// Already-tagged people, in the author's order.
    let initialSelection: [PersonSummary]
    var onDone: ([PersonSummary]) -> Void

    @Environment(SocialGraph.self) private var graph
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIDs: [UUID] = []
    @State private var query = ""

    private var friends: [PersonSummary] {
        graph.friends.map(\.person)
    }

    private var filtered: [PersonSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return friends }
        return friends.filter { person in
            person.bestName.lowercased().contains(trimmed)
                || (person.username?.lowercased().contains(trimmed) ?? false)
        }
    }

    /// Selected people in the order they were picked, which is the order they
    /// are shown in and stored with. Rebuilt from `selectedIDs` rather than kept
    /// as a second array so there is one source of truth for the set.
    private var selectedPeople: [PersonSummary] {
        selectedIDs.compactMap { id in
            friends.first { $0.id == id }
                ?? initialSelection.first { $0.id == id }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if graph.friends.isEmpty {
                    noFriendsState
                } else {
                    list
                }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Tag people")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Haptics.tap()
                        onDone(selectedPeople)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: .systemBackground))
        .onAppear {
            // Seeded once. Re-seeding on every appear would discard the user's
            // taps if the sheet ever re-rendered mid-selection.
            if selectedIDs.isEmpty {
                selectedIDs = initialSelection.map(\.id)
            }
        }
    }

    // MARK: - List

    private var list: some View {
        List {
            if !selectedPeople.isEmpty {
                Section("Tagged") {
                    ForEach(selectedPeople) { person in
                        row(person)
                    }
                }
            }

            Section(selectedPeople.isEmpty ? "Friends" : "All friends") {
                if filtered.isEmpty {
                    Text("No friends match \u{201C}\(query)\u{201D}.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filtered) { person in
                        row(person)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search friends"
        )
    }

    private func row(_ person: PersonSummary) -> some View {
        let isSelected = selectedIDs.contains(person.id)

        return Button {
            Haptics.tap()
            toggle(person)
        } label: {
            HStack(spacing: 12) {
                PersonAvatar(person: person, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(person.bestName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let handle = person.handle {
                        Text(handle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func toggle(_ person: PersonSummary) {
        if let index = selectedIDs.firstIndex(of: person.id) {
            selectedIDs.remove(at: index)
        } else {
            selectedIDs.append(person.id)
        }
    }

    // MARK: - Empty state

    private var noFriendsState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("No friends to tag yet")
                .font(.headline)
            Text("You can tag anyone you're friends with. Add a few from the Friends tab.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The "Tag people" button used by the capture flow and both edit screens.
///
/// Shared so the three of them cannot describe the same action three ways —
/// and so the summary line under it (who is currently tagged) is written once.
struct TagPeopleField: View {
    let tagged: [PersonSummary]
    var onTap: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            onTap()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.2")
                Text(tagged.isEmpty ? "Tag people (optional)" : summary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(tagged.isEmpty ? "Tag people" : "Tagged: \(summary)")
    }

    private var summary: String {
        let names = tagged.map(\.shortName)
        switch names.count {
        case 0:  return "Tag people (optional)"
        case 1:  return "With \(names[0])"
        case 2:  return "With \(names[0]) and \(names[1])"
        default: return "With \(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
}
