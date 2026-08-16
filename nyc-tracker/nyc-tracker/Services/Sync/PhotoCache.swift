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
    func clear() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Paths

    /// Storage paths contain slashes (`{user}/{visit}/{photo}.jpg`), which cannot
    /// go into a flat filename. Hashing keeps the mapping stable and collision-free
    /// enough without creating a directory tree that then has to be pruned.
    private func localURL(for storagePath: String) -> URL {
        let name = String(format: "%016llx", UInt64(bitPattern: Int64(stableHash(storagePath))))
        let ext = (storagePath as NSString).pathExtension
        return directory.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
    }

    /// FNV-1a. `Hasher` is explicitly seeded per process, so its values differ
    /// between launches — using it here would orphan the entire cache on every
    /// cold start while still counting the files against the size cap.
    private func stableHash(_ string: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int64(bitPattern: hash)
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
