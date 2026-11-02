import SwiftUI
import UIKit

/// OMNIA's visual language: deep graphite surfaces, hairline separators, one restrained accent.
enum Theme {
    // MARK: Surfaces

    static let canvas = dynamic(light: 0xF3F3F5, dark: 0x0C0D0F)
    static let sidebar = dynamic(light: 0xEDEDF0, dark: 0x111214)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x16171A)
    static let elevated = dynamic(light: 0xF8F8FA, dark: 0x1D1E22)
    static let userBubble = dynamic(light: 0xE9EAEE, dark: 0x22242A)
    static let codeBackground = dynamic(light: 0xF2F3F6, dark: 0x111216)
    static let hairline = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.08) : UIColor.black.withAlphaComponent(0.08) })
    static let faint = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.04) : UIColor.black.withAlphaComponent(0.035) })

    // MARK: Status

    static let positive = dynamic(light: 0x2E8B57, dark: 0x7FCF9F)
    static let caution = dynamic(light: 0xB7791F, dark: 0xE8B86A)
    static let critical = dynamic(light: 0xC2412D, dark: 0xF08C76)

    // MARK: Accent

    static func accent(_ choice: AccentChoice) -> Color {
        switch choice {
        case .glacier: dynamic(light: 0x3468D6, dark: 0x92B6F7)
        case .silver: dynamic(light: 0x5B6069, dark: 0xCDD1D8)
        case .sage: dynamic(light: 0x2F8459, dark: 0x93CBAA)
        case .amber: dynamic(light: 0xB0701A, dark: 0xE8B872)
        case .iris: dynamic(light: 0x6450D2, dark: 0xAEA2F6)
        case .coral: dynamic(light: 0xC9573C, dark: 0xF2A08A)
        }
    }

    // MARK: Syntax highlighting (Xcode-like defaults)

    enum Syntax {
        static let keyword = dynamic(light: 0x9B2393, dark: 0xFC5FA3)
        static let string = dynamic(light: 0xC41A16, dark: 0xFC6A5D)
        static let comment = dynamic(light: 0x5D6C79, dark: 0x7F8C98)
        static let number = dynamic(light: 0x1C00CF, dark: 0xD0BF69)
        static let type = dynamic(light: 0x0B4F79, dark: 0x5DD8FF)
        static let function = dynamic(light: 0x326D74, dark: 0x67B7A4)
        static let plain = Color.primary
    }

    // MARK: Metrics

    static let cornerRadius: CGFloat = 16
    static let smallRadius: CGFloat = 10

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

// MARK: - Typography

extension Font {
    static let omniaLargeTitle = Font.system(size: 34, weight: .semibold, design: .default)
    static let omniaTitle = Font.system(.title2, design: .default, weight: .semibold)
    static let omniaSection = Font.system(.subheadline, design: .default, weight: .semibold)
    static let omniaCaption = Font.system(.caption, design: .default, weight: .medium)
    static let omniaMono = Font.system(.footnote, design: .monospaced)
    static let omniaNumeric = Font.system(.title3, design: .rounded, weight: .semibold).monospacedDigit()
}

// MARK: - Animation preference

struct OmniaAnimation {
    static func standard(_ preference: AnimationPreference) -> Animation? {
        switch preference {
        case .full: .smooth(duration: 0.35)
        case .reduced: .easeInOut(duration: 0.15)
        case .off: nil
        }
    }
}

extension View {
    /// Applies an animation that honours both the in-app preference and Reduce Motion.
    func omniaAnimation<V: Equatable>(_ preference: AnimationPreference, value: V) -> some View {
        modifier(PreferenceAnimation(preference: preference, value: value))
    }
}

private struct PreferenceAnimation<V: Equatable>: ViewModifier {
    let preference: AnimationPreference
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : OmniaAnimation.standard(preference), value: value)
    }
}
