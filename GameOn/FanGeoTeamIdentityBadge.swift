import SwiftUI

/// Visual treatment for FanGeo favorite-team badges (no official league marks).
enum FanGeoTeamIdentityStyle: String, Codable, Hashable {
    case standard
    case hockeyIce
    case racingStripes
    case collegiateShield

    static func forSport(_ sport: FavoriteTeamSport) -> FanGeoTeamIdentityStyle {
        switch sport {
        case .hockey: return .hockeyIce
        case .racing: return .racingStripes
        case .ncaa: return .collegiateShield
        case .soccer, .basketball, .football, .baseball, .tennis, .badminton, .golf, .combat: return .standard
        }
    }
}

/// Renders a legal-safe FanGeo identity badge (initials + generic sport styling).
struct FanGeoTeamIdentityBadge: View {
    let team: FavoriteTeam
    var diameter: CGFloat = 40

    private var style: FanGeoTeamIdentityStyle {
        team.identityStyle
    }

    var body: some View {
        Group {
            switch style {
            case .standard:
                standardCircleBadge
            case .hockeyIce:
                hockeyShieldBadge
            case .racingStripes:
                racingBadge
            case .collegiateShield:
                collegiateShieldBadge
            }
        }
        .frame(width: diameter, height: diameter)
    }

    // MARK: - Standard (soccer / NBA / NFL / MLB)

    private var standardCircleBadge: some View {
        ZStack {
            Circle()
                .fill(badgeGradient)
            Text(team.initials)
                .font(.system(size: diameter * 0.32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            Circle()
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: team.badgeColor.opacity(0.35), radius: 4, y: 2)
    }

    // MARK: - Hockey (neon ice, puck / sticks)

    private var hockeyShieldBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: diameter * 0.22, style: .continuous)
                .fill(badgeGradient)
            RoundedRectangle(cornerRadius: diameter * 0.22, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            Color.cyan.opacity(0.45),
                            Color.clear
                        ],
                        center: .top,
                        startRadius: 2,
                        endRadius: diameter * 0.7
                    )
                )
            VStack(spacing: 0) {
                Text(team.initials)
                    .font(.system(size: diameter * 0.28, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                Image(systemName: "hockey.puck.fill")
                    .font(.system(size: diameter * 0.16, weight: .semibold))
                    .foregroundStyle(Color.cyan.opacity(0.9))
                    .offset(y: -1)
            }
        }
        .frame(width: diameter, height: diameter * 1.05)
        .overlay {
            RoundedRectangle(cornerRadius: diameter * 0.22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.cyan.opacity(0.55), Color.white.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
        }
        .shadow(color: Color.cyan.opacity(0.35), radius: 6, y: 2)
    }

    // MARK: - Racing (stripes, checkered accent)

    private var racingBadge: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(Color(white: 0.12))
            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { i in
                    Rectangle()
                        .fill(i.isMultiple(of: 2) ? team.badgeColor.opacity(0.85) : Color(white: 0.18))
                        .frame(width: diameter / 5.2)
                }
            }
            .clipShape(Capsule(style: .continuous))
            .opacity(0.55)

            HStack(spacing: 4) {
                Image(systemName: "flag.checkered.2.crossed.fill")
                    .font(.system(size: diameter * 0.18, weight: .bold))
                    .foregroundStyle(team.badgeColor)
                Text(team.initials)
                    .font(.system(size: diameter * 0.26, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
            }
            .padding(.horizontal, diameter * 0.1)
        }
        .frame(width: diameter * 1.05, height: diameter * 0.68)
        .scaleEffect(0.92)
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(team.badgeColor.opacity(0.5), lineWidth: 1)
        }
        .shadow(color: team.badgeColor.opacity(0.4), radius: 5, y: 2)
    }

    // MARK: - NCAA (collegiate shield)

    private var collegiateShieldBadge: some View {
        ZStack {
            shieldShape
                .fill(badgeGradient)
            shieldShape
                .stroke(Color.white.opacity(0.28), lineWidth: 1)
            VStack(spacing: 1) {
                Image(systemName: "building.columns.fill")
                    .font(.system(size: diameter * 0.14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
                Text(team.initials)
                    .font(.system(size: diameter * 0.3, weight: .heavy, design: .serif))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
            }
            .padding(.top, diameter * 0.06)
        }
        .frame(width: diameter * 0.92, height: diameter * 1.08)
        .shadow(color: team.badgeColor.opacity(0.38), radius: 5, y: 2)
    }

    private var shieldShape: some Shape {
        FanGeoCollegiateShieldShape()
    }

    private var badgeGradient: LinearGradient {
        LinearGradient(
            colors: [
                team.badgeColor.opacity(0.95),
                team.badgeColor.opacity(0.55)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Simple collegiate shield (generic, not any school mark).
private struct FanGeoCollegiateShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        p.move(to: CGPoint(x: w * 0.5, y: 0))
        p.addLine(to: CGPoint(x: w, y: h * 0.22))
        p.addLine(to: CGPoint(x: w * 0.88, y: h))
        p.addLine(to: CGPoint(x: w * 0.12, y: h))
        p.addLine(to: CGPoint(x: 0, y: h * 0.22))
        p.closeSubpath()
        return p
    }
}

/// Backward-compatible alias used by profile card and picker.
typealias FavoriteTeamLogoBadge = FanGeoTeamIdentityBadge
