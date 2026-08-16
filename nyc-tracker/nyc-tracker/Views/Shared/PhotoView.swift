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

    @State private var loaded: UIImage?

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
            }
        }
        .task(id: source) {
            await loadIfNeeded()
        }
    }

    private func loadIfNeeded() async {
        switch source {
        case .pickerItem(let item):
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                self.loaded = image
            }
        case .relativePath(let path):
            let url = FileStorage.url(forRelativePath: path)
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                self.loaded = image
            }
        case .phAssetIdentifier(let id):
            self.loaded = await Self.loadFromPhotoLibrary(identifier: id)
        case .remote(let path):
            // Lazy by design: this runs when the view is about to draw, not
            // during the pull. A fresh install therefore shows its map and list
            // immediately and fills images in as they scroll into view.
            if let url = await PhotoCache.shared.file(for: path),
               let data = try? Data(contentsOf: url),
               let image = UIImage(data: data) {
                self.loaded = image
            }
        default:
            break
        }
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
