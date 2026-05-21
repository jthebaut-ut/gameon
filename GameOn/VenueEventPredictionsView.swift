import SwiftUI
import UIKit

struct VenueEventPredictionModule: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    let venueEventID: UUID
    let teams: VenueEventPredictionTeams
    var sportType: String = ""
    let summary: VenueEventPredictionSummary?
    var isLocked = false
    let onOpen: (VenueEventPredictionType) -> Void
    var onQuickVote: ((VenueEventPredictionType, String) async -> Bool)? = nil
    var onLockedTap: (() -> Void)? = nil
    @State private var selectedWinner = ""
    @State private var selectedFirstScore = ""
    @State private var savingSelectionKey: String?

    private var resolvedSummary: VenueEventPredictionSummary {
        summary ?? .empty(eventID: venueEventID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FGSpacing.md) {
            compactPredictionHeader

            winnerMatchupSection(
                title: "Who wins?",
                icon: "trophy.fill",
                type: .winner
            )

            predictionTile(
                type: .score,
                icon: "target",
                title: "Score prediction",
                value: resolvedSummary.scoreMode ?? "Tap to predict"
            )

            firstScoreMatchupSection(
                title: "Which team scores first?",
                icon: "bolt.fill",
                type: .firstScoreTeam
            )
        }
        .padding(FGSpacing.md)
        .background {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.10),
                            FGColor.accentGreen.opacity(colorScheme == .dark ? 0.10 : 0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.24 : 0.18), lineWidth: 1)
        }
        .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.06), radius: 12, y: 5)
        .task(id: venueEventID) {
            await loadUserPrediction()
        }
        .onAppear {
#if DEBUG
            print("[PredictionUIDebug] homeTeam=\(teams.home)")
            print("[PredictionUIDebug] awayTeam=\(teams.away)")
            print("[PredictionUIDebug] homeFlag=\(CountryFlagHelper.flag(for: teams.home) ?? "none")")
            print("[PredictionUIDebug] awayFlag=\(CountryFlagHelper.flag(for: teams.away) ?? "none")")
            print("[PredictionUIDebug] teamType=home:\(teamDebugType(teams.home)),away:\(teamDebugType(teams.away))")
            print("[PredictionUIDebug] countryFlagApplied=home:\(CountryFlagHelper.flag(for: teams.home) != nil),away:\(CountryFlagHelper.flag(for: teams.away) != nil)")
            print("[PredictionUILayoutDebug] sport=\(sportType)")
            print("[PredictionUILayoutDebug] percentages=\(winnerPercentagesDebugDescription)")
            print("[PredictionUILayoutDebug] firstScoreRowLayout=true")
            print("[PredictionUILayoutDebug] firstScorePercentages=\(firstScorePercentagesDebugDescription)")
            print("[PredictionHeaderLayoutDebug] compactHeaderEnabled=true")
            print("[PredictionHeaderLayoutDebug] inlineMatchupApplied=true")
#endif
        }
    }

    private var compactPredictionHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(compactHeaderTitle)
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .allowsTightening(true)

                Spacer(minLength: FGSpacing.xs)

                participantAvatars

                Text(predictionCountText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }

            Text(isLocked ? "Predictions closed" : "Make your pre-game picks")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme).opacity(0.82))
                .lineLimit(1)
        }
    }

    private var compactHeaderTitle: String {
        "\(L10n.t("before_the_game", languageCode: appLanguageRaw)) • \(teams.displayMatchup)"
    }

    private var predictionCountText: String {
        let count = resolvedSummary.totalCount
        return count == 1 ? "1 prediction" : "\(count) predictions"
    }

    private func teamDebugType(_ team: String) -> String {
        if CountryFlagHelper.isCountry(team) { return "country" }
        return FavoriteTeamCatalog.searchTeams(team).contains { candidate in
            candidate.kind == .team && candidate.name.caseInsensitiveCompare(team) == .orderedSame
        } ? "club" : "custom"
    }

    private var winnerOptions: [PredictionVotingOption] {
        let matchupOptions = [
            option(for: teams.home, type: .winner),
            option(for: teams.away, type: .winner)
        ]
        guard isSoccerPrediction else { return matchupOptions }
        return [
            matchupOptions[0],
            PredictionVotingOption(
                value: "Draw",
                title: "Draw",
                subtitle: nil,
                flag: nil,
                percent: resolvedSummary.winnerPercents["Draw"] ?? 0,
                avatars: resolvedSummary.winnerAvatarsByOption["Draw"] ?? []
            ),
            matchupOptions[1]
        ]
    }

    private var winnerMatchupOptions: (home: PredictionVotingOption, away: PredictionVotingOption) {
        (option(for: teams.home, type: .winner), option(for: teams.away, type: .winner))
    }

    private var drawOption: PredictionVotingOption {
        PredictionVotingOption(
            value: "Draw",
            title: "Draw",
            subtitle: nil,
            flag: nil,
            percent: resolvedSummary.winnerPercents["Draw"] ?? 0,
            avatars: resolvedSummary.winnerAvatarsByOption["Draw"] ?? []
        )
    }

    private var isSoccerPrediction: Bool {
        let normalized = sportType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("soccer") || normalized.contains("football") && normalized.contains("association")
    }

    private var winnerPercentagesDebugDescription: String {
        "home=\(winnerMatchupOptions.home.percent),away=\(winnerMatchupOptions.away.percent),draw=\(drawOption.percent)"
    }

    private var firstScoreMatchupOptions: (home: PredictionVotingOption, away: PredictionVotingOption) {
        (option(for: teams.home, type: .firstScoreTeam), option(for: teams.away, type: .firstScoreTeam))
    }

    private var firstScorePercentagesDebugDescription: String {
        "home=\(firstScoreMatchupOptions.home.percent),away=\(firstScoreMatchupOptions.away.percent)"
    }

    private func option(for team: String, type: VenueEventPredictionType) -> PredictionVotingOption {
        let displayName = CountryFlagHelper.displayName(for: team, languageCode: appLanguageRaw)
        let percent: Int
        let avatars: [VenuePredictionParticipantAvatar]
        switch type {
        case .winner:
            percent = resolvedSummary.winnerPercents[team] ?? 0
            avatars = resolvedSummary.winnerAvatarsByOption[team] ?? []
        case .firstScoreTeam:
            percent = resolvedSummary.firstScorePercents[team] ?? 0
            avatars = resolvedSummary.firstScoreAvatarsByOption[team] ?? []
        case .score:
            percent = 0
            avatars = []
        }
        return PredictionVotingOption(
            value: team,
            title: displayName,
            subtitle: nil,
            flag: CountryFlagHelper.flag(for: team),
            percent: percent,
            avatars: avatars
        )
    }

    private func predictionVotingSection(
        title: String,
        icon: String,
        options: [PredictionVotingOption],
        type: VenueEventPredictionType
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.heavy))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            VStack(spacing: 8) {
                ForEach(options) { option in
                    PredictionOptionVotingCard(
                        option: option,
                        isSelected: selectedValue(for: type) == option.value,
                        isSaving: savingSelectionKey == selectionKey(type: type, value: option.value),
                        colorScheme: colorScheme
                    ) {
                        vote(type: type, value: option.value)
                    }
                }
            }
        }
    }

    private func winnerMatchupSection(
        title: String,
        icon: String,
        type: VenueEventPredictionType
    ) -> some View {
        let options = winnerMatchupOptions
        return VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.heavy))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            HStack(alignment: .center, spacing: 8) {
                PredictionMatchupTeamCard(
                    option: options.home,
                    isSelected: selectedValue(for: type) == options.home.value,
                    isSaving: savingSelectionKey == selectionKey(type: type, value: options.home.value),
                    colorScheme: colorScheme
                ) {
                    vote(type: type, value: options.home.value)
                }

                Text("VS")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.horizontal, 2)

                PredictionMatchupTeamCard(
                    option: options.away,
                    isSelected: selectedValue(for: type) == options.away.value,
                    isSaving: savingSelectionKey == selectionKey(type: type, value: options.away.value),
                    colorScheme: colorScheme
                ) {
                    vote(type: type, value: options.away.value)
                }
            }

            if isSoccerPrediction {
                PredictionDrawChip(
                    option: drawOption,
                    isSelected: selectedValue(for: type) == drawOption.value,
                    isSaving: savingSelectionKey == selectionKey(type: type, value: drawOption.value),
                    colorScheme: colorScheme
                ) {
                    vote(type: type, value: drawOption.value)
                }
            }
        }
    }

    private func firstScoreMatchupSection(
        title: String,
        icon: String,
        type: VenueEventPredictionType
    ) -> some View {
        let options = firstScoreMatchupOptions
        return VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.heavy))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            HStack(alignment: .center, spacing: 8) {
                PredictionMatchupTeamCard(
                    option: options.home,
                    isSelected: selectedValue(for: type) == options.home.value,
                    isSaving: savingSelectionKey == selectionKey(type: type, value: options.home.value),
                    colorScheme: colorScheme
                ) {
                    vote(type: type, value: options.home.value)
                }

                Text("VS")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.horizontal, 2)

                PredictionMatchupTeamCard(
                    option: options.away,
                    isSelected: selectedValue(for: type) == options.away.value,
                    isSaving: savingSelectionKey == selectionKey(type: type, value: options.away.value),
                    colorScheme: colorScheme
                ) {
                    vote(type: type, value: options.away.value)
                }
            }
        }
    }

    private func selectedValue(for type: VenueEventPredictionType) -> String {
        switch type {
        case .winner:
            return selectedWinner
        case .firstScoreTeam:
            return selectedFirstScore
        case .score:
            return ""
        }
    }

    private func vote(type: VenueEventPredictionType, value: String) {
        guard !isLocked else {
            onLockedTap?()
            return
        }
        guard let onQuickVote else {
            onOpen(type)
            return
        }

        let previousWinner = selectedWinner
        let previousFirstScore = selectedFirstScore
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
            if type == .winner {
                selectedWinner = value
            } else if type == .firstScoreTeam {
                selectedFirstScore = value
            }
            savingSelectionKey = selectionKey(type: type, value: value)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
#if DEBUG
        if type == .winner {
            print("[PredictionUIDebug] selectedWinner=\(value)")
        } else if type == .firstScoreTeam {
            print("[PredictionUIDebug] selectedFirstScore=\(value)")
            print("[PredictionUILayoutDebug] selectedFirstScore=\(value)")
            print("[PredictionUILayoutDebug] firstScorePercentages=\(firstScorePercentagesDebugDescription)")
        }
        print("[PredictionUILayoutDebug] selectedOption=\(value)")
        print("[PredictionUILayoutDebug] percentages=\(winnerPercentagesDebugDescription)")
#endif

        Task {
            let didSave = await onQuickVote(type, value)
            await MainActor.run {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    savingSelectionKey = nil
                    if !didSave {
                        selectedWinner = previousWinner
                        selectedFirstScore = previousFirstScore
                    }
                }
            }
        }
    }

    private func selectionKey(type: VenueEventPredictionType, value: String) -> String {
        "\(type.rawValue)|\(value)"
    }

    @MainActor
    private func loadUserPrediction() async {
        do {
            let prediction = try await VenueEventPredictionService.shared.fetchUserPrediction(venueEventId: venueEventID)
            selectedWinner = prediction.winner ?? ""
            selectedFirstScore = prediction.firstScoreTeam ?? ""
#if DEBUG
            if !selectedWinner.isEmpty {
                print("[PredictionUIDebug] selectedWinner=\(selectedWinner)")
            }
            if !selectedFirstScore.isEmpty {
                print("[PredictionUIDebug] selectedFirstScore=\(selectedFirstScore)")
                print("[PredictionUILayoutDebug] selectedFirstScore=\(selectedFirstScore)")
            }
#endif
        } catch {
#if DEBUG
            print("[PredictionUIDebug] userPredictionLoadSkipped=\(error.localizedDescription)")
#endif
        }
    }

    private var participantAvatars: some View {
        HStack(spacing: -7) {
            ForEach(resolvedSummary.participantAvatars.prefix(3)) { avatar in
                VenuePredictionAvatarView(avatar: avatar)
            }
        }
        .frame(minWidth: resolvedSummary.participantAvatars.isEmpty ? 0 : 38, alignment: .trailing)
    }

    private func predictionTile(
        type: VenueEventPredictionType,
        icon: String,
        title: String,
        value: String
    ) -> some View {
        Button {
#if DEBUG
            print("[VenuePredictionDebug] openSheet type=\(type.rawValue)")
#endif
            guard !isLocked else {
                onLockedTap?()
                return
            }
            onOpen(type)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.accentBlue)
                    .frame(width: 16)

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                Spacer(minLength: FGSpacing.sm)

                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.62 : 0.86))
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(isLocked ? "Predictions closed for this game." : "")
    }
}

struct VenueEventPredictionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    let venueEventID: UUID
    let teams: VenueEventPredictionTeams
    let predictionType: VenueEventPredictionType
    let onSaved: () async -> Void

    @State private var userPrediction = VenueEventUserPredictions()
    @State private var selectedTeam = ""
    @State private var awayScore = 0
    @State private var homeScore = 0
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var title: String {
        switch predictionType {
        case .winner:
            return "Who wins?"
        case .score:
            return "Score prediction"
        case .firstScoreTeam:
            return "Which team scores first?"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                Text(teams.displayMatchup)
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    predictionEditor
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.dangerRed)
                }

                Spacer(minLength: 0)

                if predictionType == .score {
                    HStack(spacing: FGSpacing.sm) {
                        FGSecondaryButton(title: "Remove", systemImage: "trash") {
                            Task { await deletePrediction() }
                        }
                        .disabled(isSaving)

                        FGPrimaryButton(title: isSaving ? "Saving..." : "Save", systemImage: "checkmark") {
                            Task { await savePrediction() }
                        }
                        .disabled(isSaving || isLoading)
                    }
                } else {
                    FGSecondaryButton(title: "Remove", systemImage: "trash") {
                        Task { await deletePrediction() }
                    }
                    .disabled(isSaving || isLoading)
                }
            }
            .padding(22)
            .fanGeoScreenBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await loadUserPrediction()
            }
        }
    }

    @ViewBuilder
    private var predictionEditor: some View {
        switch predictionType {
        case .winner, .firstScoreTeam:
            VStack(spacing: FGSpacing.sm) {
                ForEach(sheetVotingOptions) { option in
                    PredictionOptionVotingCard(
                        option: option,
                        isSelected: selectedTeam == option.value,
                        isSaving: isSaving && selectedTeam == option.value,
                        colorScheme: colorScheme
                    ) {
                        selectedTeam = option.value
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
#if DEBUG
                        if predictionType == .winner {
                            print("[PredictionUIDebug] selectedWinner=\(option.value)")
                        } else {
                            print("[PredictionUIDebug] selectedFirstScore=\(option.value)")
                        }
#endif
                        Task { await savePrediction() }
                    }
                }
            }
        case .score:
            VStack(spacing: FGSpacing.md) {
                scoreStepper(team: teams.home, score: $homeScore)
                scoreStepper(team: teams.away, score: $awayScore)
            }
        }
    }

    private var sheetVotingOptions: [PredictionVotingOption] {
        let teamOptions = teams.options.map { team in
            let displayName = CountryFlagHelper.displayName(for: team, languageCode: appLanguageRaw)
            return PredictionVotingOption(
                value: team,
                title: displayName,
                subtitle: nil,
                flag: CountryFlagHelper.flag(for: team),
                percent: 0,
                avatars: []
            )
        }
        guard predictionType == .winner else { return teamOptions }
        return [
            teamOptions[0],
            PredictionVotingOption(value: "Draw", title: "Draw", subtitle: nil, flag: nil, percent: 0, avatars: []),
            teamOptions[1]
        ]
    }

    private func scoreStepper(team: String, score: Binding<Int>) -> some View {
        HStack {
            Text(team)
                .font(FGTypography.body.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(1)
            Spacer()
            Stepper(value: score, in: 0...99) {
                Text("\(score.wrappedValue)")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(FGColor.accentBlue)
                    .frame(width: 36, alignment: .trailing)
            }
            .labelsHidden()
        }
        .padding()
        .background(FGColor.cardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
    }

    @MainActor
    private func loadUserPrediction() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let prediction = try await VenueEventPredictionService.shared.fetchUserPrediction(venueEventId: venueEventID)
            userPrediction = prediction
            switch predictionType {
            case .winner:
                selectedTeam = prediction.winner ?? ""
            case .score:
                homeScore = prediction.homeScore ?? 0
                awayScore = prediction.awayScore ?? 0
            case .firstScoreTeam:
                selectedTeam = prediction.firstScoreTeam ?? ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func savePrediction() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            switch predictionType {
            case .winner:
                try await VenueEventPredictionService.shared.upsertPrediction(
                    venueEventId: venueEventID,
                    predictionType: .winner,
                    predictedWinner: selectedTeam
                )
            case .score:
                try await VenueEventPredictionService.shared.upsertPrediction(
                    venueEventId: venueEventID,
                    predictionType: .score,
                    predictedHomeScore: homeScore,
                    predictedAwayScore: awayScore
                )
            case .firstScoreTeam:
                try await VenueEventPredictionService.shared.upsertPrediction(
                    venueEventId: venueEventID,
                    predictionType: .firstScoreTeam,
                    predictedFirstScoreTeam: selectedTeam
                )
            }
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deletePrediction() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await VenueEventPredictionService.shared.deletePrediction(
                venueEventId: venueEventID,
                predictionType: predictionType
            )
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PredictionVotingOption: Identifiable, Equatable {
    let value: String
    let title: String
    let subtitle: String?
    let flag: String?
    let percent: Int
    let avatars: [VenuePredictionParticipantAvatar]

    var id: String { value }
}

private struct PredictionMatchupTeamCard: View {
    let option: PredictionVotingOption
    let isSelected: Bool
    let isSaving: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                if let flag = option.flag {
                    Text(flag)
                        .font(.system(size: 30))
                        .frame(height: 32)
                }

                Text(option.title)
                    .font(.system(size: 14.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .frame(maxWidth: .infinity)

                Text("\(option.percent)%")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(isSelected ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
                    .monospacedDigit()

                if isSaving {
                    ProgressView()
                        .controlSize(.mini)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(FGColor.accentGreen)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: option.flag == nil ? 106 : 124)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        isSelected ? FGColor.accentGreen.opacity(0.76) : FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.13),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .shadow(
                color: (isSelected ? FGColor.accentGreen : FGColor.accentBlue).opacity(colorScheme == .dark ? 0.16 : 0.08),
                radius: isSelected ? 16 : 8,
                y: isSelected ? 7 : 3
            )
            .scaleEffect(isSelected ? 1.025 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.76), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var cardBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.09 : 0.94),
                (isSelected ? FGColor.accentGreen : FGColor.accentBlue).opacity(colorScheme == .dark ? 0.18 : 0.09)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct PredictionDrawChip: View {
    let option: PredictionVotingOption
    let isSelected: Bool
    let isSaving: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(option.title)
                    .font(.caption.weight(.heavy))
                Text("\(option.percent)%")
                    .font(.caption.weight(.black))
                    .monospacedDigit()
                if isSaving {
                    ProgressView()
                        .controlSize(.mini)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption.weight(.bold))
                }
            }
            .foregroundStyle(isSelected ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background((isSelected ? FGColor.accentGreen : FGColor.accentBlue).opacity(colorScheme == .dark ? 0.14 : 0.08))
            .clipShape(Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder((isSelected ? FGColor.accentGreen : FGColor.accentBlue).opacity(0.28), lineWidth: 1)
            }
            .scaleEffect(isSelected ? 1.012 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PredictionOptionVotingCard: View {
    let option: PredictionVotingOption
    let isSelected: Bool
    let isSaving: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                if let flag = option.flag {
                    Text(flag)
                        .font(.system(size: 26))
                        .frame(width: 34)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(option.title)
                        .font(.system(size: 15.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)

                    if let subtitle = option.subtitle {
                        Text(subtitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }

                    if !option.avatars.isEmpty {
                        HStack(spacing: -7) {
                            ForEach(option.avatars.prefix(3)) { avatar in
                                VenuePredictionAvatarView(avatar: avatar)
                            }
                        }
                        .padding(.top, 1)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 5) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.mini)
                    } else if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(FGColor.accentGreen)
                    }

                    Text("\(option.percent)%")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundStyle(isSelected ? FGColor.accentGreen : FGColor.primaryText(colorScheme))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isSelected ? FGColor.accentGreen.opacity(0.72) : FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.12),
                        lineWidth: isSelected ? 1.4 : 1
                    )
            }
            .shadow(
                color: (isSelected ? FGColor.accentGreen : FGColor.accentBlue).opacity(colorScheme == .dark ? 0.16 : 0.08),
                radius: isSelected ? 14 : 8,
                y: isSelected ? 6 : 3
            )
            .scaleEffect(isSelected ? 1.015 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var cardBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.08 : 0.92),
                (isSelected ? FGColor.accentGreen : FGColor.accentBlue).opacity(colorScheme == .dark ? 0.16 : 0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct VenuePredictionAvatarView: View {
    @Environment(\.colorScheme) private var colorScheme

    let avatar: VenuePredictionParticipantAvatar

    private var imageURL: URL? {
        let raw = avatar.avatarThumbnailURL ?? avatar.avatarURL
        return raw.flatMap(URL.init(string:))
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(FGColor.cardBackground(colorScheme))
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(Circle())
        .overlay(Circle().stroke(FGColor.cardBackground(colorScheme), lineWidth: 2))
    }

    private var fallback: some View {
        Text(String(avatar.displayName.prefix(1)).uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(FGColor.primaryText(colorScheme))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FGColor.accentBlue.opacity(0.18))
    }
}
