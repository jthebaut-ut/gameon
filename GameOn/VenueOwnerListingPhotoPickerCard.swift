import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Footer under venue photo pickers (Manage listing, business signup, Add location).
enum VenueOwnerPhotoPickerCopy {
    static let libraryAccessFooter =
        "Photos are chosen only when you tap here. If the picker is empty, check Photo Library access for GameON in Settings."

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
            return "Photo access is off for GameOn. Turn it on in Settings ▸ Privacy & Security ▸ Photos to choose venue images."
        case .limited:
            return "Couldn’t use that photo. Pick another image, or adjust Selected Photos for GameOn in Settings."
        default:
            return "Couldn’t read that photo. Try another image, or check photo access for GameOn in Settings."
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
                    .font(.headline)
                    .fontWeight(.bold)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PhotosPicker(selection: $pickerSelection, matching: .images) {
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.gray.opacity(0.10))
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
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18))

                    Text(buttonTitle)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.black)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            .buttonStyle(.plain)

            Text(VenueOwnerPhotoPickerCopy.libraryAccessFooter)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
