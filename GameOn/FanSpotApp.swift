
import SwiftUI

@main
struct WatchZoneApp: App {
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
            ContentView()
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
