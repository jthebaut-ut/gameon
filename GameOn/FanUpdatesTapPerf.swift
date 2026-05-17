import SwiftUI
import UIKit

/// Identifiable sheet token for Fan Updates (immediate presentation).
struct FanUpdatesSheetEvent: Identifiable, Equatable {
    let id: UUID
}

enum FanUpdatesTapPerf {
    private static var lastEventID: UUID?
    private static var lastTapTime: CFAbsoluteTime = 0
    private static let debounceInterval: CFTimeInterval = 0.5

    /// Presents Fan Updates sheet state on the main actor; debounces duplicate taps on the same event.
    @MainActor
    static func handleTap(eventId: UUID, present: () -> Void) {
        let now = CFAbsoluteTimeGetCurrent()
        if lastEventID == eventId, now - lastTapTime < debounceInterval {
            return
        }
        lastEventID = eventId
        lastTapTime = now

        print("[FanUpdatesTapPerf] tapReceived eventId=\(eventId.uuidString.lowercased())")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        present()
        print("[FanUpdatesTapPerf] sheetPresentedImmediately=true")
    }

    static func logCommentLoadStarted(eventId: UUID) {
        print("[FanUpdatesTapPerf] commentLoadStarted=\(eventId.uuidString.lowercased())")
    }

    static func logCommentLoadCompleted(ms: Double) {
        print("[FanUpdatesTapPerf] commentLoadCompletedMs=\(String(format: "%.0f", ms))")
    }

    static func logAdLoadStartedNonBlocking() {
        print("[FanUpdatesTapPerf] adLoadStartedNonBlocking=true")
    }

    static func logAdInsertedAfterComments() {
        print("[FanUpdatesTapPerf] adInsertedAfterComments=true")
    }
}

struct FanUpdatesPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
