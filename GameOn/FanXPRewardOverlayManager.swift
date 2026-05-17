import Combine
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Presentation model for a single queued reputation toast.
struct FanXPRewardPresentation: Identifiable, Equatable {
    enum Kind: Equatable {
        case reputationSignal
        case reputationMilestone
    }

    let id: UUID
    let kind: Kind
    let primaryLine: String
    let secondaryLine: String

    var isLevelUp: Bool { kind == .reputationMilestone }

    static func xpGain(amount: Int, subtitle: String) -> FanXPRewardPresentation {
        FanXPRewardPresentation(
            id: UUID(),
            kind: .reputationSignal,
            primaryLine: "Reputation noted",
            secondaryLine: subtitle
        )
    }

    static func levelUp(level: Int, title: String) -> FanXPRewardPresentation {
        FanXPRewardPresentation(
            id: UUID(),
            kind: .reputationMilestone,
            primaryLine: title.uppercased(),
            secondaryLine: "Your FanGeo identity is growing"
        )
    }
}

/// Serializes reputation feedback UI so multiple awards never overlap.
@MainActor
final class FanXPRewardOverlayManager: ObservableObject {
    @Published private(set) var presentation: FanXPRewardPresentation?

    private var queue: [FanXPRewardPresentation] = []
    private var drainTask: Task<Void, Never>?

    func enqueueXP(amount: Int, source: String) {
        enqueue(.xpGain(amount: amount, subtitle: FanXPSource.rewardSubtitle(for: source)))
    }

    func enqueueLevelUp(level: Int, title: String) {
        enqueue(.levelUp(level: level, title: title))
    }

    func enqueue(_ item: FanXPRewardPresentation) {
        queue.append(item)
        startDrainIfNeeded()
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { drainTask = nil }

            while !queue.isEmpty {
                let next = queue.removeFirst()
                presentation = next
                playHaptic(for: next)

                let holdNs: UInt64 = next.isLevelUp ? 3_000_000_000 : 2_200_000_000
                try? await Task.sleep(nanoseconds: holdNs)

                presentation = nil
                try? await Task.sleep(nanoseconds: 380_000_000)
            }
        }
    }

    private func playHaptic(for item: FanXPRewardPresentation) {
#if canImport(UIKit)
        if item.isLevelUp {
            let notification = UINotificationFeedbackGenerator()
            notification.prepare()
            notification.notificationOccurred(.success)
            let impact = UIImpactFeedbackGenerator(style: .heavy)
            impact.prepare()
            impact.impactOccurred(intensity: 1)
        } else {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.prepare()
            impact.impactOccurred(intensity: 0.85)
        }
#endif
    }
}
