import SwiftUI

/// The OMNIA mark: three frosted glass discs whose overlap forms one luminous center.
/// Every model, one mind. Proportions match the app icon (scripts/make-icon.py).
struct OmniaMark: View {
    var size: CGFloat = 40
    var animated = false
    var tint: Color = .accentColor

    /// In icon units: disc radius 0.215 and center offset 0.115; the group spans ~0.64.
    private static let groupSpan: CGFloat = 0.64
    private static let discRadius: CGFloat = 0.215
    private static let discOffset: CGFloat = 0.115
    private static let angles: [Double] = [90, 210, 330]

    @State private var converged = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let unit = size / Self.groupSpan
        let radius = Self.discRadius * unit
        let offset = Self.discOffset * unit * (converged ? 0.9 : 1)
        let dark = colorScheme == .dark
        ZStack {
            ForEach(Self.angles.indices, id: \.self) { index in
                let angle = Self.angles[index] * .pi / 180
                let color = discColor(index, dark: dark)
                Circle()
                    .fill(LinearGradient(colors: [color.opacity(dark ? 0.36 : 0.26), color.opacity(dark ? 0.12 : 0.08)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(
                        Circle().strokeBorder(
                            LinearGradient(colors: dark
                                           ? [Color.white.opacity(0.75), Color.white.opacity(0.08)]
                                           : [Color.black.opacity(0.28), Color.black.opacity(0.06)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: max(0.75, size * 0.014))
                    )
                    .frame(width: radius * 2, height: radius * 2)
                    .offset(x: offset * cos(angle), y: -offset * sin(angle))
                    .blendMode(dark ? .plusLighter : .multiply)
            }
        }
        .compositingGroup()
        .offset(y: 0.029 * unit)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear {
            guard animated, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { converged = true }
        }
    }

    private func discColor(_ index: Int, dark: Bool) -> Color {
        switch index {
        case 1: dark ? Color(white: 0.82) : Color(white: 0.42)
        default: tint
        }
    }
}

/// "OMNIA" set in wide, light capitals.
struct OmniaWordmark: View {
    var size: CGFloat = 22

    var body: some View {
        Text("OMNIA")
            .font(.system(size: size, weight: .light, design: .default))
            .tracking(size * 0.32)
            .foregroundStyle(.primary)
            .accessibilityLabel("OMNIA")
    }
}

#Preview {
    VStack(spacing: 24) {
        OmniaMark(size: 120, animated: true)
        OmniaWordmark(size: 32)
    }
    .padding(40)
    .preferredColorScheme(.dark)
}
