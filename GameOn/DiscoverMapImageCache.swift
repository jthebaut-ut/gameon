import SwiftUI
import UIKit

/// Diagnostics-only tracing for ``DiscoverMapImageCache`` lookups (does not alter cache behavior).
nonisolated enum ImageCacheDebug {
    private static let lock = NSLock()
    private static var memoryHits = 0
    private static var diskHits = 0
    private static var networkFetches = 0
    private static var inFlightJoins = 0
    private static var lookupCount = 0
    private static var networkFetchCountsByKey: [String: Int] = [:]

    private struct FirstNetworkFetchTrace {
        let rawURL: String
        let normalizedURL: String
        let startedAt: Date
        var completedAt: Date?
        var memoryStoreKey: String?
    }

    private static var firstNetworkFetchByCacheKey: [String: FirstNetworkFetchTrace] = [:]

    private static func threadLabel() -> String {
        if Thread.isMainThread {
            return "main"
        }
        return String(describing: Thread.current)
    }

    static func threadLabelForDiagnostics() -> String {
        threadLabel()
    }

    static func logImageInvocationStart(actorIdentity: ObjectIdentifier, invocationId: UInt64, cacheKey: String, rawURL: String) {
        print("[ImageCacheDebug] imageInvocationStart=true")
        print("[ImageCacheDebug] actorIdentity=\(actorIdentity)")
        print("[ImageCacheDebug] imageInvocationId=\(invocationId)")
        print("[ImageCacheDebug] cacheKey=\(cacheKey)")
        print("[ImageCacheDebug] rawURL=\(rawURL)")
        print("[ImageCacheDebug] invocationThread=\(threadLabel())")
    }

    static func logInFlightLookupConcurrency(
        actorIdentity: ObjectIdentifier,
        invocationId: UInt64,
        cacheKey: String,
        existingTaskFound: Bool,
        activeKeys: [String],
        lookupBeforeInsertRaceSuspected: Bool
    ) {
        print("[ImageCacheDebug] inflightLookupKey=\(cacheKey)")
        print("[ImageCacheDebug] inflightExistingTaskFound=\(existingTaskFound)")
        print("[ImageCacheDebug] inflightActiveKeys=\(activeKeys.joined(separator: ","))")
        print("[ImageCacheDebug] actorIdentity=\(actorIdentity)")
        print("[ImageCacheDebug] imageInvocationId=\(invocationId)")
        print("[ImageCacheDebug] inflightLookupThread=\(threadLabel())")
        print("[ImageCacheDebug] lookupBeforeInsertRaceSuspected=\(lookupBeforeInsertRaceSuspected)")
    }

    static func logInFlightInsertConcurrency(
        actorIdentity: ObjectIdentifier,
        invocationId: UInt64,
        cacheKey: String,
        activeKeys: [String],
        lookupThread: String,
        lookupInsertGapMs: Double
    ) {
        print("[ImageCacheDebug] inflightInsertKey=\(cacheKey)")
        print("[ImageCacheDebug] inflightActiveKeysAfterInsert=\(activeKeys.joined(separator: ","))")
        print("[ImageCacheDebug] actorIdentity=\(actorIdentity)")
        print("[ImageCacheDebug] imageInvocationId=\(invocationId)")
        print("[ImageCacheDebug] inflightInsertThread=\(threadLabel())")
        print("[ImageCacheDebug] inflightLookupThread=\(lookupThread)")
        print("[ImageCacheDebug] lookupInsertGapMs=\(String(format: "%.3f", lookupInsertGapMs))")
    }

    /// Global probe outside actor isolation to detect overlapping lookups before any insert.
    private enum InFlightRegistrationProbe {
        private static let lock = NSLock()
        private static var openLookupInvocationByCacheKey: [String: UInt64] = [:]
        private static var insertedCacheKeys: Set<String> = []

        static func registerLookup(cacheKey: String, invocationId: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let hadOpenLookup = openLookupInvocationByCacheKey[cacheKey] != nil
            let hadInsert = insertedCacheKeys.contains(cacheKey)
            openLookupInvocationByCacheKey[cacheKey] = invocationId
            return hadOpenLookup && !hadInsert
        }

        static func registerInsert(cacheKey: String, invocationId: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            insertedCacheKeys.insert(cacheKey)
            if openLookupInvocationByCacheKey[cacheKey] == invocationId {
                openLookupInvocationByCacheKey.removeValue(forKey: cacheKey)
            }
        }

        static func reset() {
            lock.lock()
            openLookupInvocationByCacheKey = [:]
            insertedCacheKeys = []
            lock.unlock()
        }
    }

    static func diagnosticIdentity(for url: URL, bucket: DiscoverMapImageCache.Bucket) -> (normalizedURL: String, cacheKey: String) {
        let normalizedURL = ImageDisplayURL.canonicalStorageURLString(url.absoluteString)
        let cacheKey = "\(bucket)|\(normalizedURL)"
        return (normalizedURL, cacheKey)
    }

    static func logLookup(
        bucket: DiscoverMapImageCache.Bucket,
        url: URL,
        memoryHit: Bool,
        diskHit: Bool,
        networkFetch: Bool,
        inFlightJoin: Bool,
        source: String = "DiscoverMapImageCache"
    ) {
        let identity = diagnosticIdentity(for: url, bucket: bucket)
        lock.lock()
        lookupCount += 1
        if memoryHit { memoryHits += 1 }
        if diskHit { diskHits += 1 }
        if networkFetch {
            networkFetches += 1
            let prior = networkFetchCountsByKey[identity.cacheKey, default: 0]
            networkFetchCountsByKey[identity.cacheKey] = prior + 1
        }
        let duplicateNetwork = networkFetch && networkFetchCountsByKey[identity.cacheKey, default: 0] > 1
        if inFlightJoin { inFlightJoins += 1 }
        lock.unlock()

        print("[ImageCacheDebug] memoryHit=\(memoryHit)")
        print("[ImageCacheDebug] diskHit=\(diskHit)")
        print("[ImageCacheDebug] networkFetch=\(networkFetch)")
        print("[ImageCacheDebug] inFlightJoin=\(inFlightJoin)")
        print("[ImageCacheDebug] bucket=\(bucket)")
        print("[ImageCacheDebug] normalizedURL=\(identity.normalizedURL)")
        print("[ImageCacheDebug] cacheKey=\(identity.cacheKey)")
        print("[ImageCacheDebug] source=\(source)")
        if duplicateNetwork {
            print("[ImageCacheDebug] duplicateNetworkFetch=true cacheKey=\(identity.cacheKey)")
        }
        if networkFetch, url.absoluteString != identity.normalizedURL {
            print("[ImageCacheDebug] versionedDisplayURL=true rawURL=\(url.absoluteString)")
        }
    }

    static func logInFlightJoin(
        bucket: DiscoverMapImageCache.Bucket,
        url: URL,
        source: String = "image"
    ) {
        let identity = diagnosticIdentity(for: url, bucket: bucket)
        lock.lock()
        lookupCount += 1
        inFlightJoins += 1
        lock.unlock()

        print("[ImageCacheDebug] memoryHit=false")
        print("[ImageCacheDebug] diskHit=false")
        print("[ImageCacheDebug] networkFetch=false")
        print("[ImageCacheDebug] inFlightJoin=true")
        print("[ImageCacheDebug] duplicateNetworkFetchPrevented=true")
        print("[ImageCacheDebug] bucket=\(bucket)")
        print("[ImageCacheDebug] normalizedURL=\(identity.normalizedURL)")
        print("[ImageCacheDebug] cacheKey=\(identity.cacheKey)")
        print("[ImageCacheDebug] source=\(source)")
    }

    static func logInFlightLookup(cacheKey: String, existingTaskFound: Bool, activeKeys: [String]) {
        print("[ImageCacheDebug] inflightLookupKey=\(cacheKey)")
        print("[ImageCacheDebug] inflightExistingTaskFound=\(existingTaskFound)")
        print("[ImageCacheDebug] inflightActiveKeys=\(activeKeys.joined(separator: ","))")
    }

    static func logInFlightInsert(cacheKey: String, activeKeys: [String]) {
        print("[ImageCacheDebug] inflightInsertKey=\(cacheKey)")
        print("[ImageCacheDebug] inflightActiveKeysAfterInsert=\(activeKeys.joined(separator: ","))")
    }

    static func logInFlightRemove(cacheKey: String, activeKeys: [String]) {
        print("[ImageCacheDebug] inflightRemoveKey=\(cacheKey)")
        print("[ImageCacheDebug] inflightActiveKeysAfterRemove=\(activeKeys.joined(separator: ","))")
    }

    static func registerInFlightLookupProbe(cacheKey: String, invocationId: UInt64) -> Bool {
        InFlightRegistrationProbe.registerLookup(cacheKey: cacheKey, invocationId: invocationId)
    }

    static func registerInFlightInsertProbe(cacheKey: String, invocationId: UInt64) {
        InFlightRegistrationProbe.registerInsert(cacheKey: cacheKey, invocationId: invocationId)
    }

    static func logURLSessionStart(cacheKey: String, url: URL) {
        print("[ImageCacheDebug] urlSessionStart=true")
        print("[ImageCacheDebug] cacheKey=\(cacheKey)")
        print("[ImageCacheDebug] rawURL=\(url.absoluteString)")
    }

    static func logNewNetworkFetchPath(
        cacheKey: String,
        inFlightActiveKeysBeforeInsert: [String],
        rawURL: String,
        normalizedURL: String,
        memoryLookupKey: String
    ) {
        print("[ImageCacheDebug] newNetworkFetchPath=true")
        print("[ImageCacheDebug] cacheKey=\(cacheKey)")
        print("[ImageCacheDebug] inflightActiveKeysBeforeInsert=\(inFlightActiveKeysBeforeInsert.joined(separator: ","))")
        print("[ImageCacheDebug] rawURL=\(rawURL)")
        print("[ImageCacheDebug] normalizedURL=\(normalizedURL)")
        print("[ImageCacheDebug] memoryLookupKey=\(memoryLookupKey)")
        recordDuplicateNetworkFetchIfNeeded(
            cacheKey: cacheKey,
            rawURL: rawURL,
            normalizedURL: normalizedURL,
            memoryLookupKey: memoryLookupKey
        )
    }

    static func recordNetworkFetchCompleted(cacheKey: String) {
        lock.lock()
        firstNetworkFetchByCacheKey[cacheKey]?.completedAt = Date()
        lock.unlock()
    }

    static func recordMemoryStore(cacheKey: String, memoryStoreKey: String) {
        lock.lock()
        firstNetworkFetchByCacheKey[cacheKey]?.memoryStoreKey = memoryStoreKey
        lock.unlock()
        print("[ImageCacheDebug] memoryStoreKey=\(memoryStoreKey)")
        print("[ImageCacheDebug] cacheKey=\(cacheKey)")
    }

    private static func recordDuplicateNetworkFetchIfNeeded(
        cacheKey: String,
        rawURL: String,
        normalizedURL: String,
        memoryLookupKey: String
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard let first = firstNetworkFetchByCacheKey[cacheKey] else {
            firstNetworkFetchByCacheKey[cacheKey] = FirstNetworkFetchTrace(
                rawURL: rawURL,
                normalizedURL: normalizedURL,
                startedAt: Date(),
                completedAt: nil,
                memoryStoreKey: nil
            )
            return
        }

        let secondStartedAt = Date()
        let firstCompletedBeforeSecond = first.completedAt.map { $0 <= secondStartedAt } ?? false
        let firstStillInFlight = first.completedAt == nil
        let versionTokenChanged = first.rawURL != rawURL && first.normalizedURL == normalizedURL

        print("[ImageCacheDebug] duplicateFetchInvestigation=true")
        print("[ImageCacheDebug] cacheKey=\(cacheKey)")
        print("[ImageCacheDebug] firstRawURL=\(first.rawURL)")
        print("[ImageCacheDebug] secondRawURL=\(rawURL)")
        print("[ImageCacheDebug] firstNormalizedURL=\(first.normalizedURL)")
        print("[ImageCacheDebug] secondNormalizedURL=\(normalizedURL)")
        print("[ImageCacheDebug] firstMemoryStoreKey=\(first.memoryStoreKey ?? "nil")")
        print("[ImageCacheDebug] secondMemoryLookupKey=\(memoryLookupKey)")
        print("[ImageCacheDebug] firstFetchCompletedBeforeSecondStarted=\(firstCompletedBeforeSecond)")
        print("[ImageCacheDebug] firstFetchStillInFlightAtSecondLookup=\(firstStillInFlight)")
        print("[ImageCacheDebug] versionTokenChanged=\(versionTokenChanged)")
    }

    static func logBypass(
        loader: String,
        url: URL?,
        bucket: DiscoverMapImageCache.Bucket = .venue,
        reason: String
    ) {
        guard let url else {
            print("[ImageCacheDebug] bypassLoader=\(loader) reason=\(reason) url=nil")
            return
        }
        let identity = diagnosticIdentity(for: url, bucket: bucket)
        print("[ImageCacheDebug] bypassLoader=\(loader)")
        print("[ImageCacheDebug] bypassReason=\(reason)")
        print("[ImageCacheDebug] bucket=\(bucket)")
        print("[ImageCacheDebug] normalizedURL=\(identity.normalizedURL)")
        print("[ImageCacheDebug] cacheKey=\(identity.cacheKey)")
        print("[ImageCacheDebug] memoryHit=false")
        print("[ImageCacheDebug] diskHit=false")
        print("[ImageCacheDebug] networkFetch=unknown")
    }

    static func printSessionSummary(reason: String) {
        lock.lock()
        let lookups = lookupCount
        let mem = memoryHits
        let disk = diskHits
        let net = networkFetches
        let joins = inFlightJoins
        let duplicates = networkFetchCountsByKey.values.reduce(0) { partial, count in
            partial + max(0, count - 1)
        }
        let duplicateKeys = networkFetchCountsByKey
            .filter { $0.value > 1 }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(8)
            .map { "\($0.key):\($0.value)" }
            .joined(separator: " | ")
        lock.unlock()

        let memoryRate = lookups > 0 ? Double(mem) / Double(lookups) : 0
        let diskRate = lookups > 0 ? Double(disk) / Double(lookups) : 0
        print("[ImageCacheDebug] sessionSummary reason=\(reason)")
        print("[ImageCacheDebug] lookupCount=\(lookups)")
        print("[ImageCacheDebug] memoryHitRate=\(String(format: "%.3f", memoryRate))")
        print("[ImageCacheDebug] diskHitRate=\(String(format: "%.3f", diskRate))")
        print("[ImageCacheDebug] memoryHits=\(mem)")
        print("[ImageCacheDebug] diskHits=\(disk)")
        print("[ImageCacheDebug] networkFetchCount=\(net)")
        print("[ImageCacheDebug] inFlightJoinCount=\(joins)")
        print("[ImageCacheDebug] duplicateNetworkFetchCount=\(duplicates)")
        if !duplicateKeys.isEmpty {
            print("[ImageCacheDebug] duplicateNetworkKeys=\(duplicateKeys)")
        }
        print("[ImageCacheDebug] diskLayerPresent=false")
    }

    static func resetSessionStats(reason: String = "reset") {
        lock.lock()
        memoryHits = 0
        diskHits = 0
        networkFetches = 0
        inFlightJoins = 0
        lookupCount = 0
        networkFetchCountsByKey = [:]
        firstNetworkFetchByCacheKey = [:]
        lock.unlock()
        print("[ImageCacheDebug] sessionReset reason=\(reason)")
    }
}

/// Small in-memory image cache for Discover map thumbnails and “going” avatars (reduces `AsyncImage` refetch/flicker).
actor DiscoverMapImageCache {
    nonisolated enum Bucket: Hashable {
        case venue
        case avatar
    }

    static let shared = DiscoverMapImageCache()

    private var storage: [Bucket: [URL: UIImage]] = [:]
    /// Coalesces concurrent downloads for the same normalized ``ImageCacheDebug`` cacheKey.
    private var inFlightByCacheKey: [String: Task<UIImage?, Never>] = [:]
    private var imageInvocationSequence: UInt64 = 0
    private var order: [Bucket: [URL]] = [:]
    private let maxEntriesByBucket: [Bucket: Int] = [
        .venue: 96,
        .avatar: 160
    ]

    func cachedImage(for url: URL, bucket: Bucket = .venue) -> UIImage? {
        if let hit = storage[bucket]?[url] ?? storage[.venue]?[url] {
            ImageCacheDebug.logLookup(
                bucket: bucket,
                url: url,
                memoryHit: true,
                diskHit: false,
                networkFetch: false,
                inFlightJoin: false,
                source: "cachedImage"
            )
            return hit
        }
        return nil
    }

    func image(for url: URL, bucket: Bucket = .venue) async -> UIImage? {
        imageInvocationSequence += 1
        let invocationId = imageInvocationSequence
        let actorIdentity = ObjectIdentifier(self)

        if let existing = cachedImage(for: url, bucket: bucket) {
            return existing
        }

        let identity = ImageCacheDebug.diagnosticIdentity(for: url, bucket: bucket)
        let cacheKey = identity.cacheKey
        let normalizedURL = identity.normalizedURL
        ImageCacheDebug.logImageInvocationStart(
            actorIdentity: actorIdentity,
            invocationId: invocationId,
            cacheKey: cacheKey,
            rawURL: url.absoluteString
        )

        let lookupStartedAt = CFAbsoluteTimeGetCurrent()
        let lookupThread = ImageCacheDebug.threadLabelForDiagnostics()
        let activeKeysBeforeLookup = Array(inFlightByCacheKey.keys)
        let existingTask = inFlightByCacheKey[cacheKey]
        let lookupBeforeInsertRaceSuspected = ImageCacheDebug.registerInFlightLookupProbe(
            cacheKey: cacheKey,
            invocationId: invocationId
        )
        ImageCacheDebug.logInFlightLookupConcurrency(
            actorIdentity: actorIdentity,
            invocationId: invocationId,
            cacheKey: cacheKey,
            existingTaskFound: existingTask != nil,
            activeKeys: activeKeysBeforeLookup,
            lookupBeforeInsertRaceSuspected: lookupBeforeInsertRaceSuspected
        )

        if let existingTask {
            ImageCacheDebug.logInFlightJoin(bucket: bucket, url: url, source: "image")
            return await existingTask.value
        }

        ImageCacheDebug.logNewNetworkFetchPath(
            cacheKey: cacheKey,
            inFlightActiveKeysBeforeInsert: activeKeysBeforeLookup,
            rawURL: url.absoluteString,
            normalizedURL: normalizedURL,
            memoryLookupKey: url.absoluteString
        )
        ImageCacheDebug.logLookup(
            bucket: bucket,
            url: url,
            memoryHit: false,
            diskHit: false,
            networkFetch: true,
            inFlightJoin: false,
            source: "image"
        )
        let fetchStartedAt = Date()

        inFlightByCacheKey[cacheKey] = Task<UIImage?, Never> { [cacheKey, url] in
            ImageCacheDebug.logURLSessionStart(cacheKey: cacheKey, url: url)
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                return await Task.detached(priority: .userInitiated) {
                    UIImage(data: data)
                }.value
            } catch {
                return nil
            }
        }
        ImageCacheDebug.registerInFlightInsertProbe(cacheKey: cacheKey, invocationId: invocationId)
        let lookupInsertGapMs = (CFAbsoluteTimeGetCurrent() - lookupStartedAt) * 1000
        ImageCacheDebug.logInFlightInsertConcurrency(
            actorIdentity: actorIdentity,
            invocationId: invocationId,
            cacheKey: cacheKey,
            activeKeys: Array(inFlightByCacheKey.keys),
            lookupThread: lookupThread,
            lookupInsertGapMs: lookupInsertGapMs
        )

        let task = inFlightByCacheKey[cacheKey]!
        let decoded = await task.value
        inFlightByCacheKey[cacheKey] = nil
        ImageCacheDebug.logInFlightRemove(
            cacheKey: cacheKey,
            activeKeys: Array(inFlightByCacheKey.keys)
        )

        let ms = Int(Date().timeIntervalSince(fetchStartedAt) * 1000)
        print("[ImageCacheDebug] networkFetchFinished=true ms=\(ms) cacheKey=\(cacheKey)")
        ImageCacheDebug.recordNetworkFetchCompleted(cacheKey: cacheKey)

        guard let ui = decoded else {
            print("[ImageCacheDebug] networkFetchFailed=true cacheKey=\(cacheKey)")
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
                let cacheKey = ImageCacheDebug.diagnosticIdentity(for: url, bucket: bucket).cacheKey
                inFlightByCacheKey[cacheKey]?.cancel()
                inFlightByCacheKey[cacheKey] = nil
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
        let cacheKey = ImageCacheDebug.diagnosticIdentity(for: url, bucket: bucket).cacheKey
        ImageCacheDebug.recordMemoryStore(cacheKey: cacheKey, memoryStoreKey: url.absoluteString)
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
