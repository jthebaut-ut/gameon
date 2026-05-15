import SwiftUI

/// Shared locked-state card for Discover venue games and pickup detail when ``MapViewModel/isGuestDiscoverMode``.
struct DiscoverGuestGameLockCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let onLogInSignUp: () -> Void

    var body: some View {
        FGCard {
            VStack(alignment: .leading, spacing: FGSpacing.md) {
                HStack(alignment: .top, spacing: FGSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.22 : 0.14))
                            .frame(width: 44, height: 44)
                        Image(systemName: "lock.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(FGColor.accentBlue)
                    }

                    Text("Create or log in to your FanGeo account to see game details.")
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

                FGPrimaryButton(title: "Log in / Sign up", action: onLogInSignUp)

                Text("FanGeo accounts are required to view details, join pickup games, save venues, and interact with events.")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
