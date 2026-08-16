import Foundation
import CoreGraphics
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Turns a camera-roll image into the two JPEGs the app actually stores, and
/// rescues the metadata before throwing the rest away.
///
/// Straight off an iPhone a photo is 3–5 MB of HEIC at 12 megapixels. Uploading
/// that is slow on cellular, expensive in the bucket, and pointless — the largest
/// this app ever draws one is a full-width carousel on a Pro Max, well under
/// 2048px on the long edge. So every image goes through here exactly once, at
/// capture time, and both the local copy and the uploaded copy are the output.
/// Nothing re-encodes on the upload path, which is what keeps a retry cheap.
///
/// ## Metadata
///
/// Re-encoding through CoreGraphics drops EXIF as a side effect, which is the
/// behaviour we want for a file served from a public bucket — but only *after*
/// the interesting parts have been read out and put somewhere access-controlled.
/// `prepare` returns them alongside the bytes; the caller writes them to the
/// `visit_photos` row.
///
/// Marked `nonisolated` throughout. The project sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without this every resize
/// would run on the main thread and a 5-photo visit would visibly hitch the
/// capture flow. Callers hop to a background task and await the result.
nonisolated enum ImagePreparer {

    /// Long-edge cap for the uploaded/stored image.
    static let fullMaxDimension: CGFloat = 2048
    /// Long-edge cap for the thumbnail used in map callouts and list rows.
    static let thumbMaxDimension: CGFloat = 400

    static let fullQuality: CGFloat = 0.8
    /// Thumbnails compress harder — at 400px the artifacts are invisible and the
    /// byte count is what decides how fast a fresh install stops looking empty.
    static let thumbQuality: CGFloat = 0.7

    struct Prepared: Sendable {
        var fullJPEG: Data
        var thumbnailJPEG: Data
        /// Pixel dimensions of `fullJPEG`, for the `visit_photos` row.
        var width: Int
        var height: Int
        var capturedAt: Date?
        var latitude: Double?
        var longitude: Double?
    }

    enum PrepareError: LocalizedError {
        case undecodable
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .undecodable:    "That image couldn't be read."
            case .encodingFailed: "That image couldn't be converted for upload."
            }
        }
    }

    /// Read metadata, downscale, strip, encode. One pass over the source bytes.
    static func prepare(_ source: Data) throws -> Prepared {
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, nil) else {
            throw PrepareError.undecodable
        }

        let metadata = readMetadata(from: imageSource)

        // `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailFromImageAlways`
        // decodes straight to the target size instead of decoding 12 megapixels
        // and then throwing most of them away — meaningfully less peak memory,
        // which matters when a batch of 8 is prepared back to back.
        // `kCGImageSourceCreateThumbnailWithTransform` bakes in the EXIF
        // orientation, so the stripped output isn't sideways.
        guard let fullImage = downscaledImage(from: imageSource, maxDimension: fullMaxDimension) else {
            throw PrepareError.undecodable
        }
        guard let thumbImage = downscaledImage(from: imageSource, maxDimension: thumbMaxDimension) else {
            throw PrepareError.undecodable
        }

        guard
            let fullJPEG = jpegData(from: fullImage, quality: fullQuality),
            let thumbJPEG = jpegData(from: thumbImage, quality: thumbQuality)
        else {
            throw PrepareError.encodingFailed
        }

        return Prepared(
            fullJPEG: fullJPEG,
            thumbnailJPEG: thumbJPEG,
            width: fullImage.width,
            height: fullImage.height,
            capturedAt: metadata.capturedAt,
            latitude: metadata.latitude,
            longitude: metadata.longitude
        )
    }

    // MARK: - Metadata

    private struct Metadata {
        var capturedAt: Date?
        var latitude: Double?
        var longitude: Double?
    }

    private static func readMetadata(from source: CGImageSource) -> Metadata {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] else { return Metadata() }

        var result = Metadata()

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            // DateTimeOriginal is when the shutter fired. DateTimeDigitized can
            // differ (a scan, an import), so prefer the former and fall back.
            let raw = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
                ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String)
            result.capturedAt = raw.flatMap(parseEXIFDate)
        }

        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            // EXIF GPS stores magnitude and hemisphere separately — a photo taken
            // in NYC has latitude 40.7 with ref "N" and longitude 73.9 with ref
            // "W". Ignoring the ref puts every western-hemisphere photo in China.
            if let latitude = gps[kCGImagePropertyGPSLatitude] as? Double {
                let ref = gps[kCGImagePropertyGPSLatitudeRef] as? String
                result.latitude = (ref == "S") ? -latitude : latitude
            }
            if let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
                let ref = gps[kCGImagePropertyGPSLongitudeRef] as? String
                result.longitude = (ref == "W") ? -longitude : longitude
            }
        }

        return result
    }

    /// EXIF timestamps are `yyyy:MM:dd HH:mm:ss` — colons in the date, and no
    /// timezone. Interpreted in the device's current zone, which is the best
    /// available guess and matches what Photos shows.
    private static func parseEXIFDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: raw)
    }

    // MARK: - Resizing

    private static func downscaledImage(
        from source: CGImageSource,
        maxDimension: CGFloat
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Encode to JPEG carrying no metadata dictionaries at all.
    ///
    /// `CGImageDestination` writes only what it is given, and it is given nothing
    /// but the pixels — so the result has no EXIF, no GPS, no maker notes. This
    /// is the actual strip; it is a property of building the file from a bare
    /// `CGImage` rather than a separate scrubbing step that could be skipped.
    private static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Avatars

    /// Square-crop and downscale for the `avatars` bucket.
    ///
    /// Same treatment as visit photos: re-encoded from bare pixels, so an avatar
    /// can't carry the location of the user's home into a public bucket either.
    static func prepareAvatar(_ source: Data, maxDimension: CGFloat = 512) -> Data? {
        guard
            let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
            let full = downscaledImage(from: imageSource, maxDimension: maxDimension * 2)
        else { return nil }

        let side = min(full.width, full.height)
        let cropRect = CGRect(
            x: (full.width - side) / 2,
            y: (full.height - side) / 2,
            width: side,
            height: side
        )
        guard let cropped = full.cropping(to: cropRect) else { return nil }

        return jpegData(from: cropped, quality: 0.85)
    }
}
