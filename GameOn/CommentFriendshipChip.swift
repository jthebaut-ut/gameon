import SwiftUI

/// Compact trailing chip for Fan Updates: Add Friend / Requested / incoming invite / Friends.
struct CommentFriendshipChip: View {
    let kind: ChatViewModel.FriendshipChipKind
    var isSending: Bool = false
    var onAddFriend: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    private var fanUpdatesIsDark: Bool { colorScheme == .dark }

    private var chipStroke: Color {
        fanUpdatesIsDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    private var addFriendForeground: Color {
        fanUpdatesIsDark ? Color(red: 0.45, green: 0.75, blue: 1.0) : Color.blue
    }

    var body: some View {
        Group {
            switch kind {
            case .addFriend:
                Button(action: onAddFriend) {
                    Text("Add Friend")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(addFriendForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(fanUpdatesIsDark ? Color.white.opacity(0.08) : Color.blue.opacity(0.10))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            fanUpdatesIsDark ? Color.white.opacity(0.10) : Color.blue.opacity(0.45),
                                            lineWidth: 1
                                        )
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(isSending)
                .opacity(isSending ? 0.55 : 1)

            case .pendingOutgoing:
                mutedCapsule("Requested", tint: nil)

            case .pendingIncoming:
                mutedCapsule("In Chat", tint: nil)

            case .friends:
                mutedCapsule("Friends", tint: nil)

            case .declinedOutgoing:
                mutedCapsule("Declined", tint: Color.orange)
            }
        }
    }

    private func mutedCapsule(_ text: String, tint: Color?) -> some View {
        let fg: Color = {
            if let tint {
                return tint
            }
            return fanUpdatesIsDark ? Color.white.opacity(0.85) : Color.secondary
        }()

        let fill: Color = {
            if fanUpdatesIsDark {
                return Color.white.opacity(0.08)
            }
            if tint == nil {
                return Color(uiColor: .systemGray5)
            }
            return tint!.opacity(0.12)
        }()

        return Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(fill)
                    .overlay(
                        Capsule()
                            .strokeBorder(fanUpdatesIsDark ? chipStroke : Color.clear, lineWidth: 1)
                    )
            )
    }
}
