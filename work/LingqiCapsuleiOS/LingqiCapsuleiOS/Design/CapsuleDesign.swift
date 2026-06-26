import SwiftUI

enum CapsuleDesign {
    static let background = LinearGradient(
        colors: [
            Color(red: 0.035, green: 0.065, blue: 0.115),
            Color(red: 0.075, green: 0.105, blue: 0.175)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let accent = Color(red: 0.54, green: 0.70, blue: 1.0)
    static let mint = Color(red: 0.65, green: 0.95, blue: 0.82)
    static let text = Color.white.opacity(0.96)
    static let secondaryText = Color.white.opacity(0.62)
    static let card = Color.white.opacity(0.075)
    static let strongCard = Color.white.opacity(0.11)
    static let line = Color.white.opacity(0.14)
}

struct CapsuleBackground: View {
    var body: some View {
        ZStack {
            CapsuleDesign.background
            RadialGradient(
                colors: [CapsuleDesign.accent.opacity(0.18), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(CapsuleDesign.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(CapsuleDesign.line, lineWidth: 1)
            )
    }
}

struct KeywordPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(CapsuleDesign.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(CapsuleDesign.strongCard, in: Capsule())
            .overlay(Capsule().stroke(CapsuleDesign.line, lineWidth: 1))
    }
}
