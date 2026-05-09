import Foundation
import UIKit

/// JPEG resize/re-encode for Supabase image uploads. Call sites fall back to original `Data` on failure.
enum ImageCompression {

    enum UploadPreset {
        /// Full-size user avatar stored at `avatar.jpg` (list/detail fallback).
        case avatar
        /// Companion `avatar_thumb.jpg` (~224px) for lists and small circles.
        case avatarThumbnail
        /// Venue / menu full image (max long edge 1500).
        case venuePhoto
        /// Venue / menu list preview (~520px long edge).
        case venuePhotoThumbnail

        fileprivate var maxLongEdge: CGFloat {
            switch self {
            case .avatar: return 768
            case .avatarThumbnail: return 224
            case .venuePhoto: return 1500
            case .venuePhotoThumbnail: return 520
            }
        }

        fileprivate var jpegQuality: CGFloat {
            switch self {
            case .avatar: return 0.85
            case .avatarThumbnail: return 0.82
            case .venuePhoto: return 0.82
            case .venuePhotoThumbnail: return 0.78
            }
        }

        fileprivate var debugLabel: String {
            switch self {
            case .avatar: return "avatar"
            case .avatarThumbnail: return "avatar_thumb"
            case .venuePhoto: return "venue"
            case .venuePhotoThumbnail: return "venue_thumb"
            }
        }
    }

    /// Returns JPEG `Data` scaled to `preset` limits when possible; on decode/encode failure returns `imageData` unchanged.
    static func jpegDataForUpload(from imageData: Data, preset: UploadPreset) -> Data {
        let originalCount = imageData.count

        guard let image = UIImage(data: imageData) else {
#if DEBUG
            print("[ImageUpload] \(preset.debugLabel) decode failed; using original \(originalCount) bytes")
#endif
            return imageData
        }

        let pixel = pixelSize(for: image)
        let longEdge = max(pixel.width, pixel.height)
        let maxEdge = preset.maxLongEdge
        let downscale = longEdge > maxEdge ? maxEdge / longEdge : 1

        let targetWidth = max(1, round(pixel.width * downscale))
        let targetHeight = max(1, round(pixel.height * downscale))

        let imageToEncode: UIImage
        if downscale < 1 {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = true
            let size = CGSize(width: targetWidth, height: targetHeight)
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            imageToEncode = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        } else {
            imageToEncode = image
        }

        guard let jpeg = imageToEncode.jpegData(compressionQuality: preset.jpegQuality), !jpeg.isEmpty else {
#if DEBUG
            print("[ImageUpload] \(preset.debugLabel) JPEG encode failed; using original \(originalCount) bytes")
#endif
            return imageData
        }

#if DEBUG
        print("[ImageUpload] \(preset.debugLabel) original: \(originalCount) bytes, compressed: \(jpeg.count) bytes")
#endif
        return jpeg
    }

    private static func pixelSize(for image: UIImage) -> CGSize {
        if let cg = image.cgImage {
            return CGSize(width: cg.width, height: cg.height)
        }
        return CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
    }
}
