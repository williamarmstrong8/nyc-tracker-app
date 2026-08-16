import Foundation
import Observation
import SwiftData
import Supabase

/// Moves visits between the local SwiftData mirror and Supabase.
///
/// ## The shape of it
///
/// Writes go to SwiftData and return immediately; nothing in the capture flow
/// awaits the network. This engine picks the work up afterwards. That inversion
/// is the reason the app still works in airplane mode and the reason confirming
/// a visit is as fast as it was before there was a backend.
///
/// SwiftData is therefore a *mirror plus a write-ahead queue*, and Supabase is
/// the source of truth. When the two disagree the remote copy wins — except for
/// rows the device hasn't successfully sent yet, which are the one thing the
/// cloud provably does not know about. See `reconcile(_:)`.
///
/// ## Actor isolation
///
/// Main-actor isolated, using `container.mainContext`. `ModelContext` is not
/// `Sendable` and `@Model` objects can't cross contexts, so a background
/// `ModelActor` would mean re-fetching every object by ID on both sides of every
/// hop — a lot of machinery for an app whose sync unit is one visit with at most
/// eight photos. Network calls suspend and free the main actor while they wait,
/// and the genuinely CPU-bound work (image decode, downscale, JPEG encode) is
/// pushed off with `Task.detached` in `uploadPhotos` (and, at capture time, in
/// `PhotoIngest`). What's left on the main thread is field copying.
///
/// If this ever syncs thousands of rows in one pass, the pull loop is the part
/// that would need to move.
@MainActor
@Observable
final class SyncEngine {

    // MARK: - Observable state

    private(set) var isSyncing = false
    /// Rows the cloud doesn't have yet, including ones that failed.
    private(set) var pendingCount = 0
    private(set) var failedCount = 0
    private(set) var lastSyncedAt: Date?
    /// Set when the whole sync (not one row) failed in a way worth showing.
    var lastError: PresentableError?

    /// Non-nil while legacy pre-auth visits are being claimed and uploaded.
    private(set) var migrationProgress: MigrationProgress?

    struct MigrationProgress: Equatable, Sendable {
        var total: Int
        var completed: Int
        var failed: Int

        var isFinished: Bool { completed + failed >= total }
        var fraction: Double {
            total == 0 ? 1 : Double(completed + failed) / Double(total)
        }
    }

    /// Raised when the session cannot be refreshed. `RootView` watches this and
    /// sends the user back through the gate.
    private(set) var needsReauthentication = false

    // MARK: - Dependencies

    private var container: ModelContainer?
    private var userID: UUID?
    private var context: ModelContext? { container?.mainContext }
    private var client: SupabaseClient { SupabaseManager.client }

    private var syncTask: Task<Void, Never>?
    private var retryTimerTask: Task<Void, Never>?
    /// Guards against a second refresh storm when several rows fail on auth at once.
    private var didAttemptSessionRefresh = false

    // MARK: - Tuning

    /// First retry lands ~2s out; each failure doubles, capped at 5 minutes.
    /// Capped because a user who leaves the app open on a bad connection should
    /// still see it recover within a few minutes of the network coming back,
    /// without the wake-on-reachability path being the only thing that saves them.
    private let baseBackoff: TimeInterval = 2
    private let maxBackoff: TimeInterval = 300
    /// How often the engine re-checks for rows whose backoff has elapsed.
    private let retryTickInterval: Duration = .seconds(20)

    private let bucket = "visit-photos"

    // MARK: - Lifecycle

    /// Bind the engine to a container and a signed-in user, then start working.
    ///
    /// Idempotent for the same user so a view re-appearing can call it freely.
    func configure(container: ModelContainer, userID: UUID) {
        if self.userID == userID, self.container != nil { return }

        self.container = container
        self.userID = userID
        needsReauthentication = false
        didAttemptSessionRefresh = false

        NetworkMonitor.shared.onBecameReachable = { [weak self] in
            self?.requestSync(reason: .networkReturned)
        }

        recoverInterruptedUploads()
        refreshCounts()
        startRetryTimer()

        Task { await claimLegacyVisitsThenSync(userID: userID) }
    }

    /// Detach from the current user. Called on sign-out.
    ///
    /// The queue is deliberately **not** cleared — see `SettingsView`'s sign-out
    /// path for the reasoning. Rows stay on disk tagged with their owner's id and
    /// resume when that user signs back in.
    func teardown() {
        syncTask?.cancel()
        syncTask = nil
        retryTimerTask?.cancel()
        retryTimerTask = nil
        NetworkMonitor.shared.onBecameReachable = nil

        container = nil
        userID = nil
        isSyncing = false
        pendingCount = 0
        failedCount = 0
        lastSyncedAt = nil
        migrationProgress = nil
        lastError = nil
    }

    // MARK: - Entry points

    enum SyncReason {
        case appForeground
        case networkReturned
        case manualRefresh
        case newLocalWrite
        case retryTimer
    }

    /// Ask for a sync. Coalesces — a second call while one is running is a no-op
    /// rather than a queued duplicate, because the running pass picks up rows
    /// added after it started anyway (it re-fetches the pending set per row).
    func requestSync(reason: SyncReason) {
        guard container != nil, userID != nil else { return }
        guard !needsReauthentication else { return }
        guard syncTask == nil else { return }

        syncTask = Task { [weak self] in
            defer { self?.syncTask = nil }
            await self?.runSync(reason: reason)
        }
    }

    /// Pull-to-refresh. Awaits completion so the spinner is honest about when
    /// the work actually finished.
    func refreshNow() async {
        guard container != nil, userID != nil else { return }
        // Cancel any in-flight background pass so the user's explicit gesture
        // owns the run and the spinner reflects it, not an earlier automatic one.
        syncTask?.cancel()
        syncTask = nil
        await runSync(reason: .manualRefresh)
    }

    /// Clear the backoff on every failed row and try again immediately.
    /// Wired to the "Retry" button in the sync status UI.
    func retryFailedNow() {
        guard let context, let userID else { return }
        let failed = (try? context.fetch(Self.failedVisitsDescriptor(for: userID))) ?? []
        for visit in failed {
            visit.markDirty()
        }
        try? context.save()
        refreshCounts()
        requestSync(reason: .manualRefresh)
    }

    // MARK: - The sync pass

    private func runSync(reason: SyncReason) async {
        guard let userID else { return }
        guard NetworkMonitor.shared.isReachable || reason == .manualRefresh else {
            // Offline: leave everything pending. Not an error state — this is the
            // designed behaviour, and surfacing an alert for it would fire every
            // time the user walks into a subway station.
            refreshCounts()
            return
        }

        isSyncing = true
        defer {
            isSyncing = false
            refreshCounts()
        }

        // Order matters. Deletions first so a visit the user deleted while
        // offline doesn't get uploaded and then immediately tombstoned — two
        // round trips and a row that briefly exists for no reason.
        await drainDeletions(userID: userID)
        await pushPendingVisits(userID: userID)
        await pull(userID: userID)
    }

    // MARK: - Push

    private func pushPendingVisits(userID: UUID) async {
        guard let context else { return }

        let now = Date()
        let candidates = ((try? context.fetch(Self.pendingVisitsDescriptor(for: userID))) ?? [])
            .filter { visit in
                // Respect the backoff window.
                guard let next = visit.nextAttemptAt else { return true }
                return next <= now
            }

        for visit in candidates {
            if Task.isCancelled { return }
            guard !needsReauthentication else { return }
            await upload(visit)
        }
    }

    /// The upload pipeline for one visit.
    ///
    /// Four steps, each idempotent, each resumable:
    ///   1. resolve the place (cached after the first success)
    ///   2. prepare + upload photo objects (skipped per-photo once uploaded)
    ///   3. upsert the visit row
    ///   4. upsert the photo rows
    ///
    /// Ordering is forced by foreign keys: a photo row needs its visit to exist,
    /// and a visit needs its place. The objects go up before the visit row on
    /// purpose — an orphaned storage object is invisible and gets reused by the
    /// next attempt (same deterministic path), whereas a photo row pointing at
    /// an object that isn't there renders as a permanently broken image.
    private func upload(_ visit: Visit) async {
        guard let context, let userID else { return }

        visit.syncState = .uploading
        try? context.save()

        do {
            // ---- 1. Place ---------------------------------------------------
            let placeID = try await resolvePlaceID(for: visit)

            // ---- 2. Photos --------------------------------------------------
            try await uploadPhotos(for: visit, userID: userID)

            // ---- 3. Visit row -----------------------------------------------
            let payload = VisitUpsert(
                id: visit.id,
                userID: userID,
                placeID: placeID,
                visitedAt: visit.visitedOn,
                transcript: visit.transcript.isEmpty ? nil : visit.transcript,
                summary: visit.enrichedDescription.isEmpty ? nil : visit.enrichedDescription,
                tags: visit.tags,
                title: visit.title.isEmpty ? nil : visit.title,
                topQuote: visit.topQuote.isEmpty ? nil : visit.topQuote,
                ratingLabel: visit.rating?.rawValue,
                returnIntent: visit.returnIntent?.rawValue,
                kind: visit.kind.rawValue,
                deletedAt: nil
            )

            try await client
                .from("visits")
                .upsert(payload, onConflict: "id")
                .execute()

            // ---- 4. Photo rows ----------------------------------------------
            try await upsertPhotoRows(for: visit)

            // ---- 5. Done ----------------------------------------------------
            visit.syncState = .synced
            visit.remoteID = visit.id
            visit.lastSyncedAt = Date()
            visit.syncError = nil
            visit.syncAttemptCount = 0
            visit.nextAttemptAt = nil
            try? context.save()

        } catch {
            record(error, on: visit)
        }
    }

    /// Step 1 — `find_or_create_place()`, cached on the local `Place`.
    ///
    /// The RPC is the only write path to `places` and it is what makes two
    /// captures of the same venue — from this device or any other — land on one
    /// row. Caching the result means the second visit to a bar the user already
    /// logged skips the call entirely.
    private func resolvePlaceID(for visit: Visit) async throws -> UUID {
        guard let place = visit.place else {
            throw SyncEngineError.visitHasNoPlace
        }
        if let cached = place.remotePlaceID { return cached }

        let params = FindOrCreatePlaceParams(
            mapkitID: place.externalPOIId,
            name: place.name,
            latitude: place.lat,
            longitude: place.lng,
            streetAddress: visit.address,
            locality: nil,
            adminArea: nil,
            country: nil,
            postalCode: nil,
            category: place.category.rawValue,
            phone: nil,
            websiteURL: nil,
            neighborhood: place.neighborhood.isEmpty ? nil : place.neighborhood
        )

        let placeID: UUID = try await client
            .rpc("find_or_create_place", params: params)
            .execute()
            .value

        place.remotePlaceID = placeID
        try? context?.save()
        return placeID
    }

    /// Step 2 — prepare and upload the objects for any photo not already up.
    ///
    /// `remoteStoragePath` is set only after the bytes are confirmed in, so this
    /// naturally resumes: a visit whose first two photos uploaded before the app
    /// was killed re-enters here and starts at the third.
    private func uploadPhotos(for visit: Visit, userID: UUID) async throws {
        for photo in visit.photos.sorted(by: { $0.order < $1.order }) {
            if photo.remoteStoragePath != nil { continue }
            try Task.checkCancellation()

            guard let localData = loadLocalImageData(for: photo) else {
                // No bytes on disk and nothing uploaded — the row would point at
                // nothing. Drop it rather than failing the whole visit: the
                // transcript and write-up are worth more than one missing image.
                continue
            }

            // Decode/resize/encode is the only genuinely CPU-heavy work in the
            // pipeline. Off the main actor so the UI stays responsive.
            let prepared = try await Task.detached(priority: .utility) {
                try ImagePreparer.prepare(localData)
            }.value

            let basePath = "\(userID.uuidString.lowercased())/\(visit.id.uuidString.lowercased())"
            let fullPath = "\(basePath)/\(photo.id.uuidString.lowercased()).jpg"
            let thumbPath = "\(basePath)/\(photo.id.uuidString.lowercased())_thumb.jpg"

            // upsert:true so a retry that already wrote this object overwrites it
            // instead of failing on "resource already exists" — the deterministic
            // path plus upsert is what makes an interrupted upload converge
            // rather than accumulate orphans.
            _ = try await client.storage
                .from(bucket)
                .upload(
                    fullPath,
                    data: prepared.fullJPEG,
                    options: FileOptions(contentType: "image/jpeg", upsert: true)
                )

            // A failed thumbnail must not fail the photo: `thumb_path` is
            // nullable and readers fall back to the full image.
            var uploadedThumbPath: String?
            do {
                _ = try await client.storage
                    .from(bucket)
                    .upload(
                        thumbPath,
                        data: prepared.thumbnailJPEG,
                        options: FileOptions(contentType: "image/jpeg", upsert: true)
                    )
                uploadedThumbPath = thumbPath
            } catch {
                uploadedThumbPath = nil
            }

            photo.remoteStoragePath = fullPath
            photo.remoteThumbPath = uploadedThumbPath
            photo.pixelWidth = prepared.width
            photo.pixelHeight = prepared.height
            // Metadata read off the original before the uploaded copy was
            // stripped. Only fill blanks — a value already set came from the
            // PHAsset at capture time and is at least as trustworthy.
            photo.capturedAt = photo.capturedAt ?? prepared.capturedAt
            photo.exifLatitude = photo.exifLatitude ?? prepared.latitude
            photo.exifLongitude = photo.exifLongitude ?? prepared.longitude

            try? context?.save()
        }
    }

    /// Step 4 — the `visit_photos` rows.
    private func upsertPhotoRows(for visit: Visit) async throws {
        let rows = visit.photos
            .sorted(by: { $0.order < $1.order })
            .compactMap { photo -> VisitPhotoUpsert? in
                guard let storagePath = photo.remoteStoragePath else { return nil }
                return VisitPhotoUpsert(
                    id: photo.id,
                    visitID: visit.id,
                    storagePath: storagePath,
                    thumbPath: photo.remoteThumbPath,
                    width: photo.pixelWidth,
                    height: photo.pixelHeight,
                    sortOrder: photo.order,
                    capturedAt: photo.capturedAt,
                    exifLatitude: photo.exifLatitude,
                    exifLongitude: photo.exifLongitude
                )
            }

        guard !rows.isEmpty else { return }

        try await client
            .from("visit_photos")
            .upsert(rows, onConflict: "id")
            .execute()
    }

    /// Bytes for a photo, preferring the on-disk copy written at capture time.
    private func loadLocalImageData(for photo: Photo) -> Data? {
        if let path = photo.relativePath {
            let url = FileStorage.url(forRelativePath: path)
            if let data = try? Data(contentsOf: url) { return data }
        }
        return nil
    }

    // MARK: - Deletions

    /// Tombstone every locally-deleted visit upstream, then clean its objects.
    ///
    /// The row is set `deleted_at` rather than DELETEd so other devices learn
    /// about it through the same `updated_at` watermark they use for edits — an
    /// incremental pull cannot observe an absence.
    private func drainDeletions(userID: UUID) async {
        guard let context else { return }

        let now = Date()
        let tombstones = ((try? context.fetch(Self.pendingDeletionsDescriptor(for: userID))) ?? [])
            .filter { ($0.nextAttemptAt ?? .distantPast) <= now }

        for tombstone in tombstones {
            if Task.isCancelled { return }
            do {
                try await client
                    .from("visits")
                    .update(["deleted_at": Date()])
                    .eq("id", value: tombstone.visitID.uuidString)
                    .eq("user_id", value: userID.uuidString)
                    .execute()

                // Objects go after the row, not before: if this half fails the
                // visit is still correctly gone from every device, and the worst
                // case is a few orphaned objects rather than a live visit whose
                // images have vanished.
                if !tombstone.storagePaths.isEmpty {
                    _ = try? await client.storage
                        .from(bucket)
                        .remove(paths: tombstone.storagePaths)
                }

                context.delete(tombstone)
                try? context.save()

            } catch {
                let failure = SyncFailure.classify(error)
                if case .authExpired = failure {
                    await handleAuthExpiry()
                    return
                }
                tombstone.attemptCount += 1
                tombstone.nextAttemptAt = backoffDate(for: tombstone.attemptCount)
                try? context.save()
            }
        }
    }

    // MARK: - Pull

    /// Fetch this user's visits and reconcile them into the local mirror.
    ///
    /// Incremental, keyed on a `lastPulledAt` watermark per user, so a repeat
    /// sync transfers only what changed.
    ///
    /// A nil watermark means a full fetch, which happens exactly when it should:
    /// first sign-in on this account, and a fresh install (the watermark lives in
    /// UserDefaults and goes with the app). There is no separate "force full"
    /// mode because nothing needs one — deletions, the thing an incremental fetch
    /// would otherwise miss, arrive as tombstone updates.
    private func pull(userID: UUID) async {
        guard let context else { return }

        let watermark = lastPulledAt(for: userID)
        // The server's clock, captured before the query, is the next watermark.
        // Using the device clock here is the classic way to lose rows: a device
        // running two seconds fast advances the watermark past writes that
        // landed in that window and never asks for them again. A small overlap
        // is harmless because reconcile is idempotent, so back the watermark off
        // by a few seconds rather than trusting either clock precisely.
        let pulledAt = Date().addingTimeInterval(-5)

        do {
            var query = client
                .from("visits")
                .select("*, place:places(*), photos:visit_photos(*)")
                .eq("user_id", value: userID.uuidString)

            if let watermark {
                query = query.gt("updated_at", value: SupabaseCoding.string(from: watermark))
            }

            let remote: [RemoteVisitWithRelations] = try await query
                .order("visited_at", ascending: false)
                .execute()
                .value

            for row in remote {
                reconcile(row, userID: userID)
            }
            try? context.save()

            setLastPulledAt(pulledAt, for: userID)
            lastSyncedAt = Date()
            lastError = nil

        } catch {
            let failure = SyncFailure.classify(error)
            if case .authExpired = failure {
                await handleAuthExpiry()
                return
            }
            // A failed pull is not worth an alert — the local mirror is still
            // correct, just possibly stale, and the next trigger retries.
            if case .permanent = failure {
                lastError = SupabaseErrorPresenter.presentable(error, context: .sync)
            }
        }
    }

    /// Merge one remote row into the local store.
    ///
    /// Conflict rule: **remote wins, unless the local row has unsent work.**
    ///
    /// The exception is the important half. A row in `pendingUpload` or `failed`
    /// holds an edit the server has never seen; overwriting it with the server's
    /// older copy would silently discard something the user typed. `uploading` is
    /// treated the same way — it means an attempt is in flight or was
    /// interrupted, and either way the local copy is the newer one.
    private func reconcile(_ row: RemoteVisitWithRelations, userID: UUID) {
        guard let context else { return }

        let existing = localVisit(id: row.id, userID: userID)

        // ---- Deletions ---------------------------------------------------
        if row.isDeleted {
            if let existing, !existing.syncState.isUnsent {
                deleteLocalFiles(for: existing)
                context.delete(existing)
            }
            // A locally-unsent row whose remote twin is deleted is left alone:
            // the user re-created or edited it after the delete, and their newer
            // intent wins. The next push un-deletes it upstream.
            return
        }

        if let existing {
            guard !existing.syncState.isUnsent else { return }   // local edit wins
            apply(row, to: existing, userID: userID)
        } else {
            let visit = Visit(
                id: row.id,
                visitedOn: row.visitedAt,
                title: row.title ?? row.place?.name ?? "",
                ownerUserID: userID
            )
            context.insert(visit)
            apply(row, to: visit, userID: userID)
        }
    }

    private func apply(_ row: RemoteVisitWithRelations, to visit: Visit, userID: UUID) {
        visit.visitedOn = row.visitedAt
        visit.title = row.title ?? row.place?.name ?? visit.title
        visit.tags = row.tags
        visit.enrichedDescription = row.summary ?? ""
        visit.transcript = row.transcript ?? ""
        visit.topQuote = row.topQuote ?? ""
        visit.rating = row.ratingLabel.flatMap(Rating.init(rawValue:))
        visit.returnIntent = row.returnIntent.flatMap(ReturnIntent.init(rawValue:))
        visit.kind = VisitKind(rawValue: row.kind) ?? .visited
        visit.ownerUserID = userID
        visit.remoteID = row.id
        visit.syncState = .synced
        visit.lastSyncedAt = Date()
        visit.syncError = nil
        visit.syncAttemptCount = 0
        visit.nextAttemptAt = nil

        if let remotePlace = row.place {
            visit.address = remotePlace.displayAddress ?? visit.address
            visit.place = localPlace(matching: remotePlace, userID: userID)
        }

        applyPhotos(row.photos, to: visit)
    }

    /// Reconcile photo rows.
    ///
    /// Bytes are **not** fetched here — only the rows. Downloading every image
    /// before the map can draw is exactly the "fresh install feels broken"
    /// failure the thumbnail decision was made to avoid. `PhotoView` pulls each
    /// one through `PhotoCache` when it is actually about to be shown.
    private func applyPhotos(_ remote: [RemoteVisitPhoto], to visit: Visit) {
        guard let context else { return }

        var existing = Dictionary(uniqueKeysWithValues: visit.photos.map { ($0.id, $0) })

        for row in remote.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let photo = existing.removeValue(forKey: row.id) ?? {
                let created = Photo(id: row.id, order: row.sortOrder)
                context.insert(created)
                created.visit = visit
                return created
            }()

            photo.order = row.sortOrder
            photo.remoteStoragePath = row.storagePath
            photo.remoteThumbPath = row.thumbPath
            photo.pixelWidth = row.width
            photo.pixelHeight = row.height
            photo.capturedAt = row.capturedAt
            photo.exifLatitude = row.exifLatitude
            photo.exifLongitude = row.exifLongitude
        }

        // Left over locally but absent remotely — deleted on another device.
        for orphan in existing.values {
            if let path = orphan.relativePath {
                FileStorage.shred(at: FileStorage.url(forRelativePath: path))
            }
            context.delete(orphan)
        }
    }

    /// Find or create the local mirror row for a remote place.
    ///
    /// Matched on `remotePlaceID` and scoped to the user, so the same venue
    /// pulled twice reuses one local row and two accounts on one device keep
    /// separate ones.
    private func localPlace(matching remote: RemotePlace, userID: UUID) -> Place {
        guard let context else {
            return Place(name: remote.name, category: .other, neighborhood: "", lat: remote.latitude, lng: remote.longitude)
        }

        // Both bound as optionals so the macro compares like-for-like against
        // the nullable columns — see `LocalStore.visitsPredicate`.
        let remoteID: UUID? = remote.id
        let owner: UUID? = userID
        let descriptor = FetchDescriptor<Place>(
            predicate: #Predicate<Place> { place in
                place.remotePlaceID == remoteID && place.ownerUserID == owner
            }
        )

        if let found = try? context.fetch(descriptor).first {
            found.name = remote.name
            found.lat = remote.latitude
            found.lng = remote.longitude
            if let neighborhood = remote.neighborhood { found.neighborhood = neighborhood }
            if let category = remote.category.flatMap(PlaceCategory.init(rawValue:)) {
                found.category = category
            }
            return found
        }

        let place = Place(
            name: remote.name,
            category: remote.category.flatMap(PlaceCategory.init(rawValue:)) ?? .other,
            neighborhood: remote.neighborhood ?? remote.locality ?? "",
            lat: remote.latitude,
            lng: remote.longitude,
            externalPOIId: remote.mapkitID,
            remotePlaceID: remote.id,
            ownerUserID: userID
        )
        context.insert(place)
        return place
    }

    // MARK: - Legacy data migration

    /// Claim pre-auth visits for the signing-in user, then sync.
    ///
    /// Visits captured before auth existed have `ownerUserID == nil`. They are
    /// invisible to every scoped query, so until they are claimed the user's own
    /// history looks like it vanished. Claiming is a local write and completes in
    /// milliseconds; the uploads that follow go through the ordinary pipeline and
    /// the ordinary retry policy, so a partial failure leaves some rows synced
    /// and the rest queued — nothing is lost either way.
    ///
    /// Deliberately not awaited by any UI. `migrationProgress` drives a
    /// non-blocking banner and the app is fully usable throughout.
    private func claimLegacyVisitsThenSync(userID: UUID) async {
        guard let context else { return }

        let orphans = (try? context.fetch(Self.unownedVisitsDescriptor())) ?? []

        if !orphans.isEmpty {
            for visit in orphans {
                visit.ownerUserID = userID
                visit.remoteID = visit.id
                visit.markDirty()
                visit.place?.ownerUserID = userID
            }
            // Places whose visits were all orphans (and any left dangling).
            let unownedPlaces = (try? context.fetch(Self.unownedPlacesDescriptor())) ?? []
            for place in unownedPlaces { place.ownerUserID = userID }

            try? context.save()

            migrationProgress = MigrationProgress(
                total: orphans.count,
                completed: 0,
                failed: 0
            )
        }

        refreshCounts()
        await runSync(reason: .appForeground)

        if migrationProgress != nil {
            updateMigrationProgress(claimed: orphans.map(\.id))
        }
    }

    private func updateMigrationProgress(claimed ids: [UUID]) {
        guard let context, !ids.isEmpty else {
            migrationProgress = nil
            return
        }
        let visits: [Visit] = ids.compactMap { id in
            let descriptor = FetchDescriptor<Visit>(predicate: #Predicate<Visit> { $0.id == id })
            return (try? context.fetch(descriptor))?.first
        }

        let completed = visits.filter { $0.syncState == .synced }.count
        let failed = visits.filter { $0.syncState == .failed }.count

        migrationProgress = MigrationProgress(
            total: ids.count,
            completed: completed,
            failed: failed
        )

        // Clear the banner once everything settled successfully. Failures stay
        // visible — they are surfaced by the ordinary failed-row UI, so the
        // banner has done its job and dismissing it avoids two indicators for
        // the same problem.
        if completed == ids.count {
            migrationProgress = nil
        }
    }

    // MARK: - Interrupted uploads

    /// Return rows stuck in `uploading` to `pendingUpload` on launch.
    ///
    /// `uploading` is only ever written just before network work starts and
    /// cleared the moment it ends, so finding one at launch means the process
    /// died mid-attempt. Re-queuing is safe precisely because every step of the
    /// pipeline is an upsert on a client-generated id: the retry converges on
    /// the same rows and reuses the same storage objects rather than making
    /// second copies.
    private func recoverInterruptedUploads() {
        guard let context, let userID else { return }

        let interrupted = (try? context.fetch(Self.uploadingVisitsDescriptor(for: userID))) ?? []
        guard !interrupted.isEmpty else { return }

        for visit in interrupted {
            visit.syncState = .pendingUpload
            visit.nextAttemptAt = nil
        }
        try? context.save()
    }

    // MARK: - Failure handling

    private func record(_ error: any Error, on visit: Visit) {
        guard let context else { return }

        let failure = SyncFailure.classify(error)

        if case .authExpired = failure {
            visit.syncState = .pendingUpload
            visit.syncError = failure.message
            try? context.save()
            Task { await handleAuthExpiry() }
            return
        }

        visit.syncAttemptCount += 1
        visit.syncError = failure.message
        // `lastSyncedAt` is deliberately untouched: it records the last time the
        // row actually reached the cloud, and a failed attempt did not.

        if failure.isRetryable {
            visit.syncState = .pendingUpload
            visit.nextAttemptAt = backoffDate(for: visit.syncAttemptCount)
        } else {
            // Permanent: stop retrying and let the user see it. The local row is
            // untouched — a failed upload must never cost the user their entry.
            visit.syncState = .failed
            visit.nextAttemptAt = nil
        }

        try? context.save()
    }

    /// Exponential backoff with full jitter, capped.
    ///
    /// Jitter matters even for a single-user app: without it, a batch that all
    /// failed on the same network blip retries in lockstep forever, so a server
    /// that is briefly unhealthy gets hit by the whole queue at once each round.
    private func backoffDate(for attempt: Int) -> Date {
        let exponential = baseBackoff * pow(2, Double(max(0, attempt - 1)))
        let capped = min(exponential, maxBackoff)
        let jittered = Double.random(in: (capped * 0.5)...capped)
        return Date().addingTimeInterval(jittered)
    }

    /// Refresh the session once, then give up and raise the auth gate.
    ///
    /// One attempt, not a loop: if the refresh token itself is dead, retrying
    /// cannot fix it, and every extra try is another round trip before the user
    /// gets told the one thing they can act on.
    private func handleAuthExpiry() async {
        guard !didAttemptSessionRefresh else {
            needsReauthentication = true
            lastError = PresentableError(
                title: "Session expired",
                message: "Sign in again to finish syncing. Nothing you've logged has been lost.",
                isRetryable: false
            )
            return
        }

        didAttemptSessionRefresh = true

        do {
            _ = try await client.auth.refreshSession()
            // Recovered — the rows are still pending and the next trigger picks
            // them up. Reset so a later, unrelated expiry gets its own attempt.
            didAttemptSessionRefresh = false
        } catch {
            needsReauthentication = true
            lastError = PresentableError(
                title: "Session expired",
                message: "Sign in again to finish syncing. Nothing you've logged has been lost.",
                isRetryable: false
            )
        }
    }

    // MARK: - Retry timer

    /// A slow tick that re-checks whether any backed-off row has come due.
    ///
    /// The two good triggers — app foreground and network-returned — cover most
    /// recoveries. This covers the rest: the app open in the foreground on a
    /// connection that is technically "satisfied" but failing, where no edge
    /// event will ever fire.
    private func startRetryTimer() {
        retryTimerTask?.cancel()
        retryTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.retryTickInterval ?? .seconds(20))
                guard let self, !Task.isCancelled else { return }
                guard self.container != nil, !self.needsReauthentication else { continue }
                guard NetworkMonitor.shared.isReachable else { continue }

                if self.hasWorkDue() {
                    self.requestSync(reason: .retryTimer)
                }
            }
        }
    }

    private func hasWorkDue() -> Bool {
        guard let context, let userID else { return false }
        let now = Date()

        let pending = (try? context.fetch(Self.pendingVisitsDescriptor(for: userID))) ?? []
        if pending.contains(where: { ($0.nextAttemptAt ?? .distantPast) <= now }) { return true }

        let deletions = (try? context.fetch(Self.pendingDeletionsDescriptor(for: userID))) ?? []
        return deletions.contains(where: { ($0.nextAttemptAt ?? .distantPast) <= now })
    }

    // MARK: - Counts

    func refreshCounts() {
        guard let context, let userID else {
            pendingCount = 0
            failedCount = 0
            return
        }

        let pending = (try? context.fetchCount(Self.pendingVisitsDescriptor(for: userID))) ?? 0
        let failed = (try? context.fetchCount(Self.failedVisitsDescriptor(for: userID))) ?? 0
        let deletions = (try? context.fetchCount(Self.pendingDeletionsDescriptor(for: userID))) ?? 0

        pendingCount = pending + deletions
        failedCount = failed
    }

    /// True when signing out would strand work. Drives the sign-out warning.
    var hasUnsyncedWork: Bool { pendingCount > 0 || failedCount > 0 }

    // MARK: - Watermark

    /// Per-user so switching accounts can't make one user's watermark suppress
    /// the other's first full fetch.
    private func watermarkKey(for userID: UUID) -> String {
        "nyc-tracker.lastPulledAt.\(userID.uuidString)"
    }

    private func lastPulledAt(for userID: UUID) -> Date? {
        let raw = UserDefaults.standard.double(forKey: watermarkKey(for: userID))
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    private func setLastPulledAt(_ date: Date, for userID: UUID) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: watermarkKey(for: userID))
    }

    /// Forget the watermark so the next pull is a full refetch. Used when the
    /// local store is wiped.
    func resetWatermark(for userID: UUID) {
        UserDefaults.standard.removeObject(forKey: watermarkKey(for: userID))
    }

    // MARK: - Local lookups

    private func localVisit(id: UUID, userID: UUID) -> Visit? {
        guard let context else { return nil }
        let owner: UUID? = userID
        let descriptor = FetchDescriptor<Visit>(
            predicate: #Predicate<Visit> { $0.id == id && $0.ownerUserID == owner }
        )
        return try? context.fetch(descriptor).first
    }

    private func deleteLocalFiles(for visit: Visit) {
        for photo in visit.photos {
            if let path = photo.relativePath {
                FileStorage.shred(at: FileStorage.url(forRelativePath: path))
            }
            if let thumb = photo.thumbRelativePath {
                FileStorage.shred(at: FileStorage.url(forRelativePath: thumb))
            }
        }
    }

    // MARK: - Descriptors

    private static func pendingVisitsDescriptor(for userID: UUID) -> FetchDescriptor<Visit> {
        let pending = SyncState.pendingUpload.rawValue
        let owner: UUID? = userID
        return FetchDescriptor<Visit>(
            predicate: #Predicate<Visit> { visit in
                visit.ownerUserID == owner && visit.syncStateRaw == pending
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
    }

    private static func failedVisitsDescriptor(for userID: UUID) -> FetchDescriptor<Visit> {
        let failed = SyncState.failed.rawValue
        let owner: UUID? = userID
        return FetchDescriptor<Visit>(
            predicate: #Predicate<Visit> { visit in
                visit.ownerUserID == owner && visit.syncStateRaw == failed
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
    }

    private static func uploadingVisitsDescriptor(for userID: UUID) -> FetchDescriptor<Visit> {
        let uploading = SyncState.uploading.rawValue
        let owner: UUID? = userID
        return FetchDescriptor<Visit>(
            predicate: #Predicate<Visit> { visit in
                visit.ownerUserID == owner && visit.syncStateRaw == uploading
            }
        )
    }

    private static func pendingDeletionsDescriptor(for userID: UUID) -> FetchDescriptor<PendingDeletion> {
        let owner: UUID? = userID
        return FetchDescriptor<PendingDeletion>(
            predicate: #Predicate<PendingDeletion> { $0.ownerUserID == owner },
            sortBy: [SortDescriptor(\.requestedAt)]
        )
    }

    private static func unownedVisitsDescriptor() -> FetchDescriptor<Visit> {
        FetchDescriptor<Visit>(predicate: #Predicate<Visit> { $0.ownerUserID == nil })
    }

    private static func unownedPlacesDescriptor() -> FetchDescriptor<Place> {
        FetchDescriptor<Place>(predicate: #Predicate<Place> { $0.ownerUserID == nil })
    }
}

// MARK: - Errors

enum SyncEngineError: LocalizedError {
    case visitHasNoPlace

    var errorDescription: String? {
        switch self {
        case .visitHasNoPlace:
            "This entry has no location, so it can't be synced."
        }
    }
}

// MARK: - Date formatting for query parameters

extension SupabaseCoding {
    /// PostgREST filter values go in the query string, not the JSON body, so the
    /// encoder's date strategy doesn't apply — the watermark has to be formatted
    /// by hand. Fractional-second UTC, which Postgres parses for timestamptz.
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
