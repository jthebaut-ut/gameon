import Combine
import Foundation
import SwiftUI

@MainActor
final class BootstrapLoadingCoordinator: ObservableObject {
    @Published private(set) var isBootstrapping = true
    @Published private(set) var bootstrapError: String?
    @Published private(set) var shouldUseMainTabFallbackBootstrap = false

    private var didStart = false
    private let minimumVisibleSeconds: TimeInterval = 1.15
    private let maximumWaitSeconds: TimeInterval = 5.5

    func beginIfNeeded(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel
    ) async {
        guard !didStart else { return }
        didStart = true

        let startedAt = Date()
        let bootstrapTask = Task {
            await Self.performBootstrap(
                viewModel: viewModel,
                chatViewModel: chatViewModel
            )
        }

        let completedInTime = await waitForCompletion(
            bootstrapTask,
            timeoutSeconds: maximumWaitSeconds
        )

        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed < minimumVisibleSeconds {
            let remaining = minimumVisibleSeconds - elapsed
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }

        if completedInTime {
            shouldUseMainTabFallbackBootstrap = false
        } else {
            bootstrapError = "Opening FanGeo while the rest finishes loading."
            bootstrapTask.cancel()
            shouldUseMainTabFallbackBootstrap = true
        }

        withAnimation(.easeInOut(duration: 0.45)) {
            isBootstrapping = false
        }
    }

    private static func performBootstrap(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel
    ) async {
        await MainActor.run {
            viewModel.renderCachedDiscoverCore()
        }

        await viewModel.bootstrapAuthSessionOnly()

        async let discoverCore: Void = {
            await viewModel.refreshDiscoverCoreInBackground()
        }()

        async let personalization: Void = {
            await viewModel.refreshUserPersonalizationInBackground()
        }()

        async let chatBootstrap: Void = {
            let shouldLoadChat = await MainActor.run {
                viewModel.isAuthenticatedForSocialFeatures
            }
            if shouldLoadChat {
                await chatViewModel.loadIfNeeded()
            } else {
                await MainActor.run {
                    chatViewModel.clearForSignOut()
                }
            }
        }()

        _ = await (discoverCore, personalization, chatBootstrap)
    }

    private func waitForCompletion(
        _ task: Task<Void, Never>,
        timeoutSeconds: TimeInterval
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return false
            }

            let finished = await group.next() ?? true
            group.cancelAll()
            return finished
        }
    }
}
