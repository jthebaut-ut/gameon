import Combine
import Foundation
import SwiftUI

/// Lightweight in-app notifications (foreground only).
/// TODO(APNs): bridge these events to push notifications for background delivery.
@MainActor
final class InAppNotificationCenter: ObservableObject {
    static let shared = InAppNotificationCenter()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let subtitle: String?
        let createdAt = Date()
    }

    @Published private(set) var toast: Toast?

    private var dismissTask: Task<Void, Never>?

    func post(title: String, subtitle: String? = nil, autoDismissAfter seconds: TimeInterval = 2.6) {
        dismissTask?.cancel()
        toast = Toast(title: title, subtitle: subtitle)
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.6, seconds) * 1_000_000_000)) } catch { return }
            await MainActor.run { self?.toast = nil }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        toast = nil
    }
}

