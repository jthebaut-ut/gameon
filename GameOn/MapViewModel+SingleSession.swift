import Foundation
import Supabase

extension MapViewModel {
    static let fanSingleDeviceLogoutMessage =
        "You were signed out because your account was opened on another device."

    private static let activeSessionSelect = "active_session_id,active_session_updated_at"

    /// Fan email/password session only — not venue-owner or admin surfaces.
    var isEligibleForFanSingleSessionEnforcement: Bool {
        isLoggedIn
            && !isVenueOwnerLoggedIn
            && !venueOwnerMode
            && currentUserAuthId != nil
    }

    /// After successful fan login / sign-up: claim this device as the active session.
    func registerFanActiveSessionOnLogin() async {
        guard isEligibleForFanSingleSessionEnforcement else { return }
        guard let userId = currentUserAuthId else { return }

        let sessionId = UUID()
        FanSingleSessionStore.saveLocalSessionId(sessionId)
        singleSessionIgnoreRealtimeUntil = Date().addingTimeInterval(3)

#if DEBUG
        print("[SingleSessionDebug] loginSessionId=\(sessionId.uuidString.lowercased())")
        print("[SingleSessionDebug] localSessionId=\(sessionId.uuidString.lowercased())")
#endif

        let wrote = await writeRemoteActiveSession(userId: userId, sessionId: sessionId)
        if wrote {
#if DEBUG
            print("[SingleSessionDebug] remoteSessionId=\(sessionId.uuidString.lowercased())")
#endif
        }

        await startFanSingleSessionRealtimeIfNeeded()
    }

    /// Foreground / restore: compare local vs remote; network failures do not sign out.
    func enforceFanSingleSessionOnForeground() async {
        await enforceFanSingleSessionFromRemoteCheck(source: "foreground")
    }

    func startFanSingleSessionRealtimeIfNeeded() async {
        guard isEligibleForFanSingleSessionEnforcement, let userId = currentUserAuthId else {
            await stopFanSingleSessionRealtime()
            return
        }

        if fanSingleSessionRealtimeTask != nil, fanSingleSessionRealtimeChannel != nil {
            return
        }

        await stopFanSingleSessionRealtime()

        fanSingleSessionRealtimeTask = Task { [weak self] in
            guard let self else { return }
            await self.runFanSingleSessionRealtimeLoop(userId: userId)
        }
    }

    func stopFanSingleSessionRealtime() async {
        fanSingleSessionRealtimeDebounceTask?.cancel()
        fanSingleSessionRealtimeDebounceTask = nil

        if let task = fanSingleSessionRealtimeTask {
            task.cancel()
            _ = await task.result
            fanSingleSessionRealtimeTask = nil
        }

        if let channel = fanSingleSessionRealtimeChannel {
            await supabase.removeChannel(channel)
            fanSingleSessionRealtimeChannel = nil
        }
    }

    /// On fan logout: clear local id; clear remote only when it still matches this device.
    func clearFanActiveSessionOnLogout() async {
        await stopFanSingleSessionRealtime()

        guard let userId = currentUserAuthId else {
            FanSingleSessionStore.clearLocalSessionId()
            return
        }

        let local = FanSingleSessionStore.localSessionId()
        if let local,
           case .remote(let remote) = await fetchRemoteActiveSessionId(userId: userId),
           remote == local {
            _ = await patchRemoteActiveSession(userId: userId, sessionId: nil)
        }

        FanSingleSessionStore.clearLocalSessionId()
    }

    // MARK: - Core check

    private func enforceFanSingleSessionFromRemoteCheck(source: String) async {
        guard isEligibleForFanSingleSessionEnforcement else { return }
        guard !isPerformingSingleSessionLogout else { return }
        guard !UserDefaults.standard.bool(forKey: "didExplicitlyLogout") else { return }
        guard let userId = currentUserAuthId else { return }

        if let local = FanSingleSessionStore.localSessionId() {
#if DEBUG
            print("[SingleSessionDebug] localSessionId=\(local)")
#endif
            switch await fetchRemoteActiveSessionId(userId: userId) {
            case .networkFailure:
#if DEBUG
                print("[SingleSessionDebug] remoteSessionId=unavailable source=\(source)")
#endif
                return
            case .noRemote:
#if DEBUG
                print("[SingleSessionDebug] remoteSessionId=nil")
#endif
                return
            case .remote(let remote):
#if DEBUG
                print("[SingleSessionDebug] remoteSessionId=\(remote)")
#endif
                if remote != local {
                    await logoutDueToSingleSessionMismatch(
                        remoteId: remote,
                        localId: local,
                        source: source,
                        realtime: source == "realtime"
                    )
                }
            }
            return
        }

        // No local session yet (upgrade / fresh install): claim this device without signing out.
        let sessionId = UUID()
        FanSingleSessionStore.saveLocalSessionId(sessionId)
        singleSessionIgnoreRealtimeUntil = Date().addingTimeInterval(3)
        _ = await writeRemoteActiveSession(userId: userId, sessionId: sessionId)
#if DEBUG
        print("[SingleSessionDebug] loginSessionId=\(sessionId.uuidString.lowercased()) source=\(source)_claim")
        print("[SingleSessionDebug] localSessionId=\(sessionId.uuidString.lowercased())")
        print("[SingleSessionDebug] remoteSessionId=\(sessionId.uuidString.lowercased())")
#endif
        await startFanSingleSessionRealtimeIfNeeded()
    }

    private func logoutDueToSingleSessionMismatch(
        remoteId: String,
        localId: String,
        source: String,
        realtime: Bool
    ) async {
        guard !isPerformingSingleSessionLogout else { return }
        guard !isAuthSessionRestoringForProfilePresentation,
              authSessionState != .loadingSession,
              authSessionState != .authRefreshFailed else {
#if DEBUG
            print("[SingleSessionDebug] mismatchIgnored=true reason=authLoadingOrRefreshFailed source=\(source)")
#endif
            return
        }

        let now = Date()
        if let pending = pendingSingleSessionMismatch,
           pending.remoteId == remoteId,
           pending.localId == localId,
           now.timeIntervalSince(pending.detectedAt) >= 5 {
#if DEBUG
            print("[SingleSessionDebug] mismatchConfirmedTwice=true source=\(source)")
#endif
            pendingSingleSessionMismatch = nil
        } else {
            if pendingSingleSessionMismatch == nil ||
                pendingSingleSessionMismatch?.remoteId != remoteId ||
                pendingSingleSessionMismatch?.localId != localId {
                pendingSingleSessionMismatch = (remoteId: remoteId, localId: localId, source: source, detectedAt: now)
#if DEBUG
                print("[SingleSessionDebug] mismatchPending=true source=\(source)")
                print("[SingleSessionDebug] mismatchConfirmDelaySeconds=5")
#endif
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await self?.enforceFanSingleSessionFromRemoteCheck(source: "\(source)_confirm")
                }
            } else {
#if DEBUG
                print("[SingleSessionDebug] mismatchPending=true source=\(source) waitingForConfirm=true")
#endif
            }
            return
        }

        isPerformingSingleSessionLogout = true
        defer { isPerformingSingleSessionLogout = false }

#if DEBUG
        print("[SingleSessionDebug] mismatchLogout=true source=\(source)")
        print("[SingleSessionDebug] realtimeMismatch=\(realtime)")
        print("[SingleSessionDebug] remoteSessionId=\(remoteId)")
        print("[SingleSessionDebug] localSessionId=\(localId)")
#endif

        await stopFanSingleSessionRealtime()
        FanSingleSessionStore.clearLocalSessionId()

        await forceLogout(reason: "singleSessionMismatch", source: "MapViewModel.logoutDueToSingleSessionMismatch")
        await MainActor.run {
            authErrorMessage = Self.fanSingleDeviceLogoutMessage
        }
    }

    // MARK: - Supabase

    private struct ActiveSessionRow: Decodable {
        let active_session_id: String?
    }

    private struct ActiveSessionPatch: Encodable {
        let active_session_id: String?
        let active_session_updated_at: String?
    }

    private enum RemoteActiveSessionFetchResult {
        case networkFailure
        case noRemote
        case remote(String)
    }

    private func fetchRemoteActiveSessionId(userId: UUID) async -> RemoteActiveSessionFetchResult {
        do {
            let rows: [ActiveSessionRow] = try await supabase
                .from("user_profiles")
                .select(Self.activeSessionSelect)
                .eq("id", value: userId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value

            let raw = rows.first?.active_session_id?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard let raw, !raw.isEmpty else { return .noRemote }
            return .remote(raw)
        } catch {
#if DEBUG
            print("[SingleSessionDebug] fetch_failed error=\(error.localizedDescription)")
#endif
            return .networkFailure
        }
    }

    @discardableResult
    private func writeRemoteActiveSession(userId: UUID, sessionId: UUID) async -> Bool {
        await patchRemoteActiveSession(userId: userId, sessionId: sessionId.uuidString.lowercased())
    }

    @discardableResult
    private func patchRemoteActiveSession(userId: UUID, sessionId: String?) async -> Bool {
        let patch = ActiveSessionPatch(
            active_session_id: sessionId,
            active_session_updated_at: sessionId == nil ? nil : ISO8601DateFormatter().string(from: Date())
        )

        do {
            try await supabase
                .from("user_profiles")
                .update(patch)
                .eq("id", value: userId.uuidString.lowercased())
                .execute()
            return true
        } catch {
#if DEBUG
            print("[SingleSessionDebug] patch_failed error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    // MARK: - Realtime

    private func runFanSingleSessionRealtimeLoop(userId: UUID) async {
        let channel = supabase.channel("fan-single-session-\(userId.uuidString.lowercased())")
        fanSingleSessionRealtimeChannel = channel

        let filter = RealtimePostgresFilter.eq("id", value: userId)
        let stream = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "user_profiles",
            filter: filter
        )

        do {
            try await channel.subscribeWithError()
        } catch {
            if fanSingleSessionRealtimeChannel === channel {
                fanSingleSessionRealtimeChannel = nil
            }
            return
        }

        for await _ in stream {
            guard !Task.isCancelled else { break }

            if let ignoreUntil = singleSessionIgnoreRealtimeUntil, Date() < ignoreUntil {
                continue
            }

            fanSingleSessionRealtimeDebounceTask?.cancel()
            fanSingleSessionRealtimeDebounceTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await self.enforceFanSingleSessionFromRemoteCheck(source: "realtime")
            }
        }
    }
}
