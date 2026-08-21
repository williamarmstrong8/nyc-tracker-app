import SwiftUI

/// Find people and manage friend requests.
///
/// Presented as a full-screen cover with its own `NavigationStack` so it
/// slides up from the bottom like a modal while filling the screen. `.searchable`
/// on a pushed destination is installed after the transition, so the field's
/// background paints a beat late; a cover that owns its stack presents the
/// search chrome on the first frame.
struct AddFriendsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            UserSearchView(query: $query)
                .background(Color(uiColor: .systemBackground))
                .navigationTitle("Add friends")
                .navigationBarTitleDisplayMode(.inline)
                .appSearchable(text: $query, prompt: "Name or username")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            Haptics.tap()
                            dismiss()
                        }
                    }
                }
        }
        .background(Color(uiColor: .systemBackground))
    }
}
