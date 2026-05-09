import Foundation
import UIKit

/// JPEG resize/re-encode for Supabase image uploads. Call sites fall back to original `Data` on failure.
enum ImageCompression {

    enum UploadPreset {
        case avatar
        case venuePhoto

        fileprivate var maxLongEdge: CGFloat {
            switch self {
            case .avatar: return 512
            case .venuePhoto: return 1500
            }
        }

        fileprivate var jpegQuality: CGFloat {
            switch self {
            case .avatar: return 0.78
            case .venuePhoto: return 0.72
            }
        }

        fileprivate var debugLabel: String {
            switch self {
            case .avatar: return "avatar"
            case .venuePhoto: return "venue"
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

    /// Optional smaller JPEG for preview/future use (not currently uploaded).
    static func jpegThumbnailData(from imageData: Data, maxLongEdge: CGFloat = 360, jpegQuality: CGFloat = 0.70) -> Data? {
        guard let image = UIImage(data: imageData) else { return nil }
        let pixel = pixelSize(for: image)
        let longEdge = max(pixel.width, pixel.height)
        let downscale = longEdge > maxLongEdge ? maxLongEdge / longEdge : 1
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
        return imageToEncode.jpegData(compressionQuality: jpegQuality)
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
