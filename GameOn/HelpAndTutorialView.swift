import SwiftUI

// MARK: - Help & Tutorial (Settings)

enum FanGeoQuickGuideTopic: String, Identifiable, CaseIterable {
    case discover
    case live
    case calendar
    case going
    case chat
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .discover: return "Discover"
        case .live: return "Live"
        case .calendar: return "Calendar"
        case .going: return "Going"
        case .chat: return "Chat"
        case .profile: return "Profile"
        }
    }

    var summary: String {
        switch self {
        case .discover:
            return "Find sports bars, pickup games, and sports communities."
        case .live:
            return "Follow live games, scores, predictions, and activity."
        case .calendar:
            return "Save games and plan ahead."
        case .going:
            return "Keep track of games and events you're attending."
        case .chat:
            return "Connect with fans, friends, and venues."
        case .profile:
            return "Customize your FanGeo experience."
        }
    }

    var detail: String {
        switch self {
        case .discover:
            return "Explore the map to find sports bars, pickup games, watch parties, and sports communities near you. Save places you like and discover where fans gather."
        case .live:
            return "Follow live professional games, scores, predictions, and fan activity in real time. See where fans are gathering and what's happening right now."
        case .calendar:
            return "Save games, watch parties, and pickup events to your FanGeo calendar. Plan ahead and get reminders so you never miss a game."
        case .going:
            return "See all the professional games, watch parties, and pickup games you're planning to attend. Your personal sports agenda lives in one place."
        case .chat:
            return "Chat with fans, coordinate watch parties, and stay connected with friends and venues. Message before and after the action."
        case .profile:
            return "Choose favorite teams, set notifications, and customize how FanGeo works for you. Build your fan identity in one place."
        }
    }

    var systemImage: String {
        switch self {
        case .discover: return "map.fill"
        case .live: return "dot.radiowaves.left.and.right"
        case .calendar: return "calendar.badge.clock"
        case .going: return "heart.fill"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .profile: return "person.crop.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .discover: return FGColor.accentGreen
        case .live: return FGColor.dangerRed
        case .calendar: return Color(red: 0.58, green: 0.42, blue: 0.94)
        case .going: return FGColor.accentGreen
        case .chat: return FGColor.accentBlue
        case .profile: return FGColor.accentGreen
        }
    }
}

struct HelpAndTutorialView: View {
    var onContactSupport: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var showOnboardingTour = false
    @State private var selectedQuickGuide: FanGeoQuickGuideTopic?

    var body: some View {
        List {
            quickTourSection
            quickGuidesSection
            contactSupportSection
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: SettingsScrollBottomLayout.sheetScrollComfortInset)
        }
        .listStyle(.plain)
        .listSectionSpacing(10)
        .scrollContentBackground(.hidden)
        .background(SettingsPremiumChrome.screenBackground(colorScheme).ignoresSafeArea())
        .navigationTitle("Help & Tutorial")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showOnboardingTour) {
            DiscoverHelpSheet()
        }
        .sheet(item: $selectedQuickGuide) { topic in
            FanGeoQuickGuideInfoSheet(topic: topic)
        }
    }

    private var quickTourSection: some View {
        Section {
            helpSectionCard {
                Button {
                    showOnboardingTour = true
                } label: {
                    helpRow(
                        title: "Learn FanGeo in under 30 seconds.",
                        subtitle: nil,
                        systemImage: "book.fill",
                        tint: FGColor.accentGreen
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quick Tour")
                .accessibilityHint("Reopens the FanGeo onboarding carousel.")
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            helpSectionHeader("📖 Quick Tour")
        }
    }

    private var quickGuidesSection: some View {
        Section {
            helpSectionCard {
                ForEach(Array(FanGeoQuickGuideTopic.allCases.enumerated()), id: \.element.id) { index, topic in
                    if index > 0 {
                        helpRowDivider()
                    }

                    Button {
                        selectedQuickGuide = topic
                    } label: {
                        helpRow(
                            title: topic.title,
                            subtitle: topic.summary,
                            systemImage: topic.systemImage,
                            tint: topic.tint
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            helpSectionHeader("Quick Guides")
        } footer: {
            Text("Get a fast explanation of each FanGeo feature.")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme).opacity(0.78))
                .padding(.top, 2)
        }
    }

    private var contactSupportSection: some View {
        Section {
            helpSectionCard {
                Button {
                    onContactSupport()
                } label: {
                    helpRow(
                        title: "Contact Support",
                        subtitle: "Questions, feedback, or technical issues.",
                        systemImage: "envelope.fill",
                        tint: FGColor.accentBlue
                    )
                }
                .buttonStyle(.plain)
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            helpSectionHeader("✉️ Contact Support")
        }
    }

    @ViewBuilder
    private func helpSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme).opacity(0.82))
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func helpSectionCard<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        HelpTutorialSectionCard(content: content)
    }

    @ViewBuilder
    private func helpRowDivider() -> some View {
        Divider()
            .overlay(SettingsPremiumChrome.divider(colorScheme))
            .opacity(0.42)
            .padding(.leading, 58)
            .padding(.trailing, FGSpacing.md)
    }

    @ViewBuilder
    private func helpRow(
        title: String,
        subtitle: String?,
        systemImage: String,
        tint: Color = FGColor.accentGreen,
        showsChevron: Bool = true
    ) -> some View {
        HStack(alignment: .center, spacing: FGSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(SettingsPremiumChrome.iconSurface(colorScheme))
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: SettingsPremiumChrome.rowIconSize, height: SettingsPremiumChrome.rowIconSize)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsPremiumChrome.mutedText(colorScheme))
                    .frame(width: 14, height: 14, alignment: .center)
            }
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: SettingsPremiumChrome.rowMinHeight, alignment: .center)
    }
}

private struct HelpTutorialSectionCard<Content: View>: View {
    let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .fill(SettingsPremiumChrome.cardFill(colorScheme))
                RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                SettingsPremiumChrome.cardHighlight(colorScheme),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: SettingsPremiumChrome.cardRadius, style: .continuous)
                .strokeBorder(SettingsPremiumChrome.cardStroke(colorScheme), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.20 : 0.08), radius: 14, y: 7)
    }
}

private struct FanGeoQuickGuideInfoSheet: View {
    let topic: FanGeoQuickGuideTopic
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                HStack(spacing: FGSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(topic.tint.opacity(colorScheme == .dark ? 0.22 : 0.14))
                        Image(systemName: topic.systemImage)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(topic.tint)
                    }
                    .frame(width: 48, height: 48)

                    Text(topic.title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(SettingsPremiumChrome.primaryText(colorScheme))
                }

                Text(topic.detail)
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundStyle(SettingsPremiumChrome.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(FGSpacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(FGAdaptiveSurface.sheetRoot.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(FGAdaptiveSurface.sheetRoot)
    }
}
