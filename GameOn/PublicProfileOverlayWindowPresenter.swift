import Combine
import SwiftUI
import UIKit

/// Presents ``PublicUserProfilePreviewView`` in a dedicated high-level `UIWindow` so it appears above nested SwiftUI sheets.
@MainActor
enum PublicProfileOverlayWindowPresenter {
    private static var overlayWindow: UIWindow?
    private static var presentedUserId: UUID?
    private static var restoredKeyWindow: UIWindow?
    private static weak var activeSession: PublicProfileOverlaySession?

    static var isOverlayWindowActive: Bool {
        overlayWindow != nil && overlayWindow?.isHidden == false
    }

    static func syncPresentation(
        userId: UUID?,
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        activeSheetHint: String?
    ) {
        if let userId {
            if presentedUserId == userId, isOverlayWindowActive, activeSession?.isDismissing != true {
                logPresentation(activeSheet: activeSheetHint, presented: true, alreadyVisible: true)
                return
            }
            if isOverlayWindowActive, presentedUserId != userId, let activeSession {
                swapUser(
                    to: userId,
                    session: activeSession,
                    viewModel: viewModel,
                    chatViewModel: chatViewModel,
                    activeSheetHint: activeSheetHint
                )
                return
            }
            present(
                userId: userId,
                viewModel: viewModel,
                chatViewModel: chatViewModel,
                activeSheetHint: activeSheetHint
            )
        } else {
            dismiss(activeSheetHint: activeSheetHint)
        }
    }

    private static func present(
        userId: UUID,
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        activeSheetHint: String?
    ) {
        tearDown(activeSheetHint: activeSheetHint, silent: true)

        guard let scene = activeWindowScene() else {
            logPresentation(activeSheet: activeSheetHint, presented: false, alreadyVisible: false)
            return
        }

        let session = PublicProfileOverlaySession(userId: userId)
        session.onDismissCompleted = {
            viewModel.dismissPublicProfile()
            tearDown(activeSheetHint: activeSheetHint, silent: true)
        }
        activeSession = session

        let root = PublicProfileOverlayContainer(
            session: session,
            viewModel: viewModel,
            chatViewModel: chatViewModel
        )
        .environmentObject(viewModel)
        .environmentObject(chatViewModel)

        let hosting = UIHostingController(rootView: root)
        hosting.view.backgroundColor = .clear

        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 1)
        window.backgroundColor = .clear
        window.overrideUserInterfaceStyle = currentAppearancePreference.userInterfaceStyle
        window.rootViewController = hosting

        restoredKeyWindow = keyWindow(in: scene)
        window.isHidden = false
        window.makeKeyAndVisible()

        overlayWindow = window
        presentedUserId = userId

        logPresentation(activeSheet: activeSheetHint, presented: true, alreadyVisible: false)
    }

    private static func swapUser(
        to userId: UUID,
        session: PublicProfileOverlaySession,
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        activeSheetHint: String?
    ) {
        session.onDismissCompleted = {
            viewModel.dismissPublicProfile()
            tearDown(activeSheetHint: activeSheetHint, silent: true)
        }
        session.setUserId(userId)
        presentedUserId = userId
        logPresentation(activeSheet: activeSheetHint, presented: true, alreadyVisible: false)
    }

    private static func dismiss(activeSheetHint: String?, silent: Bool = false) {
        guard overlayWindow != nil else { return }

        if !silent, let activeSession, !activeSession.isDismissing {
            activeSession.requestDismiss()
            if !silent {
                logPresentation(activeSheet: activeSheetHint, presented: false, alreadyVisible: false)
            }
            return
        }

        tearDown(activeSheetHint: activeSheetHint, silent: silent)
    }

    private static func tearDown(activeSheetHint: String?, silent: Bool) {
        overlayWindow?.isHidden = true
        overlayWindow = nil
        presentedUserId = nil
        activeSession = nil

        if let restoredKeyWindow {
            restoredKeyWindow.makeKeyAndVisible()
        }
        restoredKeyWindow = nil

        if !silent {
            logPresentation(activeSheet: activeSheetHint, presented: false, alreadyVisible: false)
        }
    }

    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    }

    private static func keyWindow(in scene: UIWindowScene) -> UIWindow? {
        scene.windows.first(where: \.isKeyWindow)
    }

    private static var currentAppearancePreference: FanGeoAppearancePreference {
        let rawValue = UserDefaults.standard.string(forKey: FanGeoAppearancePreference.appStorageKey)
        return rawValue.flatMap(FanGeoAppearancePreference.init(rawValue:)) ?? .system
    }

    private static func logPresentation(activeSheet: String?, presented: Bool, alreadyVisible: Bool) {
#if DEBUG
        print("[PublicProfilePresentationDebug] presenter=custom_overlay")
        print("[PublicProfilePresentationDebug] swiftUIModalUsed=false")
        print("[PublicProfilePresentationDebug] overlayWindowUsed=\(isOverlayWindowActive)")
        print("[PublicProfilePresentationDebug] activeSheet=\(activeSheet ?? "")")
        print("[PublicProfilePresentationDebug] presented=\(presented) alreadyVisible=\(alreadyVisible)")
#endif
    }
}

// MARK: - Animation session

@MainActor
final class PublicProfileOverlaySession: ObservableObject {
    @Published private(set) var userId: UUID
    @Published private(set) var backdropOpacity: Double = 0
    @Published private(set) var cardOffset: CGFloat = 0
    @Published private(set) var cardScale: CGFloat = 0.96
    @Published private(set) var dragOffset: CGFloat = 0
    @Published private(set) var isDismissing = false

    var onDismissCompleted: (() -> Void)?

    private var presentTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    private static let offscreenOffset: CGFloat = 520
    private static let dismissDragThreshold: CGFloat = 120
    private static let presentSpring = Animation.spring(response: 0.44, dampingFraction: 0.86, blendDuration: 0.12)
    private static let dismissSpring = Animation.spring(response: 0.36, dampingFraction: 0.92, blendDuration: 0.08)
    private static let snapBackSpring = Animation.spring(response: 0.32, dampingFraction: 0.84)

    init(userId: UUID) {
        self.userId = userId
        cardOffset = Self.offscreenOffset
        cardScale = 0.96
        backdropOpacity = 0
    }

    func setUserId(_ newUserId: UUID) {
        guard newUserId != userId else { return }
        userId = newUserId
        isDismissing = false
        dragOffset = 0
        runPresentAnimation()
    }

    func runPresentAnimation() {
        presentTask?.cancel()
        dismissTask?.cancel()
        isDismissing = false
        dragOffset = 0
        cardOffset = Self.offscreenOffset
        cardScale = 0.96
        backdropOpacity = 0

        presentTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            withAnimation(Self.presentSpring) {
                backdropOpacity = 0.52
                cardOffset = 0
                cardScale = 1
            }
        }
    }

    func requestDismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        presentTask?.cancel()
        dismissTask?.cancel()

        withAnimation(Self.dismissSpring) {
            backdropOpacity = 0
            cardOffset = Self.offscreenOffset
            cardScale = 0.96
            dragOffset = 0
        }

        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            onDismissCompleted?()
        }
    }

    func updateDrag(translationY: CGFloat) {
        guard !isDismissing else { return }
        let clamped = max(0, translationY)
        dragOffset = clamped
        let progress = min(1, clamped / 280)
        backdropOpacity = 0.52 * (1 - progress * 0.55)
        cardScale = 1 - (progress * 0.02)
    }

    func endDrag(translationY: CGFloat, predictedEndY: CGFloat) {
        guard !isDismissing else { return }
        if translationY > Self.dismissDragThreshold || predictedEndY > Self.dismissDragThreshold + 40 {
            requestDismiss()
            return
        }
        withAnimation(Self.snapBackSpring) {
            dragOffset = 0
            backdropOpacity = 0.52
            cardScale = 1
        }
    }
}

// MARK: - Overlay UI

/// Dimmed full-screen backdrop + bottom card (not a SwiftUI `.sheet`).
struct PublicProfileOverlayContainer: View {
    @ObservedObject var session: PublicProfileOverlaySession
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let bottomInset = max(geo.safeAreaInsets.bottom, 8)
            let cardMaxHeight = min(geo.size.height * 0.92, 760)

            ZStack(alignment: .bottom) {
                Color.black
                    .opacity(session.backdropOpacity)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        session.requestDismiss()
                    }
                    .allowsHitTesting(!session.isDismissing && session.backdropOpacity > 0.01)

                profileCard(maxHeight: cardMaxHeight, bottomInset: bottomInset)
                    .offset(y: session.cardOffset + session.dragOffset)
                    .scaleEffect(session.cardScale, anchor: .bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .onAppear {
            session.runPresentAnimation()
        }
    }

    private func profileCard(maxHeight: CGFloat, bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            dragHandle
                .padding(.top, 6)
                .padding(.bottom, 4)

            PublicUserProfilePreviewView(
                userId: session.userId,
                viewModel: viewModel,
                onDismiss: { session.requestDismiss() }
            )
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: maxHeight)
        .background(
            colorScheme == .dark
                ? Color(red: 0.04, green: 0.05, blue: 0.07)
                : Color(red: 0.94, green: 0.95, blue: 0.97)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 24, y: -4)
        .padding(.bottom, bottomInset)
    }

    private var dragHandle: some View {
        VStack(spacing: 0) {
            Capsule(style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.32) : Color.black.opacity(0.18))
                .frame(width: 40, height: 5)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .contentShape(Rectangle())
        .gesture(dragToDismissGesture)
    }

    private var dragToDismissGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let vertical = value.translation.height
                let horizontal = abs(value.translation.width)
                guard vertical > 0, vertical > horizontal * 0.65 else { return }
                session.updateDrag(translationY: vertical)
            }
            .onEnded { value in
                session.endDrag(
                    translationY: max(0, value.translation.height),
                    predictedEndY: max(0, value.predictedEndTranslation.height)
                )
            }
    }
}
