import Foundation

/// Small, versioned JSON snapshots of server state, on disk, scoped per account.
///
/// ## What this is for
///
/// The social stores (`SocialGraph`, `ChatStore`, `FriendVisitCache`) are
/// in-memory and rebuild themselves from the server on every launch. That is
/// correct for freshness and terrible to look at: a cold start shows an empty
/// friends list, no message previews and a bare map for as long as the network
/// takes, and then everything appears at once. This gives those stores something
/// to draw in their first frame.
///
/// The policy on top of it is stale-while-revalidate, which is the only sensible
/// one for a social feed: render the snapshot immediately, always refetch, and
/// replace when the refetch lands. A snapshot is never authoritative and is
/// never merged with server data — it is a placeholder that happens to be right
/// almost every time.
///
/// ## Why `Caches/`, and why not SwiftData
///
/// Both existing comments on the subject still hold: the SwiftData store is the
/// signed-in user's own mirror, partitioned by `ownerUserID`, and other people's
/// rows have no business in it. What those comments ruled out was *ownership*,
/// not disk — and they already bless the `Caches/` treatment by pointing at
/// `PhotoCache`. Everything written here gets exactly that treatment:
/// re-downloadable, excluded from backups, evictable by the OS under pressure,
/// and deleted on sign-out.
///
/// ## Correctness rails
///
/// - **Per-user filenames.** The account id is part of the path, so a snapshot
///   can never be read by a different account signed in on the same device.
/// - **Schema version.** Every file records `schemaVersion`; a mismatch is
///   discarded rather than decoded. The DTOs here are wire shapes that change
///   when the server changes, and a stale shape must not become a decode crash.
/// - **A decode failure is a cache miss.** Nothing in this file throws upward.
///   The worst outcome of any corruption is one launch that looks like it did
///   before this existed.
/// - **Max age.** Not a freshness mechanism — the refetch is. It is a floor that
///   stops an app opened after three months from showing three-month-old
///   previews during the second before the network answers.
final class SnapshotStore {

    static let shared = SnapshotStore()

    /// Bump when any persisted DTO changes shape. Every existing file is then
    /// ignored (and overwritten on the next save), which is always safe because
    /// every one of them is a copy of something the server will resend.
    private static let schemaVersion = 1

    /// What can be snapshotted. A closed set rather than free-form strings so
    /// the filenames on disk are enumerable and `clear()` can't miss one.
    enum Key: String, CaseIterable {
        case friendships
        case recommendations
        case chatThreads
        case chatMessages
        case friendVisits
    }

    private let directory: URL
    private let fileManager = FileManager.default

    /// Pending writes, keyed by file. A burst — marking a thread read, then the
    /// thread reload it triggers — collapses into one encode and one write
    /// instead of three.
    private var pendingWrites: [String: Task<Void, Never>] = [:]

    /// Long enough that a write survives a fast sequence of related mutations,
    /// short enough to have landed before the app is backgrounded and killed.
    private let writeDelay: Duration = .milliseconds(400)

    private init() {
        let caches = (try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory

        directory = caches.appendingPathComponent("NYCLogSnapshots", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Reading

    /// The snapshot for `key`, or nil if there isn't one, it belongs to another
    /// schema, or it is older than `maxAge`.
    ///
    /// Synchronous. These files are tens of kilobytes and each one is read once,
    /// at the moment a store configures itself — an `await` there would put the
    /// blank frame back that this exists to remove.
    func load<Value: Decodable>(
        _ type: Value.Type,
        _ key: Key,
        userID: UUID,
        maxAge: TimeInterval
    ) -> Value? {
        let url = fileURL(for: key, userID: userID)
        guard let data = try? Data(contentsOf: url) else { return nil }

        guard let envelope = try? Self.decoder.decode(LoadEnvelope<Value>.self, from: data),
              envelope.schemaVersion == Self.schemaVersion,
              envelope.userID == userID,
              Date().timeIntervalSince(envelope.savedAt) < maxAge
        else {
            // Unreadable, foreign or expired — drop it rather than leaving a file
            // that fails the same way on every launch.
            try? fileManager.removeItem(at: url)
            return nil
        }

        return envelope.payload
    }

    // MARK: - Writing

    /// Queue a snapshot write. Returns immediately; the disk write happens off
    /// the main actor.
    ///
    /// Safe to call on every state change — that is the intended usage, and the
    /// coalescing below is what makes it cheap.
    ///
    /// ## Why the encode happens here and not in the write task
    ///
    /// Two reasons, one of them forced. The project sets
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which makes the `Encodable`
    /// conformances of the wire DTOs main-actor-isolated — so the *values*
    /// cannot cross into a detached task at all, however `Sendable` the structs
    /// themselves are. `Data` has no such problem.
    ///
    /// It is also the better shape regardless: encoding snapshots the value at
    /// call time, so a store that mutates during the debounce window cannot have
    /// its later state written under an earlier one's timestamp. The expensive
    /// half — the file write — is the half that goes off the main actor, and the
    /// encode is microseconds against payloads capped in the tens of kilobytes.
    func save<Value: Encodable>(_ value: Value, _ key: Key, userID: UUID) {
        let envelope = SaveEnvelope(
            schemaVersion: Self.schemaVersion,
            userID: userID,
            savedAt: Date(),
            payload: value
        )
        guard let data = try? Self.encoder.encode(envelope) else { return }

        let url = fileURL(for: key, userID: userID)
        let name = url.lastPathComponent

        pendingWrites[name]?.cancel()
        pendingWrites[name] = Task { [weak self] in
            try? await Task.sleep(for: self?.writeDelay ?? .milliseconds(400))
            guard !Task.isCancelled else { return }

            await Task.detached(priority: .utility) {
                try? data.write(to: url, options: .atomic)
            }.value

            self?.pendingWrites[name] = nil
        }
    }

    // MARK: - Clearing

    /// Sign-out. Drops every account's snapshots, not just the departing one:
    /// the whole directory is disposable, and a targeted delete would leave
    /// files behind for an account that was removed from the device.
    func clear() {
        for task in pendingWrites.values { task.cancel() }
        pendingWrites.removeAll()
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Paths

    private func fileURL(for key: Key, userID: UUID) -> URL {
        let owner = StableHash.filenameToken(userID.uuidString)
        return directory.appendingPathComponent("\(owner)-\(key.rawValue).json")
    }

    // MARK: - Envelope

    /// One shape, written by `SaveEnvelope` and read by `LoadEnvelope`.
    ///
    /// Two types rather than one generic over `Codable` because the entry points
    /// have opposite requirements: `load`'s caller only has a `Decodable` and
    /// `save`'s only an `Encodable`. A single `Envelope<Value: Codable>` would
    /// force both halves on every persisted DTO, including the several that are
    /// decode-only wire types elsewhere in the app. The field names are
    /// identical, which is what makes the file readable by the other half.
    private struct SaveEnvelope<Value: Encodable>: Encodable {
        var schemaVersion: Int
        var userID: UUID
        var savedAt: Date
        var payload: Value
    }

    private struct LoadEnvelope<Value: Decodable>: Decodable {
        var schemaVersion: Int
        var userID: UUID
        var savedAt: Date
        var payload: Value
    }

    /// Both ends of this are ours, so the default date strategy — a `Double`
    /// since the reference date — round-trips exactly. The ISO-8601 formatting
    /// the wire uses exists to satisfy PostgREST and would only add a
    /// fractional-seconds precision question that nothing here needs to ask.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
