import SwiftUI

/// What a relationship control can do.
enum RelationshipAction {
    case add
    case cancel
    case accept
    case decline
    case unfriend
}

/// The relationship-aware action control.
///
/// One component for every state a pair can be in, because the states are
/// mutually exclusive by the pair index and splitting them across call sites is
/// how you end up rendering "Add friend" next to "Accept". Search rows, the
/// friends list and the friend profile all use this, so the states can only
/// disagree in one place.
///
/// | State    | Control                                     |
/// |----------|---------------------------------------------|
/// | none     | Add friend                                  |
/// | outgoing | Requested — tap to cancel                   |
/// | incoming | Accept / Decline                            |
/// | friends  | Friends — tap to unfriend, with confirmation |
/// | self     | nothing                                     |
/// | blocked  | a non-interactive label                     |
///
/// Unfriending confirms and declining does not: unfriending discards a mutual
/// relationship and is only reachable by a deliberate tap on a button that says
/// "Friends", whereas declining is the expected response to an unwanted request
/// and a confirmation sheet on it is friction in the wrong place.
struct RelationshipButton: View {
    let person: PersonSummary
    let relationship: RelationshipState
    /// True while a mutation for this person is in flight.
    var isBusy: Bool = false
    /// Compact styling for list rows; full-width for profile headers.
    var isCompact: Bool = true
    var perform: (RelationshipAction) -> Void

    @State private var confirmingUnfriend = false

    var body: some View {
        Group {
            switch relationship {
            case .isSelf:
                EmptyView()

            case .blocked:
                Text("Blocked")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

            case .none:
                action("Add friend", symbol: "person.badge.plus", prominent: true) {
                    perform(.add)
                }

            case .outgoing:
                action("Requested", symbol: "clock", prominent: false) {
                    perform(.cancel)
                }
                .accessibilityHint("Cancels your request")

            case .incoming:
                if isCompact {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            compactGlassIcon(
                                "checkmark",
                                prominent: true,
                                accessibilityLabel: "Accept"
                            ) {
                                perform(.accept)
                            }
                            compactGlassIcon(
                                "xmark",
                                prominent: false,
                                accessibilityLabel: "Decline"
                            ) {
                                perform(.decline)
                            }
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        action("Accept", symbol: "checkmark", prominent: true) {
                            perform(.accept)
                        }
                        action("Decline", symbol: "xmark", prominent: false) {
                            perform(.decline)
                        }
                    }
                }

            case .friends:
                action("Friends", symbol: "person.fill.checkmark", prominent: false) {
                    confirmingUnfriend = true
                }
                .accessibilityHint("Removes \(person.bestName) from your friends")
            }
        }
        .confirmationDialog(
            "Remove \(person.bestName) from your friends?",
            isPresented: $confirmingUnfriend,
            titleVisibility: .visible
        ) {
            Button("Remove friend", role: .destructive) { perform(.unfriend) }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Says what actually happens, because both halves surprise people:
            // it is silent, and it is not a block.
            Text("Their places disappear from your map. They aren't notified.")
        }
    }

    @ViewBuilder
    private func action(
        _ title: String,
        symbol: String,
        prominent: Bool,
        handler: @escaping () -> Void
    ) -> some View {
        let button = Button {
            Haptics.tap()
            handler()
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.titleOnly)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: isCompact ? nil : .infinity, minHeight: isCompact ? 32 : 44)
                .opacity(isBusy ? 0 : 1)
                .overlay {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    }
                }
        }
        .disabled(isBusy)

        if prominent {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }

    /// Compact circular glass icon for the list-row accept/decline pair.
    @ViewBuilder
    private func compactGlassIcon(
        _ symbol: String,
        prominent: Bool,
        accessibilityLabel: String,
        handler: @escaping () -> Void
    ) -> some View {
        let button = Button {
            Haptics.tap()
            handler()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .opacity(isBusy ? 0 : 1)
                .overlay {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    }
                }
        }
        .disabled(isBusy)
        .accessibilityLabel(accessibilityLabel)

        if prominent {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }
}
