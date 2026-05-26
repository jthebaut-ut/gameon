import SwiftUI
import UIKit

/// Small in-memory image cache for Discover map thumbnails and “going” avatars (reduces `AsyncImage` refetch/flicker).
actor DiscoverMapImageCache {
    enum Bucket: Hashable {
        case venue
        case avatar
    }

    static let shared = DiscoverMapImageCache()

    private var storage: [Bucket: [URL: UIImage]] = [:]
    private var inFlight: [Bucket: [URL: Task<UIImage?, Never>]] = [:]
    private var order: [Bucket: [URL]] = [:]
    private let maxEntriesByBucket: [Bucket: Int] = [
        .venue: 96,
        .avatar: 160
    ]

    func cachedImage(for url: URL, bucket: Bucket = .venue) -> UIImage? {
        storage[bucket]?[url] ?? storage[.venue]?[url]
    }

    func image(for url: URL, bucket: Bucket = .venue) async -> UIImage? {
        if let existing = cachedImage(for: url, bucket: bucket) {
            #if DEBUG
            print("[ImageCacheDebug] cacheHit bucket=\(bucket) url=\(url.absoluteString)")
            #endif
            return existing
        }

        if let existingTask = inFlight[bucket]?[url] {
            #if DEBUG
            print("[ImageCacheDebug] inFlightJoin bucket=\(bucket) url=\(url.absoluteString)")
            #endif
            return await existingTask.value
        }

        #if DEBUG
        print("[ImageCacheDebug] fetchStart bucket=\(bucket) url=\(url.absoluteString)")
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

        inFlight[bucket, default: [:]][url] = task
        let decoded = await task.value
        inFlight[bucket]?[url] = nil

        #if DEBUG
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[ImageCacheDebug] fetchFinished bucket=\(bucket) url=\(url.absoluteString) ms=\(ms)")
        #endif

        guard let ui = decoded else {
            return nil
        }
        storeDecoded(ui, for: url, bucket: bucket)
        return ui
    }

    func prefetch(urls: [URL], bucket: Bucket = .venue) async {
        for url in urls.prefix(8) {
            _ = await image(for: url, bucket: bucket)
        }
    }

    func invalidate(urls: [URL]) {
        for url in urls {
            for bucket in maxEntriesByBucket.keys {
                storage[bucket]?[url] = nil
                inFlight[bucket]?[url]?.cancel()
                inFlight[bucket]?[url] = nil
            }
        }
        let removed = Set(urls)
        for bucket in maxEntriesByBucket.keys {
            order[bucket]?.removeAll { removed.contains($0) }
        }
    }

    func store(_ image: UIImage, for urls: [URL], bucket: Bucket = .venue) {
        for url in urls {
            storeDecoded(image, for: url, bucket: bucket)
        }
    }

    private func storeDecoded(_ image: UIImage, for url: URL, bucket: Bucket) {
        var bucketStorage = storage[bucket] ?? [:]
        var bucketOrder = order[bucket] ?? []
        if bucketStorage[url] == nil {
            let maxEntries = maxEntriesByBucket[bucket] ?? 96
            if bucketStorage.count >= maxEntries, let old = bucketOrder.first {
                bucketStorage.removeValue(forKey: old)
                bucketOrder.removeFirst()
            }
            bucketOrder.append(url)
        }
        bucketStorage[url] = image
        storage[bucket] = bucketStorage
        order[bucket] = bucketOrder
    }
}

/// Loads a remote image with RAM cache; keeps layout stable with an intentional placeholder (non-blocking).
struct VenuePhotoDebugContext {
    let venueId: UUID
    let venueName: String
    let selectedMainPhotoURL: String?
    let selectedSecondaryPhotoURL: String?
}

struct DiscoverCachedRemoteImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var venuePhotoDebugContext: VenuePhotoDebugContext? = nil
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
            uiImage = nil
            guard let url else {
                return
            }
            if let cached = await DiscoverMapImageCache.shared.cachedImage(for: url) {
                guard !Task.isCancelled else { return }
                uiImage = cached
                loadedImageVisible = true
                return
            }
            if let loaded = await DiscoverMapImageCache.shared.image(for: url) {
                guard !Task.isCancelled else { return }
                uiImage = loaded
                await Task.yield()
                guard !Task.isCancelled else { return }
                loadedImageVisible = true
            } else {
                guard !Task.isCancelled else { return }
                uiImage = nil
#if DEBUG
                if let context = venuePhotoDebugContext {
                    print("[VenuePhotoDebug] venueId=\(context.venueId.uuidString.lowercased())")
                    print("[VenuePhotoDebug] venueName=\(context.venueName)")
                    print("[VenuePhotoDebug] selectedMainPhotoURL=\(context.selectedMainPhotoURL ?? "")")
                    print("[VenuePhotoDebug] selectedSecondaryPhotoURL=\(context.selectedSecondaryPhotoURL ?? "")")
                    print("[VenuePhotoDebug] imageLoadFailed=\(url.absoluteString)")
                }
#endif
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
