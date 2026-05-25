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
    func businessBanGuardBlocks(
        path: String,
        action: String,
        businessId: UUID? = nil,
        ownerEmail: String? = nil,
        ownerUserId: UUID? = nil
    ) async -> Bool {
        let userBanBlocked = await refreshActiveBanGate(reason: "business:\(path):\(action)")
        let userBan = await MainActor.run { activeAccountBan }
        logBusinessBanGuard(path: path, action: action, ban: userBan, blocked: userBanBlocked)
        guard !userBanBlocked else { return true }

        return await refreshActiveBusinessBanGate(
            checkPath: "\(path):\(action)",
            businessId: businessId,
            ownerEmail: ownerEmail,
            ownerUserId: ownerUserId
        )
    }

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

    @discardableResult
    func refreshActiveBusinessBanGateAndRestoreBusinessSessionIfAllowed(reason: String) async -> Bool {
        let isBanned = await refreshActiveBusinessBanGate(checkPath: reason)
        guard !isBanned else { return true }
        _ = await ensureBusinessOwnerSessionFlagsIfPossible(context: "\(reason)_restore_business")
        return false
    }

    @discardableResult
    func refreshActiveBusinessBanGate(
        checkPath: String,
        businessId: UUID? = nil,
        ownerEmail: String? = nil,
        ownerUserId: UUID? = nil
    ) async -> Bool {
        await MainActor.run {
            isCheckingActiveBusinessBan = true
        }
        defer {
            Task { @MainActor [weak self] in
                self?.isCheckingActiveBusinessBan = false
            }
        }

        let context = await businessBanLookupContext(
            explicitBusinessId: businessId,
            explicitOwnerEmail: ownerEmail,
            explicitOwnerUserId: ownerUserId
        )

        logBusinessBanGate(
            checkPath: checkPath,
            businessId: context.primaryBusinessId,
            ownerEmail: context.ownerEmail,
            ban: nil,
            blocked: false,
            prefixOnly: true
        )

        guard !context.businessIds.isEmpty
            || OwnerBusinessEmail.isValidStrict(context.ownerEmail)
            || context.ownerUserId != nil else {
            await clearBusinessBanGateIfNeeded(logLifted: false)
            logBusinessBanGate(
                checkPath: checkPath,
                businessId: nil,
                ownerEmail: context.ownerEmail,
                ban: nil,
                blocked: false
            )
            return false
        }

        do {
            let ban = try await fetchActiveBusinessBanViaRPC(context: context)
            if let ban {
                await MainActor.run {
                    activeBusinessAccountBan = ban
                    isBusinessBanGatePresented = true
                    if OwnerBusinessEmail.isValidStrict(context.ownerEmail) {
                        venueOwnerEmail = context.ownerEmail
                    }
                    currentUserAuthId = context.ownerUserId ?? currentUserAuthId
                    isVenueOwnerLoggedIn = false
                    venueOwnerMode = false
                    currentUserIsBusinessAccount = false
                    isBusinessOwnerSessionRestorePending = false
                }
                logBusinessBanGate(
                    checkPath: checkPath,
                    businessId: context.primaryBusinessId,
                    ownerEmail: context.ownerEmail,
                    ban: ban,
                    blocked: true
                )
                return true
            }

            await clearBusinessBanGateIfNeeded(logLifted: true)
            logBusinessBanGate(
                checkPath: checkPath,
                businessId: context.primaryBusinessId,
                ownerEmail: context.ownerEmail,
                ban: nil,
                blocked: false
            )
            return false
        } catch {
#if DEBUG
            print("[BusinessBanGateDebug] rpcError=\(error.localizedDescription)")
#endif
            let confirmed = await MainActor.run { activeBusinessAccountBan }
            let blocked = confirmed != nil
            logBusinessBanGate(
                checkPath: checkPath,
                businessId: context.primaryBusinessId,
                ownerEmail: context.ownerEmail,
                ban: confirmed,
                blocked: blocked
            )
            return blocked
        }
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

    private func clearBusinessBanGateIfNeeded(logLifted: Bool) async {
        let hadBan = await MainActor.run { activeBusinessAccountBan != nil }
        await MainActor.run {
            activeBusinessAccountBan = nil
            isBusinessBanGatePresented = false
        }
        if hadBan && logLifted {
#if DEBUG
            print("[BusinessBanGateDebug] banLiftedOrExpired=true")
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

    private func logBusinessBanGuard(path: String, action: String, ban: FanGeoAccountBan?, blocked: Bool) {
#if DEBUG
        print("[BusinessBanGuardDebug] path=\(path)")
        print("[BusinessBanGuardDebug] action=\(action)")
        print("[BusinessBanGuardDebug] banned=\(ban != nil)")
        print("[BusinessBanGuardDebug] blocked=\(blocked)")
        print("[BusinessBanGuardDebug] bannedUntil=\(ban?.bannedUntilRaw ?? "nil")")
        print("[BusinessBanGuardDebug] isPermanent=\(ban?.isPermanent.description ?? "nil")")
#endif
    }

    private struct BusinessBanLookupContext {
        let businessIds: [UUID]
        let ownerEmail: String
        let ownerUserId: UUID?

        var primaryBusinessId: UUID? { businessIds.first }
    }

    private func businessBanLookupContext(
        explicitBusinessId: UUID?,
        explicitOwnerEmail: String?,
        explicitOwnerUserId: UUID?
    ) async -> BusinessBanLookupContext {
        let sessionUserId: UUID?
        let sessionEmail: String?
        switch await supabaseResolvedAuthSessionResult() {
        case .active(let session):
            sessionUserId = session.user.id
            sessionEmail = session.user.email
            await MainActor.run {
                currentUserAuthId = session.user.id
            }
        case .missingSession, .refreshFailed:
            sessionUserId = nil
            sessionEmail = nil
        }

        let stateEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
        let normalizedEmail = OwnerBusinessEmail.normalized(
            explicitOwnerEmail ?? (OwnerBusinessEmail.isValidStrict(stateEmail) ? stateEmail : (sessionEmail ?? ""))
        )
        let resolvedOwnerUserId = explicitOwnerUserId ?? currentUserAuthId ?? sessionUserId

        var ids: [UUID] = []
        if let explicitBusinessId { ids.append(explicitBusinessId) }
        if let current = currentBusinessIdForAddLocation() { ids.append(current) }
        ids.append(contentsOf: ownedBusinesses.map(\.id))
        ids.append(contentsOf: managedVenuesForOwner().compactMap(\.business_id))

        if OwnerBusinessEmail.isValidStrict(normalizedEmail) || resolvedOwnerUserId != nil {
            do {
                let linked = try await fetchBusinessIdsForBanLookup(
                    ownerEmail: normalizedEmail,
                    ownerUserId: resolvedOwnerUserId
                )
                ids.append(contentsOf: linked)
            } catch {
#if DEBUG
                print("[BusinessBanGateDebug] businessLookupFailed=\(error.localizedDescription)")
#endif
            }
        }

        var seen = Set<UUID>()
        let uniqueIds = ids.filter { seen.insert($0).inserted }
        return BusinessBanLookupContext(
            businessIds: uniqueIds,
            ownerEmail: normalizedEmail,
            ownerUserId: resolvedOwnerUserId
        )
    }

    private func fetchBusinessIdsForBanLookup(ownerEmail: String, ownerUserId: UUID?) async throws -> [UUID] {
        struct BusinessIdRow: Decodable {
            let id: UUID
        }

        var rows: [BusinessIdRow] = []
        if OwnerBusinessEmail.isValidStrict(ownerEmail) {
            rows += try await supabase
                .from("businesses")
                .select("id")
                .eq("owner_email", value: ownerEmail)
                .limit(25)
                .execute()
                .value
        }

        if let ownerUserId {
            rows += try await supabase
                .from("businesses")
                .select("id")
                .eq("owner_user_id", value: ownerUserId.uuidString.lowercased())
                .limit(25)
                .execute()
                .value
        }

        var seen = Set<UUID>()
        return rows.map(\.id).filter { seen.insert($0).inserted }
    }

    private struct ActiveBusinessBanRPCParams: Encodable {
        let p_business_id: UUID?
        let p_owner_email: String?
    }

    private func fetchActiveBusinessBanViaRPC(context: BusinessBanLookupContext) async throws -> FanGeoAccountBan? {
        let businessIdsToCheck: [UUID?] = context.businessIds.isEmpty ? [nil] : context.businessIds.map(Optional.some)
        for businessId in businessIdsToCheck {
            let params = ActiveBusinessBanRPCParams(
                p_business_id: businessId,
                p_owner_email: OwnerBusinessEmail.isValidStrict(context.ownerEmail) ? context.ownerEmail : nil
            )
#if DEBUG
            print("[BusinessBanGateDebug] rpcCalled=true")
#endif
            let response = try await supabase
                .rpc("get_my_active_business_ban", params: params)
                .execute()
            if let ban = try Self.decodeActiveBan(from: response.data) {
                return ban
            }
        }
        return nil
    }

    private func logBusinessBanGate(
        checkPath: String,
        businessId: UUID?,
        ownerEmail: String,
        ban: FanGeoAccountBan?,
        blocked: Bool,
        prefixOnly: Bool = false
    ) {
#if DEBUG
        print("[BusinessBanGateDebug] checkPath=\(checkPath)")
        print("[BusinessBanGateDebug] businessId=\(businessId?.uuidString.lowercased() ?? "nil")")
        print("[BusinessBanGateDebug] ownerEmail=\(ownerEmail.isEmpty ? "nil" : ownerEmail)")
        guard !prefixOnly else { return }
        print("[BusinessBanGateDebug] activeBanFound=\(ban != nil)")
        print("[BusinessBanGateDebug] isPermanent=\(ban?.isPermanent.description ?? "nil")")
        print("[BusinessBanGateDebug] bannedUntil=\(ban?.bannedUntilRaw ?? "nil")")
        print("[BusinessBanGateDebug] blocked=\(blocked)")
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
