import Foundation

/// Gamma-encoded sRGB, each channel 0…1. AppKit colours convert into this
/// before the disruption dot picks its ink — the choice itself has no AppKit.
public struct SRGBColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
    }

    public static let black = SRGBColor(red: 0, green: 0, blue: 0)
    public static let white = SRGBColor(red: 1, green: 1, blue: 1)

    static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// Ink for the disruption dot on a pill slot. Black or white, whichever
/// contrasts more with the fill. The slot's colour already means "how full";
/// a provider outage must not repaint it, only sit on it as ink.
///
/// Any opaque sRGB fill has at least ~4.58:1 against the better of black and
/// white (the floor at relative luminance 0.179). WCAG 1.4.11 asks 3:1 for
/// graphics, so a ring is never required on these slots. Yellow looks hopeless
/// only when the ink is white — Dark Mode `labelColor` on `systemYellow`.
public enum DisruptionInk: String, Sendable, Equatable {
    case black
    case white

    public var color: SRGBColor {
        switch self {
        case .black: .black
        case .white: .white
        }
    }

    /// WCAG 2 relative luminance of a gamma-encoded sRGB colour.
    public static func relativeLuminance(of color: SRGBColor) -> Double {
        0.2126 * linearize(color.red)
            + 0.7152 * linearize(color.green)
            + 0.0722 * linearize(color.blue)
    }

    /// Contrast ratio of two relative luminances. Order does not matter.
    public static func contrastRatio(_ a: Double, _ b: Double) -> Double {
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    public static func contrastRatio(between a: SRGBColor, and b: SRGBColor) -> Double {
        contrastRatio(relativeLuminance(of: a), relativeLuminance(of: b))
    }

    /// Black when that contrast is at least as high as white's; white otherwise.
    /// The equal case (luminance ≈ 0.179) lands on black.
    public static func on(fill: SRGBColor) -> DisruptionInk {
        let luminance = relativeLuminance(of: fill)
        let black = contrastRatio(luminance, 0)
        let white = contrastRatio(luminance, 1)
        return black >= white ? .black : .white
    }

    /// Contrast of `on(fill:)` against `fill`.
    public static func contrast(on fill: SRGBColor) -> Double {
        contrastRatio(between: on(fill: fill).color, and: fill)
    }

    /// WCAG 2.1 / 2.2 sRGB linearization.
    static func linearize(_ channel: Double) -> Double {
        let c = SRGBColor.clamp(channel)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}
