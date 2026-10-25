import SwiftUI

/// Design tokens. One source of truth for spacing, radii, type, colour and motion.
public enum Theme {
    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let huge: CGFloat = 48
    }

    public enum Radius {
        public static let xs: CGFloat = 6
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 22
        public static let bubble: CGFloat = 22
        // Official ChatGPT tokens (radius-*-base in app-shared CSS).
        public static let officialSM: CGFloat = 6
        public static let officialMD: CGFloat = 8
        public static let officialLG: CGFloat = 10
        public static let officialXL: CGFloat = 12
        public static let official2XL: CGFloat = 16
        public static let official3XL: CGFloat = 20
        public static let official4XL: CGFloat = 24
        public static let composer: CGFloat = 28
    }

    public enum Layout {
        public static let sidebarMin: CGFloat = 220
        public static let sidebarIdeal: CGFloat = 252
        public static let sidebarMax: CGFloat = 320
        public static let transcriptMax: CGFloat = 768   // official --thread-content-max-width: 48rem
        public static let rowHeight: CGFloat = 36        // official --height-token-row
        public static let avatarSize: CGFloat = 28       // official --avatar-size
        public static let transcriptPadding: CGFloat = 24
        public static let messageSpacing: CGFloat = 26
    }

    public enum Motion {
        public static let quick = Animation.spring(response: 0.24, dampingFraction: 0.9)
        public static let standard = Animation.spring(response: 0.4, dampingFraction: 0.88)
        public static let gentle = Animation.spring(response: 0.62, dampingFraction: 0.92)
        public static let fade = Animation.easeOut(duration: 0.16)
    }

    public enum Typography {
        // Official --text-* scale: xs 12 / sm 14 / base 16 / lg 18 / xl 20 / 2xl 24
        public static let body = Font.system(size: 16)
        public static let message = Font.system(size: 16)
        public static let xs = Font.system(size: 12)
        public static let sm = Font.system(size: 14)
        public static let lg = Font.system(size: 18)
        public static let xl = Font.system(size: 20)
        public static let display = Font.system(size: 24, weight: .semibold)
        public static let secondary = Font.system(size: 13)
        public static let caption = Font.system(size: 11)
        public static let meta = Font.system(size: 11).monospacedDigit()
        public static let headline = Font.system(size: 15, weight: .semibold)
        public static let title = Font.system(size: 26, weight: .semibold, design: .rounded)
        public static let sectionHeader = Font.system(size: 11, weight: .semibold)
        public static let sidebarTitle = Font.system(size: 13.5, weight: .medium)
        public static let sidebarPreview = Font.system(size: 11.5)
        public static let pill = Font.system(size: 12, weight: .medium)
        public static let monospaced = Font.system(size: 13, design: .monospaced)
    }

    public enum Shadow {
        public static let composerColor = Color.black.opacity(0.07)
        public static let composerRadius: CGFloat = 18
        public static let composerY: CGFloat = 6
    }
}

// MARK: - Colour tokens

public extension Color {
    /// Main chat canvas — official --color-surface.
    static let ompCanvas = Color.ompDynamic(light: 0xFFFFFF, dark: 0x212121)
    /// Cards, composer, code blocks — official --color-surface-elevated.
    static let ompCard = Color.ompDynamic(light: 0xFFFFFF, dark: 0x000000)
    /// Subtle filled surfaces — official --color-surface-tertiary.
    static let ompFill = Color.ompDynamic(light: 0xF3F3F3, dark: 0x414141)
    /// User message bubble — official --color-background-user-message.
    static let ompUserBubble = Color.ompDynamic(light: 0xF3F3F3, dark: 0x414141)
    /// Hairlines — official --color-border.
    static let ompBorder = Color.ompDynamic(light: 0xE6E6E6, dark: 0x3F3F3F)
    /// Neutral text — official --color-text.
    static let ompText = Color.ompDynamic(light: 0x0D0D0D, dark: 0xFFFFFF)
    /// official --color-text-secondary.
    static let ompTextSecondary = Color.ompDynamic(light: 0x5D5D5D, dark: 0xCDCDCD)
    /// official --color-text-tertiary.
    static let ompTextTertiary = Color.ompDynamic(light: 0x8F8F8F, dark: 0xAFAFAF)
    /// official --color-surface-secondary (sidebar).
    static let ompSidebar = Color.ompDynamic(light: 0xE8E8E8, dark: 0x303030)
    /// official --color-background-primary-solid (primary button / send key).
    static let ompPrimarySolid = Color.ompDynamic(light: 0x0D0D0D, dark: 0xF9F9F9)
    /// official --color-text-inverse (label on primary solid).
    static let ompInverseText = Color.ompDynamic(light: 0xFFFFFF, dark: 0x0D0D0D)

    static let ompHover = Color.primary.opacity(0.06)
    static let ompSelection = Color.accentColor.opacity(0.14)

    // Backwards-compatible names used by older views.
    static let ompBackground = Color.ompCanvas
    static let ompSecondaryBackground = Color.ompFill
    static let ompTertiaryBackground = Color.ompFill
    static let ompSeparator = Color.ompBorder
    static let ompLabel = Color.ompText
    static let ompSecondaryLabel = Color.ompTextSecondary

    /// Assistant avatar gradient, used by marks and the empty state.
    static let ompMarkGradient = LinearGradient(
        colors: [Color.accentColor, Color(red: 0.55, green: 0.42, blue: 0.98)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func ompDynamic(light: UInt32, dark: UInt32) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(ompHex: isDark ? dark : light)
        })
        #else
        return Color(uiColor: UIColor { traits in
            UIColor(ompHex: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }
}

#if os(macOS)
import AppKit
private extension NSColor {
    convenience init(ompHex: UInt32) {
        self.init(
            srgbRed: CGFloat((ompHex >> 16) & 0xFF) / 255,
            green: CGFloat((ompHex >> 8) & 0xFF) / 255,
            blue: CGFloat(ompHex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#else
import UIKit
private extension UIColor {
    convenience init(ompHex: UInt32) {
        self.init(
            red: CGFloat((ompHex >> 16) & 0xFF) / 255,
            green: CGFloat((ompHex >> 8) & 0xFF) / 255,
            blue: CGFloat(ompHex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif

public extension Color {
    /// A flat sRGB color from a 0xRRGGBB value (no dark/light adaptation).
    static func ompFlat(rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255,
              green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255)
    }
}

// MARK: - Shared components

public struct OMPSurface: ViewModifier {
    var radius: CGFloat
    var fill: Color
    var border: Color

    public func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )
    }
}

public extension View {
    func ompSurface(radius: CGFloat = Theme.Radius.m, fill: Color = .ompCard, border: Color = .ompBorder) -> some View {
        modifier(OMPSurface(radius: radius, fill: fill, border: border))
    }
}

/// Assistant / app mark: gradient rounded square with a sparkle.
public struct OMPMark: View {
    var size: CGFloat
    var symbol: String

    public init(size: CGFloat = 26, symbol: String = "sparkles") {
        self.size = size
        self.symbol = symbol
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(Color.ompMarkGradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}
