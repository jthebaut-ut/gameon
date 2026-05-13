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
        let fg = tint ?? Color.secondary
        let fill = (tint ?? Color.secondary).opacity(0.12)
        return Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(tint == nil ? Color(.systemGray5) : fill)
            )
    }
}
