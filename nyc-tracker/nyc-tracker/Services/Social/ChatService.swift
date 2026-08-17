import Foundation
import Supabase

/// Every wire call the direct-message feature makes.
///
/// Stateless, like `FriendshipService` and `RecommendationService`: `ChatStore`
/// owns the observable state, the refresh policy and the realtime channel; this
/// owns the request shapes.
enum ChatService {

    private static var client: SupabaseClient { SupabaseManager.client }

    // MARK: - Threads

    /// Every thread the caller is in, newest first, with previews and unread
    /// counts. One call backs the friends-list previews, the per-row unread dot,
    /// and the tab badge.
    static func threads() async throws -> [ConversationThread] {
        if let demo = SocialDemoMode.active {
            await demo.simulateLatency()
            return demo.conversationThreads()
        }

        return try await client
            .rpc("conversation_threads")
            .execute()
            .value
    }

    /// The thread with one person, created on first use.
    ///
    /// Called every time a chat is opened rather than only when one is started,
    /// because "has this thread been created yet" is a question the server can
    /// answer in the same round trip it would take to ask.
    static func openConversation(with userID: UUID) async throws -> UUID {
        if let demo = SocialDemoMode.active {
            await demo.simulateLatency()
            return demo.openConversation(with: userID)
        }

        return try await client
            .rpc("open_conversation", params: ["p_other": userID.uuidString])
            .execute()
            .value
    }

    // MARK: - Messages

    /// One page of a thread, oldest-first for rendering.
    ///
    /// The query asks for the NEWEST `limit` rows and reverses them here. Asking
    /// ascending would page from the start of the conversation, which is the
    /// wrong end — a thread opens at the bottom.
    ///
    /// `before` is a keyset cursor for scrolling back: pass the oldest loaded
    /// message's timestamp. Not an offset, for the usual reason — a message
    /// arriving while the user reads makes offsets repeat and skip rows.
    ///
    /// Reads go straight at the `message_details` view rather than through an
    /// RPC. The view is SECURITY INVOKER, so `messages_select_parties` decides
    /// what comes back exactly as it would for the table.
    static func messages(
        in conversationID: UUID,
        before cursor: Date? = nil,
        limit: Int = 50
    ) async throws -> [ChatMessage] {
        if let demo = SocialDemoMode.active {
            await demo.simulateLatency()
            return demo.messages(in: conversationID)
        }

        var query = client
            .from("message_details")
            .select()
            .eq("conversation_id", value: conversationID.uuidString)

        if let cursor {
            query = query.lt("created_at", value: isoString(from: cursor))
        }

        let newestFirst: [ChatMessage] = try await query
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value

        return newestFirst.reversed()
    }

    /// Send one message and get it back in the same shape reads use.
    ///
    /// The composed row comes back from the insert so the bubble can be drawn
    /// from real server state — including the venue join and the photos — rather
    /// than from a locally assembled guess that a refresh then replaces.
    /// `preview` is ignored on the wire and used only by sample mode, which has
    /// no server row to read back and no knowledge of the user's own places.
    static func send(
        conversation conversationID: UUID,
        body: String,
        place placeID: UUID?,
        visit visitID: UUID?,
        preview: SharedPlacePreview? = nil
    ) async throws -> ChatMessage {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)

        if let demo = SocialDemoMode.active {
            await demo.simulateLatency()
            return demo.sendMessage(
                conversation: conversationID,
                body: trimmed,
                place: placeID,
                visit: visitID,
                preview: preview
            )
        }

        let params = SendMessageParams(
            conversation: conversationID,
            body: trimmed,
            place: placeID,
            visit: visitID
        )

        let rows: [ChatMessage] = try await client
            .rpc("send_message", params: params)
            .execute()
            .value

        guard let message = rows.first else {
            throw ChatError.sendReturnedNothing
        }
        return message
    }

    /// Move the caller's read cursor on one thread to the server's `now()`.
    ///
    /// Server clock, for the same reason `mark_recommendations_read` uses one: a
    /// device clock produces "read before it was sent" orderings that surface
    /// much later as an inexplicable unread count.
    static func markRead(conversation conversationID: UUID) async throws {
        if let demo = SocialDemoMode.active {
            demo.markConversationRead(conversationID)
            return
        }

        try await client
            .rpc("mark_conversation_read", params: ["p_conversation": conversationID.uuidString])
            .execute()
    }

    // MARK: - Errors

    enum ChatError: LocalizedError {
        /// `send_message` came back with no rows. Only reachable if the function
        /// is replaced by one that doesn't return the inserted row.
        case sendReturnedNothing

        var errorDescription: String? {
            switch self {
            case .sendReturnedNothing:
                "The message was sent but couldn't be loaded back."
            }
        }
    }

    // MARK: - Cursor formatting

    /// PostgREST filters are query-string values, so the cursor has to be text.
    ///
    /// Fractional seconds are not optional here: messages sent in the same
    /// second are ordinary, and a second-resolution cursor would re-fetch or
    /// skip whichever of them shares the boundary.
    private static func isoString(from date: Date) -> String {
        cursorFormatter.string(from: date)
    }

    private static let cursorFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
