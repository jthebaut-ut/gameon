import Foundation

extension MapViewModel {
    private static let fanXPService = FanXPService()

    func refreshProfileXP() async {
        guard let uid = currentUserAuthId, isLoggedIn, !isVenueOwnerLoggedIn else {
            await MainActor.run { currentUserFanXP = .rookie }
            return
        }
        let state = await Self.fanXPService.loadUserXP(userId: uid)
        await MainActor.run { currentUserFanXP = state }
    }

    /// Awards XP via RPC; refreshes profile summary and queues reward overlay when newly awarded.
    func awardFanXP(
        userId: UUID,
        amount: Int,
        source: String,
        sourceId: UUID? = nil,
        sourceKey: String = "",
        showToast: Bool = true
    ) async {
        guard amount > 0 else { return }

        let previousLevel = await MainActor.run {
            userId == currentUserAuthId ? currentUserFanXP.level : 0
        }

        let result = await Self.fanXPService.awardXP(
            userId: userId,
            amount: amount,
            source: source,
            sourceId: sourceId,
            sourceKey: sourceKey
        )

        guard let result else { return }

        if result.awarded == true {
            if userId == currentUserAuthId {
                await refreshProfileXP()
            }
            if showToast, userId == currentUserAuthId {
                let gained = result.xp_gained ?? amount
                let newLevel = await MainActor.run { currentUserFanXP.level }
                let newTitle = await MainActor.run { currentUserFanXP.title }
                await MainActor.run {
                    if newLevel > previousLevel {
                        fanXPRewardOverlay.enqueueLevelUp(level: newLevel, title: newTitle)
                    } else {
                        fanXPRewardOverlay.enqueueXP(amount: gained, source: source)
                    }
                }
            }
        } else if userId == currentUserAuthId, let total = result.total_xp, let level = result.level, let title = result.title {
            await MainActor.run {
                currentUserFanXP = FanXPState(totalXP: total, level: level, title: title)
            }
        }
    }

    /// Routes XP feedback through the premium overlay (not ``showSocialActionToast``).
    func showFanXPToast(_ message: String) {
        let parts = message.split(separator: "·", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if parts.count == 2, parts[0].hasPrefix("+"), parts[0].contains("XP") {
            let amountDigits = parts[0].filter(\.isNumber)
            if let amount = Int(amountDigits) {
                fanXPRewardOverlay.enqueue(
                    .xpGain(amount: amount, subtitle: parts[1])
                )
                return
            }
        }
        fanXPRewardOverlay.enqueue(
            FanXPRewardPresentation(
                id: UUID(),
                kind: .xpGain,
                primaryLine: message,
                secondaryLine: "FanGeo"
            )
        )
    }
}
