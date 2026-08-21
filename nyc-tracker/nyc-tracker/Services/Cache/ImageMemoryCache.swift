import Foundation
import UIKit

/// Decoded images, held in memory, shared by every image surface in the app.
///
/// ## Why this is a separate layer from `PhotoCache` / `AvatarCache`
///
/// Those two answer "where are the bytes". This answers "have I already turned
/// those bytes into a `UIImage`". They are worth separating because the second
/// question is the expensive one and it is asked far more often: a lazy grid
/// recycles cells constantly, and without this every recycle re-reads a JPEG
/// from disk and re-decodes it. Bytes-on-disk caching removes the network round
/// trip; only this removes the per-frame work.
///
/// ## Cost accounting
///
/// `NSCache` evicts by an abstract "cost", so the cost here is the decoded byte
/// count — width × height × 4 — not the file size. A 2048px JPEG is ~350 KB on
/// disk and ~16 MB decoded, and budgeting by the former would let a few dozen
/// images quietly occupy hundreds of megabytes.
///
/// `NSCache` also evicts on its own under memory pressure, which is the reason
/// to use it rather than a dictionary: this cache is pure convenience and every
/// entry can be rebuilt from disk, so the OS is welcome to take all of it back
/// the moment anything else needs the memory.
final class ImageMemoryCache {

    /// Visit photos — up to 2048px, ~16 MB decoded each.
    ///
    /// ~120 MB of decoded pixels. Enough to hold a screenful of a photo grid
    /// plus what is just off-screen in either direction, which is the working
    /// set that matters for scrolling. `NSCache` gives it all back under
    /// pressure, so this is a ceiling rather than a reservation.
    static let shared = ImageMemoryCache(costLimitBytes: 120 * 1024 * 1024)

    /// Avatars — capped at 512px, ~1 MB decoded each.
    ///
    /// A separate instance, not a shared budget line, because avatars and
    /// visit photos are drawn on completely different screens with wildly
    /// different working sets. When both lived in one `NSCache`, scrolling a
    /// handful of full-size photos was enough to blow the shared budget and
    /// evict every avatar that had been decoded — so a face the app had
    /// already drawn once would still re-decode (and briefly show its
    /// fallback) the next time a friends list or chat thread appeared. ~24 MB
    /// holds dozens of avatars at once, far more than a screen of faces ever
    /// shows, and a busy photo grid can no longer touch it.
    static let avatars = ImageMemoryCache(costLimitBytes: 24 * 1024 * 1024)

    private let cache: NSCache<NSString, UIImage>

    init(costLimitBytes: Int) {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = costLimitBytes
        self.cache = cache
    }

    // MARK: - Lookup

    /// Synchronous and cheap, so a view body can ask before deciding whether it
    /// needs a placeholder at all. Returning an image here is what makes a
    /// recycled cell draw its photo in the same frame instead of flashing a
    /// spinner.
    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
    }

    // MARK: - Decoding

    /// Decode `data` off the main actor and cache the result.
    ///
    /// `UIImage(data:)` is lazy — it parses the header and defers the actual
    /// decode until the image is first drawn, which lands it back on the main
    /// thread during a scroll, exactly where it hurts. `preparingForDisplay()`
    /// forces that work to happen here instead.
    func decodedImage(from data: Data, key: String) async -> UIImage? {
        if let cached = image(forKey: key) { return cached }

        let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let image = UIImage(data: data) else { return nil }
            return image.preparingForDisplay() ?? image
        }.value

        guard let decoded else { return nil }
        insert(decoded, forKey: key)
        return decoded
    }

    /// Read a file and decode it, both off the main actor.
    ///
    /// The read is deliberately part of this rather than left to the caller:
    /// `Data(contentsOf:)` on the main thread is a synchronous disk hit, and the
    /// call sites that need it are the ones drawing during a scroll.
    func decodedImage(contentsOf url: URL, key: String) async -> UIImage? {
        if let cached = image(forKey: key) { return cached }

        let decoded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            // Read into memory rather than mapping the file. These live in
            // `Caches/`, where both this app's eviction and the OS's can delete
            // a file at any moment — and a mapped page whose backing file is
            // unlinked mid-decode faults rather than failing.
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else { return nil }
            return image.preparingForDisplay() ?? image
        }.value

        guard let decoded else { return nil }
        insert(decoded, forKey: key)
        return decoded
    }

    // MARK: - Clearing

    /// Sign-out. The disk layers are cleared alongside this; leaving decoded
    /// pixels behind would let the next account see the previous one's photos
    /// for as long as the process lives.
    func clear() {
        cache.removeAllObjects()
    }

    private static func cost(of image: UIImage) -> Int {
        let pixels = Int(image.size.width * image.scale) * Int(image.size.height * image.scale)
        return pixels * 4
    }
}
