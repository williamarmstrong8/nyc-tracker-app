import SwiftUI

/// Find people and manage friend requests.
///
/// Presented as a sheet with its own `NavigationStack`, same as the map search
/// popup. `.searchable` on a pushed destination is installed after the
/// transition, so the field's background paints a beat late; a sheet's search
/// chrome exists on the first frame, over an already-black presentation
/// background.
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
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .presentationBackground(Color(uiColor: .systemBackground))
    }
}
