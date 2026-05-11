import SwiftUI

/// Default business identity avatar used across social/chat surfaces.
struct BusinessAvatarIconView: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
            Circle()
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
            Image(systemName: "building.2.fill")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(Color.green)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
