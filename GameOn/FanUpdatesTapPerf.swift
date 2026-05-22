import SwiftUI
import UIKit

/// Identifiable sheet token for Fan Updates (immediate presentation).
struct FanUpdatesSheetEvent: Identifiable, Equatable {
    let id: UUID
    let title: String?

    init(id: UUID, title: String? = nil) {
        self.id = id
        self.title = title
    }
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

#if DEBUG
        print("[FanUpdatesTapPerf] tapReceived eventId=\(eventId.uuidString.lowercased())")
#endif
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        present()
#if DEBUG
        print("[FanUpdatesTapPerf] sheetPresentedImmediately=true")
#endif
    }

    static func logCommentLoadStarted(eventId: UUID) {
#if DEBUG
        print("[FanUpdatesTapPerf] commentLoadStarted=\(eventId.uuidString.lowercased())")
#endif
    }

    static func logCommentLoadCompleted(ms: Double) {
#if DEBUG
        print("[FanUpdatesTapPerf] commentLoadCompletedMs=\(String(format: "%.0f", ms))")
#endif
    }

    static func logAdLoadStartedNonBlocking() {
#if DEBUG
        print("[FanUpdatesTapPerf] adLoadStartedNonBlocking=true")
#endif
    }

    static func logAdInsertedAfterComments() {
#if DEBUG
        print("[FanUpdatesTapPerf] adInsertedAfterComments=true")
#endif
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
