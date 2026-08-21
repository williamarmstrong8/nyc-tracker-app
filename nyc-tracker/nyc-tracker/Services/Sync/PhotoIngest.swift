import Foundation
import Photos
import PhotosUI
import SwiftUI

/// Turns picked library items into `Photo` rows with their bytes already on disk.
///
/// Both capture entry points (a real visit and a want-to-try) funnel through
/// here, so the resize, the thumbnail, and the EXIF read happen in exactly one
/// place. Previously each screen had its own copy that wrote the raw picker data
/// straight to disk — meaning a 4 MB HEIC per photo locally and, once sync
/// existed, a 4 MB upload too.
///
/// Downscaling here rather than at upload time is deliberate. The work happens
/// once at save time instead of on every retry of a failed upload; the local
/// file and the uploaded file are byte-identical, so a resumed upload re-reads
/// rather than re-encodes; and the on-disk footprint drops by roughly an order
/// of magnitude for images the app never draws above 2048px anyway.
enum PhotoIngest {

    /// Prepare every picked item, in order. Failures are skipped rather than
    /// fatal — one unreadable image should not cost the user the whole entry.
    @MainActor
    static func rows(from items: [PhotosPickerItem]) async -> [Photo] {
        var rows: [Photo] = []

        for (index, item) in items.enumerated() {
            guard let source = try? await item.loadTransferable(type: Data.self) else {
                continue
            }

            // Off the main actor: decode + downscale + encode, twice, per photo.
            let prepared = try? await Task.detached(priority: .userInitiated) {
                try ImagePreparer.prepare(source)
            }.value

            guard let prepared else {
                // Undecodable. Keep the asset reference so `PhotoView` can still
                // fall back to rendering it straight from the photo library.
                rows.append(Photo(assetLocalIdentifier: item.itemIdentifier, order: index))
                continue
            }

            let fullPath = try? FileStorage.writeData(
                prepared.fullJPEG, kind: .photos, fileExtension: "jpg"
            )
            let thumbPath = try? FileStorage.writeData(
                prepared.thumbnailJPEG, kind: .photos, fileExtension: "jpg"
            )

            // Prefer the PHAsset's own metadata when we can get it: the library
            // keeps location and creation date as first-class properties, which
            // survive edits and screenshots that strip EXIF from the pixel data.
            let assetMetadata = await assetMetadata(for: item.itemIdentifier)

            rows.append(Photo(
                relativePath: fullPath?.relativePath,
                thumbRelativePath: thumbPath?.relativePath,
                assetLocalIdentifier: item.itemIdentifier,
                order: index,
                capturedAt: assetMetadata.capturedAt ?? prepared.capturedAt,
                exifLatitude: assetMetadata.latitude ?? prepared.latitude,
                exifLongitude: assetMetadata.longitude ?? prepared.longitude,
                pixelWidth: prepared.width,
                pixelHeight: prepared.height
            ))
        }

        return rows
    }

    // MARK: - PHAsset metadata

    private struct AssetMetadata {
        var capturedAt: Date?
        var latitude: Double?
        var longitude: Double?
    }

    /// Returns empties if photo-library access is denied, which is fine — the
    /// EXIF read from the image data is the fallback, and a photo with neither
    /// simply has null metadata columns.
    private static func assetMetadata(for identifier: String?) async -> AssetMetadata {
        guard let identifier else { return AssetMetadata() }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else { return AssetMetadata() }

        return AssetMetadata(
            capturedAt: asset.creationDate,
            latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude
        )
    }
}
