import SwiftUI

struct VenueEventPredictionModule: View {
    @Environment(\.colorScheme) private var colorScheme

    let venueEventID: UUID
    let teams: VenueEventPredictionTeams
    let summary: VenueEventPredictionSummary?
    var isLocked = false
    let onOpen: (VenueEventPredictionType) -> Void
    var onLockedTap: (() -> Void)? = nil

    private var resolvedSummary: VenueEventPredictionSummary {
        summary ?? .empty(eventID: venueEventID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            HStack(spacing: FGSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Before the game")
                        .font(FGTypography.caption.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(isLocked ? "Predictions closed" : "Make your pre-game picks")
                        .font(.caption2)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }

                Spacer(minLength: FGSpacing.sm)

                participantAvatars

                Text(predictionCountText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }

            VStack(spacing: 7) {
                predictionTile(
                    type: .winner,
                    icon: "trophy.fill",
                    title: "Who wins?",
                    value: winnerValue
                )
                predictionTile(
                    type: .score,
                    icon: "target",
                    title: "Score prediction",
                    value: resolvedSummary.scoreMode ?? "Add yours"
                )
                predictionTile(
                    type: .firstScoreTeam,
                    icon: "bolt.fill",
                    title: "First to score",
                    value: firstScoreValue
                )
            }
        }
        .padding(FGSpacing.sm)
        .background(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.08))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.small, style: .continuous)
                .strokeBorder(FGColor.accentBlue.opacity(0.16), lineWidth: 1)
        }
    }

    private var predictionCountText: String {
        let count = resolvedSummary.totalCount
        return count == 1 ? "1 prediction" : "\(count) predictions"
    }

    private var winnerValue: String {
        guard let leader = resolvedSummary.winnerLeader, let percent = resolvedSummary.winnerPercent else {
            return "Add yours"
        }
        return "\(leader) \(percent)%"
    }

    private var firstScoreValue: String {
        guard let leader = resolvedSummary.firstScoreLeader, let percent = resolvedSummary.firstScorePercent else {
            return "Add yours"
        }
        return "\(leader) \(percent)%"
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
            return "First team to score"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                Text("\(teams.away) vs \(teams.home)")
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
                ForEach(teams.options, id: \.self) { team in
                    Button {
                        selectedTeam = team
                    } label: {
                        HStack {
                            Text(team)
                                .font(FGTypography.body.weight(.semibold))
                            Spacer()
                            if selectedTeam == team {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(FGColor.accentBlue)
                            }
                        }
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .padding()
                        .background(selectedTeam == team ? FGColor.accentBlue.opacity(0.12) : FGColor.cardBackground(colorScheme))
                        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        case .score:
            VStack(spacing: FGSpacing.md) {
                scoreStepper(team: teams.away, score: $awayScore)
                scoreStepper(team: teams.home, score: $homeScore)
            }
        }
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
