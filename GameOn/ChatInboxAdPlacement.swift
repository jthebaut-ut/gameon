import Foundation

/// In-feed native ad slot for the Chat → Friends inbox list (not DM threads).
enum ChatInboxListItem: Identifiable {
    case conversation(ChatViewModel.FriendDisplay)
    case nativeAd

    var id: String {
        switch self {
        case .conversation(let friend):
            return "chat-conversation-\(friend.id.uuidString)"
        case .nativeAd:
            return "chat-inbox-native-ad"
        }
    }
}

enum ChatInboxAdPlacement {
    /// Dedicated AdMob in-flight slot id (separate from venue comment ad slots 0/1).
    static let nativeAdSlotIndex = 2

    /// 0-based insertion threshold: DEBUG shows after 2nd row for testing; RELEASE keeps production after 8th.
    static var adAfterConversationIndex: Int {
#if DEBUG
        1
#else
        7
#endif
    }

    /// Human-readable 1-based row position after which the ad is inserted.
    static var insertedAfterConversationPosition: Int {
        adAfterConversationIndex + 1
    }

    static var debugOverrideEnabled: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    static func listItems(for friends: [ChatViewModel.FriendDisplay]) -> [ChatInboxListItem] {
        guard friends.count > adAfterConversationIndex else {
            return friends.map { .conversation($0) }
        }

        var items: [ChatInboxListItem] = []
        items.reserveCapacity(friends.count + 1)

        for (index, friend) in friends.enumerated() {
            items.append(.conversation(friend))
            if index == adAfterConversationIndex {
                items.append(.nativeAd)
            }
        }
        return items
    }
}
