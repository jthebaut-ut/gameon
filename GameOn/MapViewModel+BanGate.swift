import Foundation
import Supabase

struct FanGeoAccountBan: Equatable {
    let id: UUID?
    let reason: String
    let bannedUntil: Date?
    let bannedUntilRaw: String?
    let serverNow: Date?
    let serverNowRaw: String?
    let isPermanentFromServer: Bool?

    var isPermanent: Bool {
        isPermanentFromServer ?? (bannedUntil == nil)
    }

    var remainingSeconds: Int? {
        guard let bannedUntil, let serverNow else { return nil }
        return max(0, Int(bannedUntil.timeIntervalSince(serverNow).rounded(.up)))
    }
}

extension MapViewModel {
    @discardableResult
    func refreshActiveBanGate(reason: String) async -> Bool {
#if DEBUG
        print("[BanGateDebug] checkingActiveBan=true")
#endif
        await MainActor.run {
            isCheckingActiveBan = true
        }
        defer {
            Task { @MainActor [weak self] in
                self?.isCheckingActiveBan = false
            }
        }

        switch await supabaseResolvedAuthSessionResult() {
        case .active(let session):
            await MainActor.run {
                currentUserAuthId = session.user.id
            }
        case .missingSession:
            await clearBanGateIfNeeded(logLifted: false)
            logBanGateResult(nil)
            return false
        case .refreshFailed(let error):
#if DEBUG
            print("[BanGateDebug] checkFailed=\(error.localizedDescription)")
#endif
            return await MainActor.run { activeAccountBan != nil }
        }

        do {
            let response = try await supabase
                .rpc("get_my_active_ban")
                .execute()
            let ban = try Self.decodeActiveBan(from: response.data)
            logBanGateResult(ban)

            if let ban {
                await MainActor.run {
                    activeAccountBan = ban
                }
#if DEBUG
                print("[BanGateDebug] banGatePresented=true")
#endif
                return true
            }

            await clearBanGateIfNeeded(logLifted: true)
            return false
        } catch {
#if DEBUG
            print("[BanGateDebug] checkFailed=\(error.localizedDescription)")
#endif
            return await MainActor.run { activeAccountBan != nil }
        }
    }

    @discardableResult
    func refreshActiveBanGateAndRestoreSessionIfAllowed(reason: String) async -> Bool {
        let isBanned = await refreshActiveBanGate(reason: reason)
        guard !isBanned else { return true }
        await bootstrapAuthSessionOnly()
        await refreshUserPersonalizationInBackground()
        return false
    }

    private func clearBanGateIfNeeded(logLifted: Bool) async {
        let hadBan = await MainActor.run { activeAccountBan != nil }
        await MainActor.run {
            activeAccountBan = nil
        }
        if hadBan && logLifted {
#if DEBUG
            print("[BanGateDebug] banLiftedOrExpired=true")
#endif
        }
    }

    private func logBanGateResult(_ ban: FanGeoAccountBan?) {
#if DEBUG
        print("[BanGateDebug] isBanned=\(ban != nil)")
        print("[BanGateDebug] isPermanent=\(ban?.isPermanent.description ?? "nil")")
        print("[BanGateDebug] bannedUntil=\(ban?.bannedUntilRaw ?? "nil")")
        print("[BanGateDebug] serverNow=\(ban?.serverNowRaw ?? "nil")")
        print("[BanGateDebug] remainingSeconds=\(ban?.remainingSeconds.map(String.init) ?? "nil")")
#endif
    }

    private static func decodeActiveBan(from data: Data) throws -> FanGeoAccountBan? {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        let payload: [String: Any]

        if let array = object as? [[String: Any]] {
            guard let first = array.first else { return nil }
            payload = first
        } else if let dict = object as? [String: Any] {
            payload = dict
        } else {
            return nil
        }

        if boolValue(payload, keys: ["is_banned", "isBanned", "banned"]) == false {
            return nil
        }

        let idRaw = stringValue(payload, keys: ["id", "ban_id", "banId"])
        let reason = stringValue(payload, keys: ["reason", "ban_reason", "banReason"]) ?? ""
        let bannedUntilRaw = stringValue(payload, keys: ["expires_at", "banned_until", "bannedUntil", "until"])
        let serverNowRaw = stringValue(payload, keys: ["server_now", "serverNow"])
        let startsAtRaw = stringValue(payload, keys: ["starts_at", "startsAt"])
        let createdAtRaw = stringValue(payload, keys: ["created_at", "createdAt"])
        let isPermanent = boolValue(payload, keys: ["is_permanent", "isPermanent", "permanent"])

        let hasBanIdentity = idRaw != nil
            || bannedUntilRaw != nil
            || !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || startsAtRaw != nil
            || createdAtRaw != nil
            || boolValue(payload, keys: ["is_banned", "isBanned", "banned"]) == true

        guard hasBanIdentity else { return nil }

        return FanGeoAccountBan(
            id: idRaw.flatMap(UUID.init(uuidString:)),
            reason: reason,
            bannedUntil: bannedUntilRaw.flatMap(SupabaseTimestampParsing.parseTimestamptz),
            bannedUntilRaw: bannedUntilRaw,
            serverNow: serverNowRaw.flatMap(SupabaseTimestampParsing.parseTimestamptz),
            serverNowRaw: serverNowRaw,
            isPermanentFromServer: isPermanent
        )
    }

    private static func stringValue(_ payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let value = payload[key] {
                let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, text.lowercased() != "<null>" {
                    return text
                }
            }
        }
        return nil
    }

    private static func boolValue(_ payload: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = payload[key] as? Bool { return value }
            if let number = payload[key] as? NSNumber { return number.boolValue }
            if let text = payload[key] as? String {
                switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "t", "1", "yes":
                    return true
                case "false", "f", "0", "no":
                    return false
                default:
                    break
                }
            }
        }
        return nil
    }
}
