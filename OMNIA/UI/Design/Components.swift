import SwiftUI

// MARK: - Surfaces

struct SurfaceModifier: ViewModifier {
    var radius: CGFloat = Theme.cornerRadius
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

extension View {
    func surface(radius: CGFloat = Theme.cornerRadius, padding: CGFloat = 16) -> some View {
        modifier(SurfaceModifier(radius: radius, padding: padding))
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var trailing: AnyView?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        trailing = nil
    }

    init<Trailing: View>(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.omniaSection)
                if let subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if let trailing { trailing }
        }
    }
}

// MARK: - Badges

struct Pill: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

struct CompatibilityBadge: View {
    let compatibility: Compatibility

    var body: some View {
        Pill(text: compatibility.title, symbol: compatibility.symbol, tint: color)
    }

    private var color: Color {
        switch compatibility {
        case .comfortable: Theme.positive
        case .fits: Theme.positive
        case .tight: Theme.caution
        case .tooLarge: Theme.critical
        }
    }
}

struct StatusDot: View {
    var color: Color
    var pulsing = false
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay(
                Circle().stroke(color.opacity(0.5), lineWidth: 6)
                    .scaleEffect(pulse ? 1.6 : 0.6)
                    .opacity(pulse ? 0 : 0.6)
                    .opacity(pulsing ? 1 : 0)
            )
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

// MARK: - Metrics

struct StatTile: View {
    let title: String
    let value: String
    var detail: String?
    var symbol: String?
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).foregroundStyle(tint).imageScale(.small)
                }
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.omniaNumeric)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(padding: 14)
    }
}

/// Horizontal stacked bar showing where memory goes (weights, KV cache, compute, overhead).
struct MemoryBreakdownBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        let label: String
        let bytes: UInt64
        let color: Color
    }

    let segments: [Segment]
    /// The ceiling the segments are measured against.
    let capacity: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                let total = max(Double(capacity), Double(segments.reduce(0) { $0 + $1.bytes }), 1)
                HStack(spacing: 2) {
                    ForEach(segments) { segment in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(segment.color)
                            .frame(width: max(2, proxy.size.width * Double(segment.bytes) / total))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.faint, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 10)

            HStack(spacing: 14) {
                ForEach(segments) { segment in
                    HStack(spacing: 5) {
                        Circle().fill(segment.color).frame(width: 6, height: 6)
                        Text("\(segment.label) \(ByteFormat.memory(segment.bytes))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

extension MemoryBreakdownBar {
    init(estimate: MemoryEstimate, capacity: UInt64, accent: Color) {
        self.init(segments: [
            Segment(label: "Weights", bytes: estimate.weights, color: accent),
            Segment(label: "KV cache", bytes: estimate.kvCache, color: accent.opacity(0.6)),
            Segment(label: "Compute", bytes: estimate.compute, color: accent.opacity(0.35)),
            Segment(label: "Runtime", bytes: estimate.overhead, color: Color.secondary.opacity(0.35))
        ], capacity: capacity)
    }
}

// MARK: - Empty states

struct OmniaEmptyState: View {
    let title: String
    let message: String
    var symbol: String = "circle.dashed"
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Notice banner

struct NoticeBanner: View {
    let notice: EngineNotice
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notice.symbol)
                .foregroundStyle(.tint)
            Text(notice.message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 560)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 16)
    }
}

// MARK: - Helpers

extension View {
    /// Reads the horizontal size class once and passes `isCompact` to the builder.
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

struct LabeledValueRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}
