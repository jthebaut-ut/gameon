
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
