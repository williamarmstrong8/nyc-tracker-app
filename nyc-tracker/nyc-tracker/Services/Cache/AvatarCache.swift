import Foundation
import UIKit

/// Profile pictures, cached until the person changes theirs.
///
/// ## Why the URL is the whole invalidation story
///
/// `ProfileService.uploadAvatar` writes to a fixed path per user
/// (`avatars/{user_id}/avatar.jpg`) and appends a cache-busting `?v=<timestamp>`
/// to the URL it stores on the profile row. That query item exists so the CDN
/// stops serving the old image, but it does something more useful here: it makes
/// the URL a *version identifier*. Two different URLs are two different images,
/// and the same URL is always the same bytes.
///
/// So this cache treats an avatar as immutable and never expires it. There is no
/// TTL, no revalidation, no conditional request — the only thing that can
/// invalidate a cached avatar is the person uploading a new one, and when they do
/// their profile row carries a new URL and this fetches once more. That is
/// exactly "cache the profile picture until it's updated", with no freshness
/// policy to get wrong.
///
/// The previous version is deleted as the new one lands (see `identityToken`), so
/// a user who changes their picture weekly leaves one file behind, not fifty.
///
/// ## Where the bytes live
///
/// `Caches/`, like `PhotoCache` and for the same reasons: every byte is
/// re-downloadable from a public bucket, so it must never enter a backup and the
/// OS is welcome to reclaim it. Avatars are small and read constantly, which is
/// why they get their own directory and their own generous cap rather than
/// competing for space with 2048px visit photos.
///
/// Decoded images go to `ImageMemoryCache`, which is what actually stops a
/// friends list from re-decoding forty JPEGs every time it scrolls.
final class AvatarCache {

    static let shared = AvatarCache()

    /// ~40 MB. At the ~60 KB a rendered avatar lands at, that is hundreds of
    /// people — far more than anyone's friend list, with room for the search
    /// results and message threads that also draw faces.
    private let maxBytes: Int64 = 40 * 1024 * 1024
    private var evictionTargetBytes: Int64 { maxBytes * 3 / 4 }

    private let directory: URL
    private let fileManager = FileManager.default

    /// One fetch per URL, however many views ask. A friends list showing the
    /// same person in a row and in a message preview is one download.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Faces the app has already shown, kept as strong references.
    ///
    /// `ImageMemoryCache` uses `NSCache`, which is free to drop everything under
    /// memory pressure — and opening a chat full of place photos routinely does
    /// exactly that. Without this pin, popping back to Friends recreates every
    /// `AvatarImage` with an empty `@State`, misses the purged `NSCache`, and
    /// flashes initials for a frame while disk reloads. Avatars are tiny; a few
    /// dozen strong refs is the right trade for never flickering on navigation.
    private var pinned: [String: UIImage] = [:]
    private var pinOrder: [String] = []
    private let pinLimit = 64

    private init() {
        let caches = (try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory

        directory = caches.appendingPathComponent("NYCLogAvatars", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Lookup

    /// The decoded image if it is already available locally — pin, `NSCache`, or
    /// disk — without going async.
    ///
    /// Synchronous so a view body can draw the avatar in its first frame. This
    /// is what removes the initials-then-image flicker on every scroll and on
    /// every navigation back to a screen of faces. The asynchronous path below
    /// only runs the first time a face is seen (or after a cold launch before
    /// the pin is warm).
    func cachedImage(for urlString: String) -> UIImage? {
        let key = cacheKey(for: urlString)
        if let pinned = pinned[key] { return pinned }

        if let cached = ImageMemoryCache.avatars.image(forKey: key) {
            pin(cached, forKey: key)
            return cached
        }

        // Disk is the backstop when `NSCache` was purged. Avatar JPEGs are tens
        // of kilobytes; a sync read here is cheaper than a visible flicker.
        let fileURL = localURL(for: urlString)
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else {
            return nil
        }
        touch(fileURL)
        ImageMemoryCache.avatars.insert(image, forKey: key)
        pin(image, forKey: key)
        return image
    }

    /// The avatar, from memory, then disk, then the network.
    ///
    /// Returns nil on any failure. The caller's fallback is initials on the
    /// person's palette colour, which is a perfectly good avatar — so there is
    /// nothing useful for a view to do with an error.
    func image(for urlString: String) async -> UIImage? {
        if let cached = cachedImage(for: urlString) { return cached }

        if let existing = inFlight[urlString] { return await existing.value }

        let key = cacheKey(for: urlString)
        let fileURL = localURL(for: urlString)
        if fileManager.fileExists(atPath: fileURL.path) {
            touch(fileURL)
            if let image = await ImageMemoryCache.avatars.decodedImage(contentsOf: fileURL, key: key) {
                pin(image, forKey: key)
                return image
            }
            // A file that won't decode is a truncated download from a killed
            // process. Drop it so the fetch below can replace it.
            try? fileManager.removeItem(at: fileURL)
        }

        guard let url = URL(string: urlString) else { return nil }

        let task = Task { [weak self] () -> UIImage? in
            guard let self else { return nil }
            defer { self.inFlight[urlString] = nil }

            guard let (data, response) = try? await URLSession.shared.data(from: url) else {
                return nil
            }
            // A 404 for a deleted avatar comes back as a perfectly valid body of
            // XML error text. Writing that to disk would cache a permanent
            // failure that only a reinstall clears.
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }

            self.write(data, for: urlString)
            guard let image = await ImageMemoryCache.avatars.decodedImage(from: data, key: key) else {
                return nil
            }
            self.pin(image, forKey: key)
            return image
        }

        inFlight[urlString] = task
        return await task.value
    }

    // MARK: - Priming

    /// Seed the cache with bytes the app already has in hand.
    ///
    /// Called straight after an avatar upload. Without it the user's own new
    /// picture is the one image in the app that has to be downloaded to be seen —
    /// they just supplied it, so re-fetching it from the CDN (which may not even
    /// have it yet) is both slower and less reliable than using what's local.
    func prime(_ data: Data, for urlString: String) {
        write(data, for: urlString)
        let key = cacheKey(for: urlString)
        Task {
            guard let image = await ImageMemoryCache.avatars.decodedImage(from: data, key: key) else {
                return
            }
            pin(image, forKey: key)
        }
    }

    // MARK: - Clearing

    /// Sign-out. Faces are the most identifying thing cached anywhere in the
    /// app, so they go with the session — both the files and the decoded
    /// copies in `ImageMemoryCache.avatars`, which otherwise would keep
    /// drawing the previous account's faces for as long as the process lives.
    func clear() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        pinned.removeAll()
        pinOrder.removeAll()
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        ImageMemoryCache.avatars.clear()
    }

    // MARK: - Pinning

    private func pin(_ image: UIImage, forKey key: String) {
        if pinned[key] != nil {
            pinOrder.removeAll { $0 == key }
        }
        pinned[key] = image
        pinOrder.append(key)
        while pinOrder.count > pinLimit {
            let evicted = pinOrder.removeFirst()
            pinned.removeValue(forKey: evicted)
        }
    }

    // MARK: - Paths

    private func cacheKey(for urlString: String) -> String { "avatar:\(urlString)" }

    /// `<who>-<which version>.jpg`.
    ///
    /// Split in two on purpose. The first token is the storage path without the
    /// query — stable for the lifetime of the account — and the second is the
    /// `?v=` stamp that changes on every upload. Keeping them as separate tokens
    /// is what lets `write` find and delete a person's previous avatar by prefix
    /// instead of leaving one file per upload to age out on its own.
    private func localURL(for urlString: String) -> URL {
        directory.appendingPathComponent("\(identityToken(for: urlString))-\(versionToken(for: urlString)).jpg")
    }

    private func identityToken(for urlString: String) -> String {
        let components = URLComponents(string: urlString)
        return StableHash.filenameToken(components?.path ?? urlString)
    }

    private func versionToken(for urlString: String) -> String {
        let components = URLComponents(string: urlString)
        return StableHash.filenameToken(components?.query ?? "")
    }

    private func write(_ data: Data, for urlString: String) {
        let destination = localURL(for: urlString)
        guard (try? data.write(to: destination, options: .atomic)) != nil else { return }
        removeOtherVersions(of: urlString, keeping: destination)
        evictIfNeeded()
    }

    /// Delete every other cached version of the same person's avatar.
    ///
    /// This is the "until it's updated" half of the contract: the moment a newer
    /// image is on disk, the one it replaced is worthless — nothing will ever ask
    /// for the old URL again, because the profile row no longer contains it.
    private func removeOtherVersions(of urlString: String, keeping destination: URL) {
        let prefix = "\(identityToken(for: urlString))-"
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in contents
        where url.lastPathComponent.hasPrefix(prefix) && url != destination {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Eviction

    private func touch(_ url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Least-recently-used by the filesystem's own modification date, swept down
    /// to 75% of the cap so a full cache doesn't rescan on every insert. Same
    /// policy as `PhotoCache`, and the eviction that actually matters is the
    /// per-person one above — this is the backstop for a very large friend graph.
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
            entries.append((url, size, values?.contentModificationDate ?? .distantPast))
            total += size
        }

        guard total > maxBytes else { return }

        for entry in entries.sorted(by: { $0.accessed < $1.accessed }) {
            guard total > evictionTargetBytes else { break }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
