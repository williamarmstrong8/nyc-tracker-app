import Foundation
import Observation
import Supabase

/// Direct messages, as observable state: the thread list, the messages of every
/// thread that has been opened this session, and one realtime subscription
/// feeding both.
///
/// ## What lives here and what doesn't
///
/// `SocialGraph` owns who your friends are. This owns what you have said to
/// them. They are kept apart because they change for different reasons and at
/// different rates — a friends list is stable for weeks, a thread changes while
/// you are looking at it — and merging them would mean refetching the graph
/// every time a message arrives.
///
/// Nothing here is written to SwiftData. See the note at the top of
/// `ChatModels.swift`: a queued-but-unsent message rendered as sent is worse
/// than no offline support at all.
///
/// Scoped to the signed-in user by `configure(userID:)`, same as the other
/// social stores, so one account's threads can never survive into the next.
@Observable
final class ChatStore {

    // MARK: - Observable state

    /// Threads, newest activity first — the order the server returns them in.
    private(set) var threads: [ConversationThread] = []

    /// Loaded messages per conversation, oldest first.
    ///
    /// A dictionary rather than "the messages of the open thread" so that
    /// backing out of a chat and returning to it doesn't blank the screen while
    /// the same rows are fetched again.
    private(set) var messagesByConversation: [UUID: [ChatMessage]] = [:]

    private(set) var isLoadingThreads = false
    /// False until the first successful thread load. Distinguishes "no threads"
    /// from "haven't looked yet".
    private(set) var hasLoadedThreads = false

    var lastError: PresentableError?

    // MARK: - Private

    private var userID: UUID?
    private var refreshTask: Task<Void, Never>?
    private var listenerTask: Task<Void, Never>?
    private var channel: RealtimeChannelV2?
    /// The thread currently on screen, if any. Drives whether an incoming
    /// message is marked read on arrival.
    private var activeConversationID: UUID?
    private var pendingRefreshTask: Task<Void, Never>?

    init() {}

    // MARK: - Derived

    /// Total unread across every thread. The Friends tab badge adds this to the
    /// friend-request and recommendation counts from `SocialGraph`.
    var unreadCount: Int {
        threads.reduce(0) { $0 + $1.unreadCount }
    }

    /// The thread with one person, if it has ever been used.
    ///
    /// Keyed by person rather than by conversation because that is what the
    /// friends list has in hand: a row knows who it is, not which thread id
    /// belongs to them.
    func thread(with personID: UUID) -> ConversationThread? {
        threads.first { $0.userID == personID }
    }

    func messages(in conversationID: UUID) -> [ChatMessage] {
        messagesByConversation[conversationID] ?? []
    }

    // MARK: - Lifecycle

    func configure(userID: UUID) {
        guard self.userID != userID else { return }
        self.userID = userID
        // Sample threads need both sides, and the signed-in one is real. This is
        // the only place the overlay is told who that is; it is a no-op when
        // demo mode is off.
        SocialDemoMode.shared.noteSignedInUser(userID)
        clearState()
        refreshThreads()
        startListening()
    }

    /// Drop everything and close the socket. Called on sign-out, before the next
    /// account loads.
    func teardown() {
        refreshTask?.cancel()
        refreshTask = nil
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        stopListening()
        userID = nil
        clearState()
    }

    private func clearState() {
        threads = []
        messagesByConversation = [:]
        activeConversationID = nil
        hasLoadedThreads = false
        isLoadingThreads = false
        lastError = nil
    }

    // MARK: - Threads

    /// Fire-and-forget refresh, for `.task` and `onAppear`.
    func refreshThreads() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.reloadThreads()
        }
    }

    /// Awaitable refresh, for pull-to-refresh and for sequencing after a send.
    func reloadThreads() async {
        guard userID != nil else { return }

        isLoadingThreads = true
        defer { isLoadingThreads = false }

        do {
            let loaded = try await ChatService.threads()
            guard !Task.isCancelled else { return }
            threads = loaded
            hasLoadedThreads = true
        } catch {
            guard !Task.isCancelled else { return }
            // Keep what's on screen. A network blip must not empty the friends
            // list's previews or zero the badge.
            lastError = SupabaseErrorPresenter.presentable(error, context: .general)
        }
    }

    // MARK: - One thread

    /// The conversation with someone, created on first open.
    ///
    /// Returns nil on failure rather than throwing: the chat screen's answer to
    /// "couldn't open this" is an inline retry, not a thrown error that every
    /// call site re-wraps.
    func openConversation(with personID: UUID) async -> UUID? {
        guard userID != nil else { return nil }
        do {
            return try await ChatService.openConversation(with: personID)
        } catch {
            lastError = SupabaseErrorPresenter.presentable(error, context: .general)
            return nil
        }
    }

    /// Load (or reload) the newest page of a thread.
    @discardableResult
    func loadMessages(in conversationID: UUID) async -> Bool {
        do {
            let loaded = try await ChatService.messages(in: conversationID)
            messagesByConversation[conversationID] = loaded
            return true
        } catch {
            lastError = SupabaseErrorPresenter.presentable(error, context: .general)
            return false
        }
    }

    /// Page backwards from the oldest loaded message.
    ///
    /// Returns false when there is nothing older, so the caller can stop asking.
    @discardableResult
    func loadOlderMessages(in conversationID: UUID) async -> Bool {
        guard let oldest = messagesByConversation[conversationID]?.first else {
            return await loadMessages(in: conversationID)
        }

        do {
            let older = try await ChatService.messages(in: conversationID, before: oldest.createdAt)
            guard !older.isEmpty else { return false }
            let existing = messagesByConversation[conversationID] ?? []
            messagesByConversation[conversationID] = merge(older, into: existing)
            return true
        } catch {
            lastError = SupabaseErrorPresenter.presentable(error, context: .general)
            return false
        }
    }

    /// Send one message into a thread.
    ///
    /// The returned row is appended immediately rather than waiting for a
    /// refresh, so the bubble lands with the tap. The thread list is refreshed
    /// afterwards because its preview and ordering just changed.
    @discardableResult
    func send(
        in conversationID: UUID,
        body: String,
        place placeID: UUID?,
        visit visitID: UUID?,
        preview: SharedPlacePreview? = nil
    ) async -> Bool {
        do {
            let message = try await ChatService.send(
                conversation: conversationID,
                body: body,
                place: placeID,
                visit: visitID,
                preview: preview
            )
            let existing = messagesByConversation[conversationID] ?? []
            messagesByConversation[conversationID] = merge([message], into: existing)
            await reloadThreads()
            return true
        } catch {
            lastError = SupabaseErrorPresenter.presentable(error, context: .general)
            return false
        }
    }

    /// Mark a thread read, optimistically.
    ///
    /// The badge drops as the thread opens rather than a round trip later. The
    /// server call only ever affects the caller's own cursor, so a duplicate is
    /// harmless and a failure costs one badge that reappears on next launch —
    /// not worth an alert.
    func markRead(_ conversationID: UUID) {
        if let index = threads.firstIndex(where: { $0.conversationID == conversationID }),
           threads[index].unreadCount > 0 {
            threads[index].unreadCount = 0
        }

        Task {
            try? await ChatService.markRead(conversation: conversationID)
        }
    }

    /// Tell the store which thread is on screen.
    ///
    /// Only used to decide whether an arriving message should be marked read
    /// without the user doing anything — which is the correct behaviour when
    /// they are literally looking at it, and wrong in every other case.
    func setActiveConversation(_ conversationID: UUID?) {
        activeConversationID = conversationID
    }

    // MARK: - Realtime

    /// Subscribe to every message row the server is willing to send us.
    ///
    /// Deliberately unfiltered. Realtime evaluates `messages_select_parties` per
    /// subscriber before delivering a change, so an unfiltered subscription
    /// still only yields this user's own threads — and one channel for the
    /// session means the badge updates while the user is on the map, which a
    /// per-thread channel opened by the chat screen could never do.
    ///
    /// The payload itself is used only as a signal. It carries the raw
    /// `messages` row, without the venue join or the photos, so rendering from
    /// it would show a card that changes shape a moment later.
    private func startListening() {
        // Sample people have no server rows; a socket for them would sit idle.
        guard SocialDemoMode.active == nil else { return }

        stopListening()

        let channel = SupabaseManager.client.channel("direct-messages")
        self.channel = channel

        listenerTask = Task { [weak self] in
            let inserts = channel.postgresChange(
                InsertAction.self,
                schema: "public",
                table: "messages"
            )
            do {
                try await channel.subscribeWithError()
            } catch {
                // Not surfaced. A socket that won't open costs live updates, not
                // correctness: every screen still loads over HTTP, and the
                // foreground refresh in `nyc_trackerApp` keeps the badge honest.
                // An alert here would fire on any flaky network, about a feature
                // the user never asked for by name.
                return
            }

            for await insert in inserts {
                guard !Task.isCancelled else { break }
                self?.handleIncoming(insert)
            }
        }
    }

    private func stopListening() {
        listenerTask?.cancel()
        listenerTask = nil

        if let channel {
            self.channel = nil
            Task { await SupabaseManager.client.removeChannel(channel) }
        }
    }

    private func handleIncoming(_ insert: InsertAction) {
        let conversationID = insert.record["conversation_id"]?.stringValue.flatMap(UUID.init(uuidString:))

        // Coalesced: a friend sending three places in a row is one refresh, not
        // three. 250ms is below the threshold where the delay is noticeable and
        // above the gap between messages sent together.
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            guard let self else { return }

            await self.reloadThreads()

            // Only refetch a thread that is already on screen or already loaded.
            // Every other thread is corrected by its own load when opened.
            if let conversationID, self.messagesByConversation[conversationID] != nil {
                await self.loadMessages(in: conversationID)
            }
            if let conversationID, conversationID == self.activeConversationID {
                self.markRead(conversationID)
            }
        }
    }

    // MARK: - Merging

    /// Union by id, sorted oldest first.
    ///
    /// Needed because three sources write into the same array — the initial
    /// page, the older page, and a just-sent message — and the realtime refetch
    /// can overlap any of them. Keyed on id so the same message arriving twice
    /// is one bubble.
    private func merge(_ incoming: [ChatMessage], into existing: [ChatMessage]) -> [ChatMessage] {
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for message in incoming {
            byID[message.id] = message
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                // Stable tiebreak for messages sent in the same instant, so the
                // order doesn't shuffle between renders.
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
    }
}
