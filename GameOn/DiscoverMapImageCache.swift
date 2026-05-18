import SwiftUI
import UIKit

/// Small in-memory image cache for Discover map thumbnails and “going” avatars (reduces `AsyncImage` refetch/flicker).
actor DiscoverMapImageCache {
    static let shared = DiscoverMapImageCache()

    private var storage: [URL: UIImage] = [:]
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private var order: [URL] = []
    private let maxEntries = 72

    func cachedImage(for url: URL) -> UIImage? {
        storage[url]
    }

    func image(for url: URL) async -> UIImage? {
        if let existing = storage[url] {
            #if DEBUG
            print("[ImageCacheDebug] cacheHit url=\(url.absoluteString)")
            #endif
            return existing
        }

        if let existingTask = inFlight[url] {
            #if DEBUG
            print("[ImageCacheDebug] inFlightJoin url=\(url.absoluteString)")
            #endif
            return await existingTask.value
        }

        #if DEBUG
        print("[ImageCacheDebug] fetchStart url=\(url.absoluteString)")
        let t0 = Date()
        #endif

        let task = Task<UIImage?, Never> {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                return await Task.detached(priority: .userInitiated) {
                    UIImage(data: data)
                }.value
            } catch {
                return nil
            }
        }

        inFlight[url] = task
        let decoded = await task.value
        inFlight.removeValue(forKey: url)

        #if DEBUG
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[ImageCacheDebug] fetchFinished url=\(url.absoluteString) ms=\(ms)")
        #endif

        guard let ui = decoded else {
            return nil
        }
        if storage.count >= maxEntries, let old = order.first {
            storage.removeValue(forKey: old)
            order.removeFirst()
        }
        storage[url] = ui
        order.append(url)
        return ui
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
    @State private var loadedImageVisible = false

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .opacity(loadedImageVisible ? 1 : 0)
            } else {
                placeholder()
            }
        }
        .animation(.easeOut(duration: 0.22), value: loadedImageVisible)
        .task(id: url?.absoluteString) {
            loadedImageVisible = false
            guard let url else {
                uiImage = nil
                return
            }
            if let cached = await DiscoverMapImageCache.shared.cachedImage(for: url) {
                uiImage = cached
                loadedImageVisible = true
                return
            }
            if let loaded = await DiscoverMapImageCache.shared.image(for: url) {
                uiImage = loaded
                await Task.yield()
                loadedImageVisible = true
            } else {
                uiImage = nil
            }
        }
    }
}

extension MapViewModel {
    /// Warms the Discover image cache for thumbnails. Menu URLs are optional (heavier / rarely shown on the map card).
    func prefetchDiscoverVenueImages(for bar: BarVenue, includeMenu: Bool = false) async {
        var urls: [URL] = []
        if let s = ImageDisplayURL.forList(thumbnail: bar.coverPhotoThumbnailURL, full: bar.coverPhotoURL),
           let u = URL(string: s) {
            urls.append(u)
        }
        if includeMenu,
           let s = ImageDisplayURL.forList(thumbnail: bar.menuPhotoThumbnailURL, full: bar.menuPhotoURL),
           let u = URL(string: s) {
            urls.append(u)
        }
        await DiscoverMapImageCache.shared.prefetch(urls: urls)
    }
}
