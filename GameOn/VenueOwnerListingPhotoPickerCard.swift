import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Footer under venue photo pickers (Manage listing, business signup, Add location).
enum VenueOwnerPhotoPickerCopy {
    static let libraryAccessFooter =
        "Photos are chosen only when you tap here. If the picker is empty, check Photo Library access for FanGeo in Settings."

    static func urlWithCacheBust(_ cleanBase: String) -> String {
        let t = String(Date().timeIntervalSince1970)
        let trimmed = cleanBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let sep = trimmed.contains("?") ? "&" : "?"
        return "\(trimmed)\(sep)v=\(t)"
    }

    /// Uses the same `v` query as the full-size preview URL so thumbnail previews refresh together.
    static func thumbnailURLAlignedWithDisplay(storageURL: String, displayTemplateURL: String) -> String {
        let storage = storageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !storage.isEmpty else { return "" }
        let template = displayTemplateURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let templateComponents = URLComponents(string: template),
              let templateItems = templateComponents.queryItems,
              let vValue = templateItems.first(where: { $0.name == "v" })?.value,
              !vValue.isEmpty
        else {
            return storage
        }
        guard var storageComponents = URLComponents(string: storage) else {
            let sep = storage.contains("?") ? "&" : "?"
            return "\(storage)\(sep)v=\(vValue)"
        }
        var q = storageComponents.queryItems ?? []
        q.removeAll { $0.name == "v" }
        q.append(URLQueryItem(name: "v", value: vValue))
        storageComponents.queryItems = q
        return storageComponents.string ?? storage
    }

    static func pickFailureUserHint() -> String {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .denied, .restricted:
            return "Photo access is off for FanGeo. Turn it on in Settings ▸ Privacy & Security ▸ Photos to choose venue images."
        case .limited:
            return "Couldn’t use that photo. Pick another image, or adjust Selected Photos for FanGeo in Settings."
        default:
            return "Couldn’t read that photo. Try another image, or check photo access for FanGeo in Settings."
        }
    }
}

/// Bar / menu photo picker matching Manage listing: preview card, black CTA, PhotosPicker, helper footer.
struct VenueOwnerListingPhotoPickerCard: View {
    let title: String
    let subtitle: String
    @Binding var pickerSelection: PhotosPickerItem?
    /// After upload to `venue-photos`, includes optional cache-bust query for `AsyncImage`.
    var remotePreviewURL: String
    /// Local JPEG/PNG bytes before upload (business signup while still logged out).
    var localPreviewData: Data?
    var emptySelectionButtonTitle: String = "Tap to add photo"
    var replaceSelectionButtonTitle: String = "Tap to replace photo"
    var usesFanGeoSheetChrome: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    private var trimmedRemote: String {
        remotePreviewURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasPreview: Bool {
        if let d = localPreviewData, !d.isEmpty, UIImage(data: d) != nil { return true }
        return !trimmedRemote.isEmpty
    }

    private var buttonTitle: String {
        hasPreview ? replaceSelectionButtonTitle : emptySelectionButtonTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                Text(subtitle)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }

            PhotosPicker(selection: $pickerSelection, matching: .images) {
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(
                            usesFanGeoSheetChrome
                                ? FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.76 : 0.97)
                                : Color.gray.opacity(0.10)
                        )
                        .frame(height: 140)
                        .overlay {
                            Group {
                                if let d = localPreviewData, !d.isEmpty, let ui = UIImage(data: d) {
                                    Image(uiImage: ui)
                                        .resizable()
                                        .scaledToFill()
                                } else if let url = URL(string: trimmedRemote), !trimmedRemote.isEmpty {
                                    AsyncImage(url: url) { image in
                                        image
                                            .resizable()
                                            .scaledToFill()
                                    } placeholder: {
                                        ProgressView()
                                    }
                                    .id(trimmedRemote)
                                } else {
                                    Image(systemName: "photo")
                                        .font(.largeTitle)
                                        .foregroundStyle(
                                            usesFanGeoSheetChrome
                                                ? FGColor.mutedText(colorScheme)
                                                : Color.secondary
                                        )
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay {
                            if usesFanGeoSheetChrome {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                            }
                        }

                    HStack(spacing: FGSpacing.sm) {
                        Image(systemName: hasPreview ? "arrow.triangle.2.circlepath" : "plus")
                            .font(.system(size: 14, weight: .bold))
                        Text(buttonTitle)
                            .font(FGTypography.cardTitle)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FGSpacing.md)
                    .background(
                        usesFanGeoSheetChrome
                            ? AnyShapeStyle(FGColor.brandGradient)
                            : AnyShapeStyle(Color.black)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                }
            }
            .buttonStyle(.plain)

            Text(VenueOwnerPhotoPickerCopy.libraryAccessFooter)
                .font(FGTypography.metadata)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(usesFanGeoSheetChrome ? FGSpacing.md : 0)
        .background(
            usesFanGeoSheetChrome
                ? AnyShapeStyle(FGColor.cardBackground(colorScheme))
                : AnyShapeStyle(Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous))
        .overlay {
            if usesFanGeoSheetChrome {
                RoundedRectangle(cornerRadius: FGRadius.card, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
        }
    }
}
