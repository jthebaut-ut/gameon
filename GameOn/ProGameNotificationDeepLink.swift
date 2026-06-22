import Foundation
import UserNotifications

/// Payload keys for local pro game reminder notification deep links.
enum ProGameNotificationDeepLinkPayload {
    static let matchIDKey = "match_id"
    static let sourceKey = "source"
    static let sourceValue = "pro_game_notification"

    static func userInfo(matchID: String) -> [String: String] {
        [
            matchIDKey: matchID,
            sourceKey: sourceValue
        ]
    }

    static func isProGameNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo[sourceKey] as? String) == sourceValue
    }

    static func matchID(from userInfo: [AnyHashable: Any]) -> String? {
        guard isProGameNotification(userInfo) else { return nil }
        let raw = (userInfo[matchIDKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    static func apply(to content: UNMutableNotificationContent, matchID: String) {
        var merged = content.userInfo
        for (key, value) in userInfo(matchID: matchID) {
            merged[key] = value
        }
        content.userInfo = merged
    }
}

/// Delivers pro game notification taps to ``MapViewModel`` once the root view model is bound.
@MainActor
final class ProGameNotificationDeepLinkBridge {
    static let shared = ProGameNotificationDeepLinkBridge()

    private weak var viewModel: MapViewModel?
    private var pendingUserInfo: [AnyHashable: Any]?

    private init() {}

    func bind(viewModel: MapViewModel) {
        self.viewModel = viewModel
        if let pendingUserInfo {
            self.pendingUserInfo = nil
            deliver(userInfo: pendingUserInfo)
        }
    }

    func handleNotificationResponse(_ response: UNNotificationResponse) {
        deliver(userInfo: response.notification.request.content.userInfo)
    }

    func deliver(userInfo: [AnyHashable: Any]) {
        guard let matchID = ProGameNotificationDeepLinkPayload.matchID(from: userInfo) else { return }
        if let viewModel {
            viewModel.enqueueProGameNotificationDeepLink(matchID: matchID)
        } else {
            pendingUserInfo = userInfo
        }
#if DEBUG
        print("[ProGameNotificationDeepLink] matchID=\(matchID) delivered=\(viewModel != nil)")
#endif
    }
}

struct ProGameNotificationDeepLinkRequest: Equatable {
    let id: UUID
    let matchID: String
}
