import Foundation

/// Legacy internal XP thresholds kept for persisted-account compatibility.
enum FanXPLevelCalculator {
    private static let anchors: [(level: Int, xp: Int)] = [
        (1, 0), (2, 100), (3, 250), (4, 450), (5, 700),
        (10, 3000), (15, 8000), (20, 15000), (30, 40000), (50, 120000)
    ]

    static let maxLevel = 50

    static func xpForCurrentLevel(_ level: Int) -> Int {
        thresholdForLevel(level)
    }

    static func xpForNextLevel(_ level: Int) -> Int? {
        let l = max(1, level)
        guard l < maxLevel else { return nil }
        return thresholdForLevel(l + 1)
    }

    static func levelForXP(_ totalXP: Int) -> Int {
        let total = max(0, totalXP)
        if total >= 120_000 { return maxLevel }
        var level = 1
        while level < maxLevel, total >= thresholdForLevel(level + 1) {
            level += 1
        }
        return level
    }

    static func titleForLevel(_ level: Int) -> String {
        let l = max(1, level)
        if l >= 40 { return "FanGeo Elite" }
        if l >= 25 { return "Hardcore Supporter" }
        if l >= 15 { return "Stadium Legend" }
        if l >= 10 { return "Super Fan" }
        if l >= 5 { return "Loyal Fan" }
        return "Rookie Fan"
    }

    static func thresholdForLevel(_ level: Int) -> Int {
        let l = max(1, level)
        if l <= 1 { return 0 }
        if l == 2 { return 100 }
        if l == 3 { return 250 }
        if l == 4 { return 450 }
        if l == 5 { return 700 }
        if l <= 9 {
            return 700 + ((3000 - 700) * (l - 5)) / 4
        }
        if l == 10 { return 3000 }
        if l <= 14 {
            return 3000 + ((8000 - 3000) * (l - 10)) / 4
        }
        if l == 15 { return 8000 }
        if l <= 19 {
            return 8000 + ((15000 - 8000) * (l - 15)) / 4
        }
        if l == 20 { return 15000 }
        if l <= 29 {
            return 15000 + ((40000 - 15000) * (l - 20)) / 9
        }
        if l == 30 { return 40000 }
        if l <= 49 {
            return 40000 + ((120000 - 40000) * (l - 30)) / 19
        }
        return 120_000
    }
}

struct FanXPState: Equatable {
    let totalXP: Int
    let level: Int
    let title: String

    static let rookie = FanXPState(totalXP: 0, level: 1, title: "Rookie Fan")

    var progressFraction: Double {
        guard let nextThreshold = FanXPLevelCalculator.xpForNextLevel(level) else { return 1 }
        let currentThreshold = FanXPLevelCalculator.xpForCurrentLevel(level)
        let span = max(1, nextThreshold - currentThreshold)
        let earned = max(0, totalXP - currentThreshold)
        return min(1, Double(earned) / Double(span))
    }

    var xpIntoCurrentLevel: Int {
        max(0, totalXP - FanXPLevelCalculator.xpForCurrentLevel(level))
    }

    var xpToNextLevel: Int? {
        guard let next = FanXPLevelCalculator.xpForNextLevel(level) else { return nil }
        return max(0, next - totalXP)
    }

    var progressLine: String {
        if let remaining = xpToNextLevel {
            return "\(remaining.formatted()) internal reputation signals to next tier"
        }
        return "Highest internal tier reached"
    }

    var xpRangeLine: String {
        if let next = FanXPLevelCalculator.xpForNextLevel(level) {
            return "\(xpIntoCurrentLevel.formatted()) / \((next - FanXPLevelCalculator.xpForCurrentLevel(level)).formatted()) internal signals"
        }
        return "\(totalXP.formatted()) internal signals"
    }
}
