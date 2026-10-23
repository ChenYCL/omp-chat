import SwiftUI

/// Design tokens. One source of truth for spacing, radii, type and motion.
public enum Theme {
    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    public enum Radius {
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 22
        public static let bubble: CGFloat = 18
    }

    public enum Motion {
        public static let quick = Animation.spring(response: 0.28, dampingFraction: 0.86)
        public static let standard = Animation.spring(response: 0.42, dampingFraction: 0.88)
        public static let gentle = Animation.spring(response: 0.62, dampingFraction: 0.92)
    }

    public enum Typography {
        public static let body = Font.system(.body)
        public static let secondary = Font.system(.callout)
        public static let caption = Font.system(.caption)
        public static let headline = Font.system(.headline, design: .rounded)
        public static let monospaced = Font.system(.callout, design: .monospaced)
    }
}

public extension Color {
    /// Semantic surfaces that adapt to light/dark without hard-coded hex.
    static let ompBackground = Color(uiColorCompat: .systemBackgroundCompat)
    static let ompSecondaryBackground = Color(uiColorCompat: .secondarySystemBackgroundCompat)
    static let ompTertiaryBackground = Color(uiColorCompat: .tertiarySystemBackgroundCompat)
    static let ompSeparator = Color(uiColorCompat: .separatorCompat)
    static let ompLabel = Color(uiColorCompat: .labelCompat)
    static let ompSecondaryLabel = Color(uiColorCompat: .secondaryLabelCompat)
}

#if canImport(UIKit)
import UIKit
private typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
private typealias PlatformColor = NSColor
#endif

private extension PlatformColor {
    static var systemBackgroundCompat: PlatformColor {
        #if canImport(UIKit)
        .systemBackground
        #else
        .windowBackgroundColor
        #endif
    }
    static var secondarySystemBackgroundCompat: PlatformColor {
        #if canImport(UIKit)
        .secondarySystemBackground
        #else
        .underPageBackgroundColor
        #endif
    }
    static var tertiarySystemBackgroundCompat: PlatformColor {
        #if canImport(UIKit)
        .tertiarySystemBackground
        #else
        .controlBackgroundColor
        #endif
    }
    static var separatorCompat: PlatformColor {
        #if canImport(UIKit)
        .separator
        #else
        .separatorColor
        #endif
    }
    static var labelCompat: PlatformColor {
        #if canImport(UIKit)
        .label
        #else
        .labelColor
        #endif
    }
    static var secondaryLabelCompat: PlatformColor {
        #if canImport(UIKit)
        .secondaryLabel
        #else
        .secondaryLabelColor
        #endif
    }
}

private extension Color {
    init(uiColorCompat color: PlatformColor) {
        #if canImport(UIKit)
        self.init(uiColor: color)
        #else
        self.init(nsColor: color)
        #endif
    }
}
