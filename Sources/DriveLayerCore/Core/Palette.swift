import Foundation

/// One colour, as plain sRGB components.
///
/// The palette lives in the core rather than in the SwiftUI layer for one reason:
/// contrast is a correctness property, and a correctness property belongs somewhere
/// a test can reach it. `DLColor` is a thin adapter over these numbers.
struct RGB: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// WCAG 2.1 relative luminance.
    var relativeLuminance: Double {
        func linear(_ component: Double) -> Double {
            component <= 0.040_45 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2.1 contrast ratio, between 1 (identical) and 21 (black on white).
    func contrastRatio(against other: RGB) -> Double {
        let mine = relativeLuminance
        let theirs = other.relativeLuminance
        return (max(mine, theirs) + 0.05) / (min(mine, theirs) + 0.05)
    }
}

/// The colour values behind the design system.
///
/// Every foreground here is checked against every surface it can appear on, in both
/// appearances, by `PaletteTests`. That test is the reason the light-mode status
/// colours are darker than they look like they should be: the obvious green, amber
/// and orange all failed at 4.5:1 on a near-white background.
///
/// Colour is never the only signal in DriveLayer — `SemanticStatus` carries a
/// distinct symbol too — but "not the only signal" is not a licence for a status a
/// driver has to squint at in daylight.
enum Palette {

    enum Appearance: CaseIterable, Sendable {
        case light, dark
    }

    /// The minimum contrast DriveLayer holds itself to: WCAG AA for normal text.
    /// Applied to large text as well, because a large number in an unreadable colour
    /// is still unreadable.
    static let minimumContrastRatio: Double = 4.5

    // MARK: - Surfaces

    /// Dark mode is the primary case: this is an app used in a car at night.
    static func background(_ appearance: Appearance) -> RGB {
        switch appearance {
        case .light: return RGB(0.96, 0.96, 0.97)
        case .dark: return RGB(0.05, 0.05, 0.06)
        }
    }

    static func surface(_ appearance: Appearance) -> RGB {
        switch appearance {
        case .light: return RGB(1, 1, 1)
        case .dark: return RGB(0.10, 0.10, 0.12)
        }
    }

    static func surfaceRaised(_ appearance: Appearance) -> RGB {
        switch appearance {
        case .light: return RGB(1, 1, 1)
        case .dark: return RGB(0.14, 0.14, 0.16)
        }
    }

    /// Every surface a foreground colour can land on.
    static func surfaces(_ appearance: Appearance) -> [RGB] {
        [background(appearance), surface(appearance), surfaceRaised(appearance)]
    }

    // MARK: - Foregrounds

    static func primaryText(_ appearance: Appearance) -> RGB {
        switch appearance {
        case .light: return RGB(0.08, 0.08, 0.09)
        case .dark: return RGB(0.96, 0.96, 0.97)
        }
    }

    static func secondaryText(_ appearance: Appearance) -> RGB {
        switch appearance {
        case .light: return RGB(0.36, 0.36, 0.40)
        case .dark: return RGB(0.66, 0.66, 0.70)
        }
    }

    /// The single accent, used for interactive elements only.
    static func accent(_ appearance: Appearance) -> RGB {
        switch appearance {
        case .light: return RGB(0.11, 0.42, 0.85)
        case .dark: return RGB(0.36, 0.64, 1.0)
        }
    }

    static func status(_ status: SemanticStatus, _ appearance: Appearance) -> RGB {
        switch (status, appearance) {
        // The light values are deliberately deeper than a conventional traffic-light
        // palette. A 0.72-red amber reads well on a poster and fails at 3.1:1 here.
        // The green is deeper still, so it does not collapse onto the critical red
        // in greyscale — the two states that mean opposite things.
        case (.normal, .light): return RGB(0.08, 0.35, 0.21)
        case (.watch, .light): return RGB(0.57, 0.40, 0.04)
        case (.attention, .light): return RGB(0.68, 0.34, 0.07)
        case (.critical, .light): return RGB(0.76, 0.16, 0.16)
        case (.unknown, .light): return RGB(0.43, 0.43, 0.48)

        case (.normal, .dark): return RGB(0.36, 0.80, 0.52)
        case (.watch, .dark): return RGB(0.95, 0.75, 0.28)
        case (.attention, .dark): return RGB(1.0, 0.62, 0.28)
        case (.critical, .dark): return RGB(1.0, 0.44, 0.42)
        case (.unknown, .dark): return RGB(0.55, 0.55, 0.60)
        }
    }

    /// Every colour drawn as text or as a meaningful mark, with a name for a test
    /// failure to point at.
    static func foregrounds(_ appearance: Appearance) -> [(name: String, colour: RGB)] {
        var colours: [(String, RGB)] = [
            ("primaryText", primaryText(appearance)),
            ("secondaryText", secondaryText(appearance)),
            ("accent", accent(appearance))
        ]
        for state in SemanticStatus.allCases {
            colours.append(("status.\(state.rawValue)", status(state, appearance)))
        }
        return colours
    }
}
