import SwiftUI

/// Compact trailing chip for Fan Updates: Add Friend / Requested / incoming invite / Friends.
struct CommentFriendshipChip: View {
    let kind: ChatViewModel.FriendshipChipKind
    var isSending: Bool = false
    var onAddFriend: () -> Void = {}

    var body: some View {
        Group {
            switch kind {
            case .addFriend:
                Button(action: onAddFriend) {
                    Text("Add Friend")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.10))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.blue.opacity(0.45), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(isSending)
                .opacity(isSending ? 0.55 : 1)

            case .pendingOutgoing:
                mutedCapsule("Requested")

            case .pendingIncoming:
                mutedCapsule("In Chat")

            case .friends:
                mutedCapsule("Friends")
            }
        }
    }

    private func mutedCapsule(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color(.systemGray5))
            )
    }
}
