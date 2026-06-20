import Foundation

/// In-feed native ad slot for the Chat → Chats inbox list (not DM threads).
enum ChatInboxListItem: Identifiable {
    case conversation(ChatViewModel.FriendDisplay)
    case nativeAd(ChatInboxNativeAdSlot)

    var id: String {
        switch self {
        case .conversation(let friend):
            return "chat-conversation-\(friend.id.uuidString)"
        case .nativeAd(let slot):
            return slot.id
        }
    }
}

struct ChatInboxNativeAdSlot: Hashable {
    let ordinal: Int
    let insertedAfterConversationPosition: Int

    var id: String {
        "chat-inbox-native-ad-\(insertedAfterConversationPosition)"
    }

    var slotIndex: Int {
        ChatInboxAdPlacement.nativeAdSlotIndex + ordinal
    }
}

enum ChatInboxAdPlacement {
    /// Dedicated AdMob in-flight slot id (separate from venue comment ad slots 0/1).
    static let nativeAdSlotIndex = 2

    static var debugOverrideEnabled: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    static func shouldInsertNativeAd(conversationCount: Int) -> Bool {
        !insertionPositions(for: conversationCount).isEmpty
    }

    static func skippedReason(conversationCount: Int) -> String? {
        shouldInsertNativeAd(conversationCount: conversationCount) ? nil : "noConversations"
    }

    static func insertionPositions(for conversationCount: Int) -> [Int] {
        guard conversationCount > 0 else { return [] }
        return [conversationCount]
    }

    static func nativeAdSlots(for conversationCount: Int) -> [ChatInboxNativeAdSlot] {
        insertionPositions(for: conversationCount).enumerated().map { index, position in
            ChatInboxNativeAdSlot(ordinal: index, insertedAfterConversationPosition: position)
        }
    }

    static func listItems(for friends: [ChatViewModel.FriendDisplay]) -> [ChatInboxListItem] {
        guard FanGeoAdPolicy.shouldInsertAdsInFeeds() else {
            return friends.map { .conversation($0) }
        }
        let slots = nativeAdSlots(for: friends.count)
        guard !slots.isEmpty else {
            return friends.map { .conversation($0) }
        }
        let slotsByPosition = Dictionary(uniqueKeysWithValues: slots.map {
            ($0.insertedAfterConversationPosition, $0)
        })

        var items: [ChatInboxListItem] = []
        items.reserveCapacity(friends.count + slots.count)

        for (index, friend) in friends.enumerated() {
            items.append(.conversation(friend))
            if let slot = slotsByPosition[index + 1] {
                items.append(.nativeAd(slot))
            }
        }
        return items
    }
}
