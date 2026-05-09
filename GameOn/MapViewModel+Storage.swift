import Foundation
import Supabase

// Supabase Storage public URL parsing and best-effort deletes when replacing avatars / venue photos.

extension MapViewModel {

    private static let storageDeletionBuckets: Set<String> = ["user-avatars", "venue-photos"]

    /// Extracts the object key after `/storage/v1/object/public/{bucket}/` for `remove` API calls.
    func storagePath(fromPublicURL publicURL: String, bucket: String) -> String? {
        let trimmed = publicURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let marker = "/storage/v1/object/public/\(bucket)/"
        guard let range = trimmed.range(of: marker) else { return nil }

        let path = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return path
    }

    /// Removes one object if the path is safe and the bucket is app-controlled. Failures are swallowed (best-effort).
    func deleteStorageObjectIfSafe(bucket: String, path: String) async {
        guard Self.storageDeletionBuckets.contains(bucket) else {
#if DEBUG
            print("STORAGE DELETE skipped: bucket not allowed:", bucket)
#endif
            return
        }

        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2048 else { return }
        guard !trimmed.contains(".."), !trimmed.hasPrefix("/") else {
#if DEBUG
            print("STORAGE DELETE skipped: unsafe path:", trimmed)
#endif
            return
        }

        do {
            try await supabase.storage
                .from(bucket)
                .remove(paths: [trimmed])
#if DEBUG
            print("STORAGE DELETE ok:", bucket, trimmed)
#endif
        } catch {
#if DEBUG
            print("STORAGE DELETE failed:", bucket, trimmed, error)
#endif
        }
    }

    /// After a successful upload, remove the prior object if it was in the same bucket, non-empty, and distinct from `newPublicURL`.
    func deleteReplacedStorageObjectIfNeeded(oldPublicURL: String?, newPublicURL: String, bucket: String) async {
        let old = oldPublicURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newTrim = newPublicURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty else { return }
        guard old != newTrim else { return }
        guard let path = storagePath(fromPublicURL: old, bucket: bucket) else { return }

        await deleteStorageObjectIfSafe(bucket: bucket, path: path)
    }

    /// Legacy helper — prefer ``deleteReplacedStorageObjectIfNeeded`` from upload paths with explicit “previous URL”.
    func deleteStorageFile(publicURL: String, bucketName: String) async {
        guard let path = storagePath(fromPublicURL: publicURL, bucket: bucketName) else { return }
        await deleteStorageObjectIfSafe(bucket: bucketName, path: path)
    }
}
