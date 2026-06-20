import Foundation

/// In-feed native ad slots for venue event comment threads (does not affect comment data).
enum VenueCommentsListItem: Identifiable {
    case comment(VenueEventCommentRow)
    case nativeAd(slotIndex: Int)

    var id: String {
        switch self {
        case .comment(let row):
            if let uuid = row.id {
                return "comment-\(uuid.uuidString)"
            }
            let stamp = row.created_at ?? ""
            let author = row.user_email ?? ""
            let body = row.comment ?? ""
            return "comment-pending-\(stamp)-\(author)-\(body.hashValue)"
        case .nativeAd(let slotIndex):
            return "venue-native-ad-\(slotIndex)"
        }
    }
}

enum VenueCommentsAdPlacement {
    /// 0-based index of the 8th comment — ad is inserted immediately after it.
    static let firstAdAfterCommentIndex = 7
    /// 0-based index of the 20th comment — optional second ad.
    static let secondAdAfterCommentIndex = 19

    static func listItems(for comments: [VenueEventCommentRow]) -> [VenueCommentsListItem] {
        guard FanGeoAdPolicy.shouldInsertAdsInFeeds() else {
            return comments.map { .comment($0) }
        }
        guard comments.count >= 8 else {
            return comments.map { .comment($0) }
        }

        var items: [VenueCommentsListItem] = []
        items.reserveCapacity(comments.count + (comments.count >= 20 ? 2 : 1))

        for (index, comment) in comments.enumerated() {
            items.append(.comment(comment))
            if index == firstAdAfterCommentIndex {
                items.append(.nativeAd(slotIndex: 0))
            }
            if comments.count >= 20, index == secondAdAfterCommentIndex {
                items.append(.nativeAd(slotIndex: 1))
            }
        }
        return items
    }

    /// 1-based comment positions after which an ad is shown (for debug).
    static func insertedAfterCommentPositions(commentCount: Int) -> [Int] {
        guard commentCount >= 8 else { return [] }
        var positions = [8]
        if commentCount >= 20 {
            positions.append(20)
        }
        return positions
    }
}
