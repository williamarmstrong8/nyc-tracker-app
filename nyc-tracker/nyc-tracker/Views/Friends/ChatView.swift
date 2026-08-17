import SwiftUI
import SwiftData

/// Route to a chat.
///
/// A wrapper rather than pushing `PersonSummary` directly, because that value
/// already means "show me this person's profile" — it is what a search result
/// and a request row push, and both of those are people you are not messaging
/// yet. Two meanings for one route type would send Add-friends taps into a
/// conversation with a stranger.
struct ChatRoute: Hashable {
    let person: PersonSummary
}

/// A direct-message thread with one friend.
///
/// The friends list used to open a profile; it opens this instead. The profile
/// is still one tap away — the header is a link to it — because "who is this
/// person" is a question you ask occasionally and "what have we said" is one you
/// ask every time.
///
/// ## A text field, with a place as an optional attachment
///
/// The composer is an ordinary text field. A pin button beside it opens the
/// picker; picking a place attaches it above the field as a chip instead of
/// sending immediately, so the note and the venue travel together in one
/// message the way `send_message` expects. A message needs no place at all —
/// this is still a chat, not only a place-sharing tool.
struct ChatView: View {
    let userID: UUID
    let person: PersonSummary

    @Environment(ChatStore.self) private var chat
    @Environment(FriendVisitCache.self) private var friendCache
    @Environment(FeedStore.self) private var feed
    @Environment(SocialDemoMode.self) private var demo
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext

    @State private var conversationID: UUID?
    @State private var loadState: LoadState = .loading
    @State private var isSending = false
    @State private var showPicker = false
    @State private var openedMessagePlace: ChatPlaceOpen?
    @State private var messageText = ""
    @State private var attachedPlace: PickedChatPlace?
    /// Bumped after a successful send so the thread scrolls once the composer
    /// has cleared, not only when the message row first appears.
    @State private var scrollRequest = 0
    @FocusState private var isComposing: Bool

    /// Matches the `messages_body_length` CHECK. The database is the
    /// guarantee; this stops someone writing 3,000 characters and only
    /// finding out on send.
    private static let maxMessageLength = 2000
    /// False once a backwards page comes back empty, so the button stops
    /// offering history that isn't there.
    @State private var hasOlderMessages = true
    @State private var isLoadingOlder = false

    /// How far the thread is dragged left, revealing the send times.
    ///
    /// `@GestureState` rather than `@State`: it resets itself the instant the
    /// finger lifts, which is exactly the behaviour — the timestamps are
    /// something you hold open to read, not a mode you toggle into.
    @GestureState private var timeReveal: CGFloat = 0

    private static let timeRevealWidth: CGFloat = 62
    /// Stable id for the thread's trailing edge. Scrolling here, rather than
    /// to a message that LazyVStack may not have materialized, is what keeps
    /// a just-sent bubble on screen.
    private static let threadBottomID = "chat-thread-bottom"

    private enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// What tapping a place card in the thread resolves to — one entry, never
    /// the multi-visit place sheet. See `openMessagePlace(_:)`.
    private enum ChatPlaceOpen: Identifiable {
        case ownVisit(Visit)
        case friendVisit(FriendVisit)

        var id: String {
            switch self {
            case .ownVisit(let visit): "own-\(visit.id)"
            case .friendVisit(let visit): "friend-\(visit.id)"
            }
        }
    }

    private var messages: [ChatMessage] {
        guard let conversationID else { return [] }
        return chat.messages(in: conversationID)
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading where messages.isEmpty:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message) where messages.isEmpty:
                failureState(message)
            default:
                thread
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(person.bestName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { router.hidesBottomBar = true }
        .toolbar {
            ToolbarItem(placement: .principal) {
                // The one route to the profile. A link rather than a menu item
                // because tapping someone's name and photo is already how you
                // expect to get to them.
                NavigationLink(value: person) {
                    HStack(spacing: 8) {
                        PersonAvatar(person: person, size: 30)
                        Text(person.bestName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(person.bestName), open profile")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .task(id: person.id) { await open() }
        .onDisappear {
            chat.setActiveConversation(nil)
            router.hidesBottomBar = false
        }
        .sheet(isPresented: $showPicker) {
            SharePlacePicker(userID: userID, recipient: person) { picked in
                attachedPlace = picked
                isComposing = true
            }
        }
        .sheet(item: $openedMessagePlace) { opened in
            messagePlaceSheet(opened)
        }
    }

    /// One person's entry, not the whole place — always the same full-screen,
    /// dark write-up used for your own pins on the map: full-width photos,
    /// title, tags, description, everything. Only the source of truth differs
    /// — your own `Visit` or their `FriendVisit` — the presentation doesn't.
    @ViewBuilder
    private func messagePlaceSheet(_ opened: ChatPlaceOpen) -> some View {
        switch opened {
        case .ownVisit(let visit):
            NavigationStack {
                ReadOnlyWriteUpView(
                    visit: visit,
                    onDismiss: { openedMessagePlace = nil },
                    onShowOnMap: {
                        openedMessagePlace = nil
                        router.showMap()
                    }
                )
                .toolbarBackground(.black, for: .navigationBar)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            }
            .preferredColorScheme(.dark)
            .presentationBackground(.black)

        case .friendVisit(let visit):
            NavigationStack {
                FriendVisitWriteUpView(
                    visit: visit,
                    onDismiss: { openedMessagePlace = nil },
                    onShowOnMap: {
                        openedMessagePlace = nil
                        router.showMap()
                    }
                )
                .toolbarBackground(.black, for: .navigationBar)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            }
            .preferredColorScheme(.dark)
            .presentationBackground(.black)
        }
    }

    // MARK: - Thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if hasOlderMessages && messages.count >= 20 {
                        loadOlderButton
                    }

                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if let separator = daySeparator(at: index) {
                            Text(separator)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 6)
                        }

                        ChatMessageRow(
                            message: message,
                            isMine: message.senderID == userID,
                            onOpenPlace: { tappedMessage in
                                Haptics.tap()
                                openMessagePlace(tappedMessage)
                            }
                        )
                        // Parked just off the right edge, so it is only visible
                        // while the thread is dragged left.
                        .overlay(alignment: .trailing) {
                            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .frame(width: Self.timeRevealWidth - 8, alignment: .leading)
                                // Parked one full reveal PLUS the row's own
                                // padding to the right, so nothing peeks past
                                // the screen edge at rest and the label lands
                                // clear of it when the drag bottoms out.
                                .offset(x: Self.timeRevealWidth + 16)
                                // Read out with the message instead of as a
                                // separate element nobody can reach by swiping.
                                .accessibilityHidden(true)
                        }
                        .accessibilityValue(
                            Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                        )
                        .id(message.id)
                    }

                    if messages.isEmpty && loadState == .ready {
                        emptyState
                    }

                    // Trailing edge of the thread. Scrolling here, rather than
                    // to a message that LazyVStack may not have materialized,
                    // is what keeps a just-sent bubble on screen.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.threadBottomID)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
                // The whole thread slides, timestamps included — they ride in
                // from the right as the messages leave, which is what makes the
                // gesture read as one surface rather than two.
                .offset(x: timeReveal)
                .animation(.interactiveSpring(duration: 0.25), value: timeReveal)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            // Simultaneous, not exclusive: the vertical scroll has to keep
            // working, and the guard below hands any mostly-vertical drag back
            // to it untouched. `@GestureState` is what snaps the thread home on
            // release without a second animation to write.
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .updating($timeReveal) { value, state, _ in
                        guard abs(value.translation.width) > abs(value.translation.height) else {
                            return
                        }
                        // Left only, and never past the width of the labels —
                        // dragging right would expose empty space beside the
                        // messages for no reason.
                        state = max(-Self.timeRevealWidth, min(0, value.translation.width))
                    }
            )
            .refreshable { await reload() }
            // A thread is read from the bottom. Any new message — sent or
            // received — brings the view back to it. Keyed on the last id so
            // paging older messages (which only changes count) stays put.
            .onChange(of: messages.last?.id) { _, newest in
                guard newest != nil else { return }
                scrollToLatest(proxy)
            }
            .onChange(of: scrollRequest) { _, _ in
                scrollToLatest(proxy)
            }
        }
    }

    /// Wait a frame so the new row has laid out, then pin the thread to its
    /// trailing edge. Immediate `scrollTo` on send often runs before the
    /// bubble exists in the lazy stack, so nothing moves. A second pass a
    /// moment later catches place-card photos that grow the row after load.
    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            withAnimation(.snappy) {
                proxy.scrollTo(Self.threadBottomID, anchor: .bottom)
            }
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.snappy) {
                proxy.scrollTo(Self.threadBottomID, anchor: .bottom)
            }
        }
    }

    private var loadOlderButton: some View {
        Button {
            Task { await loadOlder() }
        } label: {
            if isLoadingOlder {
                ProgressView().controlSize(.small)
            } else {
                Text("Load earlier messages")
                    .font(.caption.weight(.semibold))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text("No places sent yet")
                .font(.headline)
            Text("Send \(person.shortName) somewhere you've been and say why.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 80)
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("Couldn't open this conversation")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") {
                Task { await open() }
            }
            .buttonStyle(.glass)
            .padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Composer

    private var trimmedMessage: String {
        messageText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmedMessage.isEmpty && conversationID != nil && !isSending
    }

    /// One card, not several. The attached place and the send button both live
    /// inside the same glass surface as the text field — an attachment sitting
    /// in its own card above, or a send button floating beside it, would read
    /// as two controls doing one job. This is the whole composer: a single
    /// `glassEffect` surface, so there is no glass-on-glass to worry about
    /// even though it contains three interactive pieces.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let attachedPlace {
                attachmentRow(attachedPlace)
                Divider()
                    .padding(.horizontal, 14)
            }
            composerInputRow
        }
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// The place waiting to go out with the next message, as the top of the
    /// same card the text field sits in rather than a floating chip above it.
    private func attachmentRow(_ picked: PickedChatPlace) -> some View {
        HStack(spacing: 10) {
            Color.clear
                .frame(width: 40, height: 40)
                .overlay {
                    if let path = picked.preview.photoPath {
                        PhotoView(source: .friendPhoto(path: path), contentMode: .fill)
                    } else {
                        ZStack {
                            Color(uiColor: .tertiarySystemFill)
                            Image(systemName: "mappin")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(picked.preview.title ?? picked.preview.place.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = picked.preview.place.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Button {
                Haptics.tap()
                attachedPlace = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attached place")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// The pin, the field, and send — one row, plain buttons throughout
    /// because the card around them is already the glass surface.
    private var composerInputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                Haptics.tap()
                showPicker = true
            } label: {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background {
                        Circle()
                            .fill(Color(uiColor: .tertiarySystemFill))
                    }
            }
            .buttonStyle(.plain)
            .disabled(conversationID == nil)
            .accessibilityLabel("Attach a place")

            TextField(
                attachedPlace == nil ? "Message" : "Say something about it…",
                text: $messageText,
                axis: .vertical
            )
            .lineLimit(1...5)
            .focused($isComposing)
            .padding(.vertical, 6)
            .onChange(of: messageText) { _, new in
                if new.count > Self.maxMessageLength {
                    messageText = String(new.prefix(Self.maxMessageLength))
                }
            }

            Button {
                Haptics.tap()
                Task { await sendCurrentMessage() }
            } label: {
                if isSending {
                    ProgressView().controlSize(.small).frame(width: 30, height: 30)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 27))
                        .foregroundStyle(canSend ? Color.accentColor : Color(uiColor: .tertiaryLabel))
                        .frame(width: 30, height: 30)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Day separators

    /// A date line whenever the calendar day changes, and above the first
    /// message. Threads here are sparse — a few places a month — so without one
    /// every message reads as if it arrived today.
    private func daySeparator(at index: Int) -> String? {
        let message = messages[index]
        if index == 0 {
            return message.createdAt.formatted(.dateTime.weekday(.wide).month().day())
        }
        let previous = messages[index - 1].createdAt
        guard !Calendar.current.isDate(previous, inSameDayAs: message.createdAt) else {
            return nil
        }
        return message.createdAt.formatted(.dateTime.weekday(.wide).month().day())
    }

    // MARK: - Opening a place card

    /// Resolves the tapped card to one specific entry — never the aggregated
    /// place sheet — and opens it in whichever style matches its author: your
    /// own message opens your own write-up, theirs opens `FriendVisitDetailSheet`.
    private func openMessagePlace(_ message: ChatMessage) {
        guard let place = message.place else { return }

        if message.senderID == userID,
           let visitID = message.visitID,
           let visit = ownVisit(withID: visitID) {
            openedMessagePlace = .ownVisit(visit)
            return
        }

        if let visitID = message.visitID {
            let known = SocialPlaceVisits.collected(
                placeID: place.id,
                cache: friendCache,
                feed: feed,
                demo: demo
            )
            if let match = known.first(where: { $0.id == visitID }) {
                openedMessagePlace = .friendVisit(match)
                return
            }
        }

        // No local write-up and nothing already cached — fall back to what the
        // message itself carries. Enough for the card's fields even if the
        // full summary/quote/transcript weren't joined onto this row.
        openedMessagePlace = .friendVisit(FriendVisit(
            visitID: message.visitID ?? UUID(),
            visitedAt: message.createdAt,
            title: message.visitTitle,
            summary: nil,
            transcript: nil,
            topQuote: nil,
            tags: message.visitTags,
            ratingLabel: message.ratingLabel,
            returnIntent: nil,
            kind: "visited",
            placeID: place.id,
            placeName: place.name,
            placeCategory: place.categoryRaw,
            neighborhood: place.neighborhood,
            streetAddress: place.streetAddress,
            latitude: place.latitude,
            longitude: place.longitude,
            userID: message.senderID,
            username: message.username,
            displayName: message.displayName,
            avatarURL: message.avatarURL,
            photos: message.photos
        ))
    }

    private func ownVisit(withID id: UUID) -> Visit? {
        var descriptor = FetchDescriptor<Visit>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    // MARK: - Loading

    private func open() async {
        if conversationID == nil { loadState = .loading }

        guard let id = await chat.openConversation(with: person.id) else {
            loadState = .failed(
                chat.lastError?.message ?? "Something went wrong. Please try again."
            )
            return
        }

        conversationID = id
        chat.setActiveConversation(id)

        // Seeing a thread is reading it.
        chat.markRead(id)

        if await chat.loadMessages(in: id) {
            loadState = .ready
        } else {
            loadState = .failed(
                chat.lastError?.message ?? "Couldn't load these messages."
            )
        }
    }

    private func reload() async {
        guard let conversationID else {
            await open()
            return
        }
        await chat.loadMessages(in: conversationID)
        chat.markRead(conversationID)
    }

    private func loadOlder() async {
        guard let conversationID, !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        hasOlderMessages = await chat.loadOlderMessages(in: conversationID)
    }

    // MARK: - Sending

    private func sendCurrentMessage() async {
        guard let conversationID else { return }
        let body = trimmedMessage
        guard !body.isEmpty else { return }

        let picked = attachedPlace

        isSending = true
        defer { isSending = false }

        let sent = await chat.send(
            in: conversationID,
            body: body,
            place: picked?.placeID,
            visit: picked?.visitID,
            preview: picked?.preview
        )

        if sent {
            messageText = ""
            attachedPlace = nil
            scrollRequest += 1
            Haptics.success()
        }
    }
}

// MARK: - One message

/// One message: a place preview, then the note under it.
///
/// The preview is the venue — photo, name, address — and is the tap target;
/// it already carries its own surface (the photo) so it stays unfilled. The
/// note is a real bubble: mine is blue with white text, theirs is a white
/// card with dark text — so a two-person thread is readable in both
/// appearances without needing avatars.
private struct ChatMessageRow: View {
    let message: ChatMessage
    let isMine: Bool
    var onOpenPlace: (ChatMessage) -> Void

    /// The preview is a fixed width; the note is not. Roughly two thirds of a
    /// phone, which keeps the photo big enough to recognise a room by while
    /// still reading as "attached to a message" rather than as a feed post.
    private static let previewWidth: CGFloat = 240
    private static let bubbleTextColor = Color.black.opacity(0.88)
    private static let mineBubbleFill = Color.blue
    /// The gap a bubble always leaves on the opposite side of the thread.
    /// This — not a `maxWidth` on the bubble itself — is what caps its
    /// width, because `.frame(maxWidth:)` fills whatever it's offered up
    /// to the cap instead of hugging the text, which is what made a
    /// one-word reply render as a full-width bubble.
    private static let bubbleMargin: CGFloat = 64

    private var photoSource: PhotoView.Source? {
        message.photos
            .sorted { $0.sortOrder < $1.sortOrder }
            .first
            .map { PhotoView.Source.friendPhoto(path: $0.smallestPath) }
    }

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 8) {
            if let place = message.place {
                placePreview(place)
            }

            if !message.body.isEmpty {
                bubble
            }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }

    /// A `Spacer` on the far side, not a `maxWidth` on the bubble, is what
    /// makes this hug the text: the spacer soaks up whatever room the
    /// text doesn't need, and only yields once the bubble grows to within
    /// `bubbleMargin` of the edge — which is also where wrapping kicks in.
    private var bubble: some View {
        HStack(spacing: 0) {
            if isMine { Spacer(minLength: Self.bubbleMargin) }
            Text(message.body)
                .font(.subheadline)
                .foregroundStyle(isMine ? Color.white : Self.bubbleTextColor)
                .multilineTextAlignment(isMine ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isMine ? Self.mineBubbleFill : Color.white)
                )
            if !isMine { Spacer(minLength: Self.bubbleMargin) }
        }
    }

    private func placePreview(_ place: PlaceSummary) -> some View {
        Button {
            onOpenPlace(message)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay {
                        if let photoSource {
                            PhotoView(source: photoSource, contentMode: .fill)
                        } else {
                            ZStack {
                                categoryTint(place.category).opacity(0.18)
                                Image(systemName: categorySymbol(place.category))
                                    .font(.system(size: 32, weight: .ultraLight))
                                    .foregroundStyle(categoryTint(place.category))
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(message.placeHeadline ?? place.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    // The address, always — it is what makes this a preview of a
                    // real place rather than a name someone typed.
                    if let subtitle = place.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(width: Self.previewWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(place.name)
        .accessibilityHint("Opens \(place.name)")
    }

    private func categorySymbol(_ category: PlaceCategory) -> String {
        switch category {
        case .restaurant: "fork.knife"
        case .bar:        "wineglass.fill"
        case .cafe:       "cup.and.saucer.fill"
        case .bakery:     "birthday.cake.fill"
        case .other:      "mappin"
        }
    }

    private func categoryTint(_ category: PlaceCategory) -> Color {
        switch category {
        case .restaurant: .orange
        case .bar:        .purple
        case .cafe:       .brown
        case .bakery:     .pink
        case .other:      .gray
        }
    }
}
