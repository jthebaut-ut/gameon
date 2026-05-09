import SwiftUI
import UIKit

/// Small in-memory image cache for Discover map thumbnails and “going” avatars (reduces `AsyncImage` refetch/flicker).
actor DiscoverMapImageCache {
    static let shared = DiscoverMapImageCache()

    private var storage: [URL: UIImage] = [:]
    private var order: [URL] = []
    private let maxEntries = 72

    func cachedImage(for url: URL) -> UIImage? {
        storage[url]
    }

    func image(for url: URL) async -> UIImage? {
        if let existing = storage[url] {
            return existing
        }
        #if DEBUG
        print("[DiscoverPerf] image cache MISS fetch \(url.lastPathComponent)")
        let t0 = Date()
        #endif
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
                UIImage(data: data)
            }.value
            guard let ui = decoded else { return nil }
            if storage.count >= maxEntries, let old = order.first {
                storage.removeValue(forKey: old)
                order.removeFirst()
            }
            storage[url] = ui
            order.append(url)
            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[DiscoverPerf] image decode+store ms=\(ms) \(url.lastPathComponent)")
            #endif
            return ui
        } catch {
            return nil
        }
    }

    func prefetch(urls: [URL]) async {
        for url in urls.prefix(8) {
            _ = await image(for: url)
        }
    }
}

/// Loads a remote image with RAM cache; keeps layout stable with an intentional placeholder (non-blocking).
struct DiscoverCachedRemoteImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var uiImage: UIImage?

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url?.absoluteString) {
            guard let url else {
                uiImage = nil
                return
            }
            if let cached = await DiscoverMapImageCache.shared.cachedImage(for: url) {
                uiImage = cached
                return
            }
            uiImage = await DiscoverMapImageCache.shared.image(for: url)
        }
    }
}

extension MapViewModel {
    /// Warms the Discover image cache for thumbnails. Menu URLs are optional (heavier / rarely shown on the map card).
    func prefetchDiscoverVenueImages(for bar: BarVenue, includeMenu: Bool = false) async {
        var urls: [URL] = []
        if let s = bar.coverPhotoURL?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
           let u = URL(string: s) {
            urls.append(u)
        }
        if includeMenu,
           let s = bar.menuPhotoURL?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
           let u = URL(string: s) {
            urls.append(u)
        }
        await DiscoverMapImageCache.shared.prefetch(urls: urls)
    }
}
