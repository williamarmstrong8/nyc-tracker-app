import SwiftUI
import PhotosUI
import Photos

/// Displays a photo from any of the supported sources: an SF Symbol placeholder (seeded data),
/// a PhotosPickerItem (in the capture flow), an on-disk file (persisted), or a PHAsset local
/// identifier (fallback if we didn't get a file copy).
struct PhotoView: View {
    enum Source: Hashable {
        case sfSymbol(String)
        case pickerItem(PhotosPickerItem)
        case uiImage(UIImage)
        case relativePath(String)
        case phAssetIdentifier(String)
        /// An object in the `visit-photos` bucket, fetched through `PhotoCache`.
        case remote(path: String)
        /// A bundled asset-catalog image. Used by sample-data visits so the
        /// explore feed and friend cards can show a real photo without hitting
        /// storage.
        case asset(String)

        /// Friend-visit photos are storage paths, with two prefixed exceptions:
        /// sample data is `asset:<catalog name>` and renders from the bundle,
        /// and a message composed in sample mode is `local:<relative path>` and
        /// renders from the user's own photo storage — neither has a server
        /// object to fetch.
        static func friendPhoto(path: String) -> Source {
            if path.hasPrefix("asset:") {
                return .asset(String(path.dropFirst("asset:".count)))
            }
            if path.hasPrefix("local:") {
                return .relativePath(String(path.dropFirst("local:".count)))
            }
            return .remote(path: path)
        }

        /// Stable identity for `ImageMemoryCache`, or nil for a source that has
        /// nothing to cache.
        ///
        /// `.uiImage` and `.asset` are already decoded (one is handed in, the
        /// other is an asset-catalog image UIKit caches itself), and `.sfSymbol`
        /// draws a glyph. Everything else costs a file read, a decode, or a round
        /// trip, and gets a key.
        ///
        /// The prefixes matter: a relative path and a storage path can collide as
        /// bare strings, and a thumbnail and its full-size original are different
        /// images at different paths that must not share an entry.
        var cacheKey: String? {
            switch self {
            case .sfSymbol, .uiImage, .asset:
                return nil
            case .relativePath(let path):
                return "file:\(path)"
            case .phAssetIdentifier(let id):
                return "asset:\(id)"
            case .remote(let path):
                return "remote:\(path)"
            case .pickerItem(let item):
                // Non-nil because the picker is built with `photoLibrary: .shared()`.
                // Without that it would be nil and this source stays uncached,
                // which is the old behaviour and merely slower.
                return item.itemIdentifier.map { "picker:\($0)" }
            }
        }

        /// Build the best source for a persisted `Photo` row.
        ///
        /// The order is a preference ranking, cheapest and most reliable first:
        /// a local file needs no network, the photo library needs no network but
        /// may have been deleted, and the remote object always works but costs a
        /// round trip. After a reinstall only the last one is available, which is
        /// the case this ordering exists to handle without special-casing it.
        ///
        /// `wantsThumbnail` picks the ~400px object for small renders (map
        /// callouts, list rows). Fetching a 2048px image to draw it at 56pt is
        /// the difference between a list that populates immediately after a
        /// reinstall and one that trickles in over minutes.
        init(photo: Photo, wantsThumbnail: Bool = false) {
            if let symbol = photo.sfSymbol {
                self = .sfSymbol(symbol)
                return
            }

            if wantsThumbnail, let thumb = photo.thumbRelativePath,
               FileManager.default.fileExists(
                   atPath: FileStorage.url(forRelativePath: thumb).path
               ) {
                self = .relativePath(thumb)
                return
            }

            if let path = photo.relativePath,
               FileManager.default.fileExists(
                   atPath: FileStorage.url(forRelativePath: path).path
               ) {
                self = .relativePath(path)
                return
            }

            if wantsThumbnail, let remoteThumb = photo.remoteThumbPath {
                self = .remote(path: remoteThumb)
                return
            }
            if let remote = photo.remoteStoragePath {
                self = .remote(path: remote)
                return
            }
            if let asset = photo.assetLocalIdentifier {
                self = .phAssetIdentifier(asset)
                return
            }
            self = .sfSymbol("photo")
        }
    }

    let source: Source
    var contentMode: ContentMode = .fill

    /// Seeded synchronously from `ImageMemoryCache` so an image that has already
    /// been decoded is drawn in this view's very first frame.
    ///
    /// This is the difference between a photo grid that scrolls and one that
    /// blinks: `LazyVGrid` and `List` build a brand-new `PhotoView` every time a
    /// cell is recycled, and a `@State` starting at nil means every one of those
    /// shows the placeholder until an async hop completes — for a photo the app
    /// decoded a second ago.
    @State private var loaded: UIImage?

    /// Which source `loaded` came from.
    ///
    /// SwiftUI reuses a view's identity — and therefore its `@State` — when only
    /// the source changes, which is exactly what a recycled grid cell and a
    /// swiped carousel page both do. Without this, "I already have an image"
    /// cannot be told apart from "I already have *this* image", and the view
    /// keeps drawing the previous photo.
    @State private var loadedKey: String?

    init(source: Source, contentMode: ContentMode = .fill) {
        self.source = source
        self.contentMode = contentMode
        let key = source.cacheKey
        let cached = key.flatMap { ImageMemoryCache.shared.image(forKey: $0) }
        _loaded = State(initialValue: cached)
        _loadedKey = State(initialValue: cached == nil ? nil : key)
    }

    var body: some View {
        Group {
            switch source {
            case .sfSymbol(let name):
                symbolPlaceholder(name: name)
            case .pickerItem, .relativePath, .phAssetIdentifier, .remote:
                if let loaded {
                    Image(uiImage: loaded)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    loadingPlaceholder
                }
            case .uiImage(let image):
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            case .asset(let name):
                Image(name)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            }
        }
        // `.fill` otherwise sizes the image to its own aspect, so a landscape
        // photo is wider than a square / 3:4 tile and paints into its neighbors.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .task(id: source) {
            await loadIfNeeded()
        }
    }

    private func loadIfNeeded() async {
        let key = source.cacheKey

        if let key {
            // Already showing this exact image — either `init` found it in the
            // cache, or a previous run of this loaded it. Nothing to do, and no
            // placeholder was ever shown.
            if loadedKey == key { return }

            // A different source than the one on screen. Drop the old image so a
            // recycled cell shows its placeholder rather than the last cell's
            // photo, then take the cached decode if there is one.
            if loaded != nil { loaded = nil }
            if let cached = ImageMemoryCache.shared.image(forKey: key) {
                loaded = cached
                loadedKey = key
                return
            }
        }

        switch source {
        case .pickerItem(let item):
            // Cacheable only when the picker was built with
            // `photoLibrary: .shared()`, which is what makes `itemIdentifier`
            // non-nil. Without it the decode still moves off the main actor;
            // it just isn't kept.
            if let data = try? await item.loadTransferable(type: Data.self) {
                if let key {
                    self.loaded = await ImageMemoryCache.shared.decodedImage(from: data, key: key)
                } else {
                    self.loaded = UIImage(data: data)
                }
            }
        case .relativePath(let path):
            // The read and the JPEG decode both used to happen right here on the
            // main actor, on every cell recycle. Both now happen off it, once.
            self.loaded = await ImageMemoryCache.shared.decodedImage(
                contentsOf: FileStorage.url(forRelativePath: path),
                key: key ?? "file:\(path)"
            )
        case .phAssetIdentifier(let id):
            // No `Data` to hand to the cache — `PHImageManager` returns a
            // rendered `UIImage` — so this inserts the result directly instead of
            // going through the decode helper.
            let image = await Self.loadFromPhotoLibrary(identifier: id)
            if let image, let key {
                ImageMemoryCache.shared.insert(image, forKey: key)
            }
            self.loaded = image
        case .remote(let path):
            // Lazy by design: this runs when the view is about to draw, not
            // during the pull. A fresh install therefore shows its map and list
            // immediately and fills images in as they scroll into view.
            guard let url = await PhotoCache.shared.file(for: path) else { return }
            self.loaded = await ImageMemoryCache.shared.decodedImage(
                contentsOf: url,
                key: key ?? "remote:\(path)"
            )
        default:
            break
        }

        // Record what is on screen only if something actually landed. A failed
        // load leaves this nil so a later appearance retries rather than
        // treating the placeholder as the final answer.
        if loaded != nil { loadedKey = key }
    }

    private static func loadFromPhotoLibrary(identifier: String) async -> UIImage? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else { return nil }
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        // The image request can fire the callback twice (degraded + final); guard so we resume once.
        let box = ResumeBox()
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            manager.requestImage(
                for: asset,
                targetSize: CGSize(width: 1200, height: 1200),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                if box.resume() {
                    continuation.resume(returning: image)
                }
            }
        }
    }

    @ViewBuilder
    private func symbolPlaceholder(name: String) -> some View {
        ZStack {
            LinearGradient(colors: [Color(uiColor: .tertiarySystemFill),
                                    Color(uiColor: .secondarySystemFill)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: name)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
        }
    }

    private var loadingPlaceholder: some View {
        ZStack {
            Color(uiColor: .tertiarySystemFill)
            ProgressView()
        }
    }
}

/// Small helper so the PHImageManager callback can resume its continuation exactly once.
private final class ResumeBox: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func resume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}
