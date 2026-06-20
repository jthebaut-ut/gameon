
import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

@main
struct WatchZoneApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(FanGeoAppDelegate.self) private var appDelegate
    #endif

    @AppStorage(FanGeoAppearancePreference.appStorageKey) private var appearancePreferenceRaw = FanGeoAppearancePreference.system.rawValue
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    init() {
        GoogleMobileAdsBootstrap.startIfNeeded()
        #if DEBUG
        let b = Bundle.main
        print("GAMEON_DEBUG bundlePath=\(b.bundlePath)")
        print("GAMEON_DEBUG executablePath=\(b.executablePath ?? "(nil)")")
        print("GAMEON_DEBUG bundleIdentifier=\(b.bundleIdentifier ?? "(nil)")")
        print("[FanGeoLoadingDebug] launchScreenLoaded")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            FanGeoAdConsentPrePromptHost {
                ContentView()
            }
                .preferredColorScheme(appearancePreference.colorScheme)
                .environment(\.locale, Locale(identifier: L10n.normalizedLanguageCode(appLanguageRaw)))
                .onAppear {
                    #if DEBUG
                    print("[LaunchPathDebug] WatchZoneAppMounted=true")
                    #endif
                }
        }
    }

    private var appearancePreference: FanGeoAppearancePreference {
        FanGeoAppearancePreference(rawValue: appearancePreferenceRaw) ?? .system
    }
}

#if canImport(UIKit)
private final class FanGeoAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task {
            await PushNotificationRegistrationService.shared.refreshPushTokenRegistration(reason: "appLaunch")
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushNotificationRegistrationService.shared.handleDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushNotificationRegistrationService.shared.handleRegistrationFailure(error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
#if DEBUG
        print("[RemoteNotificationDebug] received userInfo=\(userInfo)")
#endif
        completionHandler(.noData)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }
}
#endif

private struct FanGeoAdConsentPrePromptHost<Content: View>: View {
    let content: Content
    @State private var showsPreConsentPrompt = false
    @State private var shouldContinueConsentFlowAfterDismissal = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .sheet(
                isPresented: $showsPreConsentPrompt,
                onDismiss: {
                    guard shouldContinueConsentFlowAfterDismissal else { return }
                    shouldContinueConsentFlowAfterDismissal = false
                    GoogleMobileAdsBootstrap.acknowledgePreConsentPromptAndContinue()
                }
            ) {
                FanGeoAdConsentPrePromptView {
                    shouldContinueConsentFlowAfterDismissal = true
                    showsPreConsentPrompt = false
                }
                .interactiveDismissDisabled()
                .presentationDetents([.medium])
                .presentationDragIndicator(.hidden)
            }
            .onAppear {
                showsPreConsentPrompt = GoogleMobileAdsBootstrap.shouldPresentPreConsentPrompt
            }
    }
}

private struct FanGeoAdConsentPrePromptView: View {
    let onContinue: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Help Keep FanGeo Free")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                Text(preConsentBody)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(FGColor.brandGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(FGAdaptiveSurface.sheetRoot.ignoresSafeArea())
    }

    private var preConsentBody: String {
        """
        FanGeo uses advertising to support:
        • Venue discovery
        • Pickup games
        • Community sports places
        • Fan chat and social features

        You can choose personalized ads, or continue with non-personalized or limited ads where available.
        """
    }
}
