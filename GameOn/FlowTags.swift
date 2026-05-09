import SwiftUI

struct FlowTags: View {
    let tags: [String]
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                    Text(tag)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.gray.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        }
    }
}
