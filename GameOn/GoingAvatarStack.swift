import SwiftUI

/// Overlapping avatars for “who’s going” rows (Discover / venue preview).
struct GoingAvatarStack: View {
    let profiles: [UserProfileRow]

    private let maxVisible = 4
    private let diameter: CGFloat = 32

    var body: some View {
        let trimmed = Array(profiles.prefix(maxVisible))
        HStack(spacing: -diameter * 0.35) {
            ForEach(Array(trimmed.enumerated()), id: \.offset) { _, row in
                avatar(for: row)
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
            }
        }
    }

    @ViewBuilder
    private func avatar(for row: UserProfileRow) -> some View {
        if let raw = row.avatar_url?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = URL(string: raw) {
            DiscoverCachedRemoteImage(url: url, contentMode: .fill) {
                placeholder(initial: row.display_name ?? row.email)
            }
        } else {
            placeholder(initial: row.display_name ?? row.email)
        }
    }

    private func placeholder(initial: String?) -> some View {
        let letter = initial?.first.map { String($0).uppercased() } ?? "?"
        return ZStack {
            Color(.systemGray4)
            Text(letter)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
    }
}
