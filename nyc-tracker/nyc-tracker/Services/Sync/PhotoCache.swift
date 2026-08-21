import Foundation
import Supabase

/// Bounded on-disk cache for photos pulled down from Supabase Storage.
///
/// After a reinstall the local store has `visit_photos` rows but no bytes. This
/// is where the bytes land as they are fetched, so the second look at a visit is
/// instant and works offline.
///
/// It lives in `Caches/`, not Application Support, and that choice is the whole
/// design: every file here is re-downloadable from the object it came from, so
/// the OS is welcome to delete it under storage pressure and it must never be
/// backed up. Locally-captured photos — the ones that exist *only* on the device
/// until they upload — stay in Application Support under `FileStorage` and are
/// never touched by eviction. Losing one of those loses user data; losing one of
/// these costs a round trip.
///
/// ## Eviction
///
/// Least-recently-used, by the filesystem's own access date, run when the
/// directory exceeds `maxBytes`. It sweeps down to `evictionTargetBytes` (75% of
/// the cap) rather than to exactly the cap, so a cache sitting right at the limit
/// doesn't run a scan on every single insert.
@MainActor
@Observable
final class PhotoCache {

    static let shared = PhotoCache()

    /// ~250 MB. At the ~350 KB a 2048px JPEG lands at, that is roughly 700 full
    /// images, or several years of logging for one person, while staying small
    /// enough that iOS is unlikely to be pressured into purging it.
    private let maxBytes: Int64 = 250 * 1024 * 1024
    private var evictionTargetBytes: Int64 { maxBytes * 3 / 4 }

    /// Prefetch bounds. Three at a time is enough to keep the connection busy
    /// without competing with the image a view is waiting on, and 40 paths is
    /// roughly two screens of the profile grid — past that the user has scrolled
    /// and the lazy path is a better predictor than anything decided up front.
    private let prefetchConcurrency = 3
    private let prefetchLimit = 40

    private let directory: URL
    private let fileManager = FileManager.default

    /// Paths currently being fetched, so two views showing the same photo don't
    /// each start a download. The second awaits the first's task.
    private var inFlight: [String: Task<URL?, Never>] = [:]

    private var client: SupabaseClient { SupabaseManager.client }
    private let bucket = "visit-photos"

    private init() {
        let caches = (try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory

        directory = caches.appendingPathComponent("NYCLogPhotos", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Lookup

    /// Local URL for a storage path if it is already cached, without fetching.
    ///
    /// Synchronous and cheap so a view body can ask before deciding to show a
    /// placeholder.
    func cachedURL(for storagePath: String) -> URL? {
        let url = localURL(for: storagePath)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        touch(url)
        return url
    }

    /// Return the cached file, downloading it if necessary.
    ///
    /// Returns nil on any failure — a missing photo renders as a placeholder,
    /// which is the correct outcome for an image that is offline or gone. Callers
    /// are view code and have nothing useful to do with an error.
    func file(for storagePath: String) async -> URL? {
        if let cached = cachedURL(for: storagePath) { return cached }

        if let existing = inFlight[storagePath] {
            return await existing.value
        }

        let task = Task { [weak self] () -> URL? in
            guard let self else { return nil }
            defer { self.inFlight[storagePath] = nil }

            do {
                let data = try await self.client.storage
                    .from(self.bucket)
                    .download(path: storagePath)

                let destination = self.localURL(for: storagePath)
                try data.write(to: destination, options: .atomic)
                self.evictIfNeeded()
                return destination
            } catch {
                return nil
            }
        }

        inFlight[storagePath] = task
        return await task.value
    }

    /// Drop everything. Called on sign-out so the next account can't read the
    /// previous one's images out of the cache.
    ///
    /// Deleting the files is not sufficient on its own: `ImageMemoryCache` holds
    /// the *decoded* versions of the same photos and outlives the session, so a
    /// disk-only clear would leave the previous account's images drawable for as
    /// long as the process lives.
    func clear() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        ImageMemoryCache.shared.clear()
    }

    // MARK: - Prefetch

    /// Warm the cache for photos that are about to be needed.
    ///
    /// The lazy path in `PhotoView` is still what fetches anything that actually
    /// gets drawn; this only moves the round trip earlier for a set the caller
    /// knows it is about to render — the first rows of the profile activity
    /// grid, the photos of the visits just returned for the map. The difference
    /// is a grid that fills in as the user's thumb arrives versus one that
    /// starts downloading when it does.
    ///
    /// Bounded on both axes: at most `prefetchLimit` paths, at most
    /// `prefetchConcurrency` at a time. An unbounded version of this is how a
    /// prefetch turns into a stampede that starves the image the user is
    /// actually looking at.
    func prefetch(_ storagePaths: [String]) {
        // `cachedURL` bumps the LRU date as it checks, which is the right side
        // effect here: a path we were about to fetch is a path about to be drawn.
        let wanted = Array(
            storagePaths
                .prefix(prefetchLimit)
                .filter { cachedURL(for: $0) == nil && inFlight[$0] == nil }
        )
        guard !wanted.isEmpty else { return }
        let concurrency = min(prefetchConcurrency, wanted.count)

        Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                while next < concurrency {
                    let path = wanted[next]
                    group.addTask { _ = await self?.file(for: path) }
                    next += 1
                }
                // Refill as each finishes, so `concurrency` requests stay in
                // flight rather than the whole list going out at once.
                while await group.next() != nil {
                    guard next < wanted.count else { continue }
                    let path = wanted[next]
                    next += 1
                    group.addTask { _ = await self?.file(for: path) }
                }
            }
        }
    }

    // MARK: - Paths

    /// Storage paths contain slashes (`{user}/{visit}/{photo}.jpg`), which cannot
    /// go into a flat filename. Hashing keeps the mapping stable and collision-free
    /// enough without creating a directory tree that then has to be pruned.
    private func localURL(for storagePath: String) -> URL {
        let name = StableHash.filenameToken(storagePath)
        let ext = (storagePath as NSString).pathExtension
        return directory.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
    }

    // MARK: - Eviction

    /// Bump the access date so LRU ordering reflects reads, not just writes.
    private func touch(_ url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func evictIfNeeded() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ) else { return }

        var entries: [(url: URL, size: Int64, accessed: Date)] = []
        var total: Int64 = 0

        for url in contents {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.fileSize ?? 0)
            let accessed = values?.contentModificationDate ?? .distantPast
            entries.append((url, size, accessed))
            total += size
        }

        guard total > maxBytes else { return }

        // Oldest first, deleting until under target.
        for entry in entries.sorted(by: { $0.accessed < $1.accessed }) {
            guard total > evictionTargetBytes else { break }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
