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

        /// Build the best source for a persisted `Photo` row.
        init(photo: Photo) {
            if let symbol = photo.sfSymbol {
                self = .sfSymbol(symbol)
            } else if let path = photo.relativePath {
                self = .relativePath(path)
            } else if let asset = photo.assetLocalIdentifier {
                self = .phAssetIdentifier(asset)
            } else {
                self = .sfSymbol("photo")
            }
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
            case .pickerItem, .relativePath, .phAssetIdentifier:
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
