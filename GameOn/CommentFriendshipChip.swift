import SwiftUI

/// Minimal pill for Add Friend / Pending / Friends on comment rows.
struct CommentFriendshipChip: View {
    let kind: ChatViewModel.FriendshipChipKind
    var isSending: Bool = false
    var onAddFriend: () -> Void = {}

    var body: some View {
        Group {
            switch kind {
            case .addFriend:
                Button(action: onAddFriend) {
                    label("Add Friend", style: .action)
                }
                .buttonStyle(.plain)
                .disabled(isSending)

            case .pending:
                label("Pending", style: .muted)

            case .friends:
                label("Friends", style: .muted)
            }
        }
    }

    private enum LabelStyle { case action, muted }

    private func label(_ text: String, style: LabelStyle) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(style == .action ? Color.black.opacity(0.88) : Color(.systemGray5))
            )
            .foregroundStyle(style == .action ? Color.white : Color.secondary)
            .opacity(isSending && style == .action ? 0.55 : 1)
    }
}
