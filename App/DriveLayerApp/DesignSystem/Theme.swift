import SwiftUI

/// The design system's constants.
///
/// The visual direction is a calm instrument panel, not a dashboard template:
/// large meaningful type, generous space, few surfaces, and colour used sparingly
/// so that when something *is* coloured it means something.
enum DL {

    enum Spacing {
        static let hairline: CGFloat = 2
        static let tight: CGFloat = 6
        static let small: CGFloat = 10
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let section: CGFloat = 32
        static let screen: CGFloat = 20
    }

    enum Radius {
        static let small: CGFloat = 10
        static let card: CGFloat = 18
        static let large: CGFloat = 26
        static let pill: CGFloat = 999
    }

    /// Type scale. Numbers that matter are large and rounded; supporting text is
    /// small, quiet, and uppercase only for labels.
    enum Font {
        /// The one number a screen is about.
        static var hero: SwiftUI.Font { .system(size: 56, weight: .medium, design: .rounded) }
        static var display: SwiftUI.Font { .system(size: 34, weight: .medium, design: .rounded) }
        static var metric: SwiftUI.Font { .system(size: 24, weight: .medium, design: .rounded) }
        static var title: SwiftUI.Font { .system(.title3, design: .default).weight(.semibold) }
        static var body: SwiftUI.Font { .system(.body) }
        static var callout: SwiftUI.Font { .system(.callout) }
        static var caption: SwiftUI.Font { .system(.caption) }
        /// Small uppercase label with tracking, used for section headers.
        static var label: SwiftUI.Font { .system(.caption, design: .default).weight(.semibold) }
    }

    enum Opacity {
        static let secondary: Double = 0.62
        static let tertiary: Double = 0.38
        static let separator: Double = 0.12
        static let fill: Double = 0.07
    }

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.18)
        static let standard = Animation.easeInOut(duration: 0.28)
        /// Used for values that update continuously while driving, so they settle
        /// rather than snap.
        static let value = Animation.easeOut(duration: 0.45)
    }
}

/// Semantic colours.
///
/// Defined in code rather than an asset catalog so the palette is reviewable in one
/// place and stays in step with `SemanticStatus`. Every status colour is paired with
/// a distinct symbol elsewhere in the system — colour is never the only signal.
enum DLColor {

    static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let components = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: components.0, green: components.1, blue: components.2, alpha: 1)
        })
    }

    // Surfaces. Dark mode is the primary case: this is an app used in a car at night.
    static let background = dynamic(light: (0.96, 0.96, 0.97), dark: (0.05, 0.05, 0.06))
    static let surface = dynamic(light: (1, 1, 1), dark: (0.10, 0.10, 0.12))
    static let surfaceRaised = dynamic(light: (1, 1, 1), dark: (0.14, 0.14, 0.16))

    static let primaryText = dynamic(light: (0.08, 0.08, 0.09), dark: (0.96, 0.96, 0.97))
    static let secondaryText = dynamic(light: (0.36, 0.36, 0.40), dark: (0.66, 0.66, 0.70))

    /// The single accent, used for interactive elements only.
    static let accent = dynamic(light: (0.11, 0.42, 0.85), dark: (0.36, 0.64, 1.0))

    static let normal = dynamic(light: (0.12, 0.55, 0.33), dark: (0.36, 0.80, 0.52))
    static let watch = dynamic(light: (0.72, 0.51, 0.05), dark: (0.95, 0.75, 0.28))
    static let attention = dynamic(light: (0.83, 0.42, 0.09), dark: (1.0, 0.62, 0.28))
    static let critical = dynamic(light: (0.76, 0.16, 0.16), dark: (1.0, 0.44, 0.42))
    static let unknown = dynamic(light: (0.45, 0.45, 0.50), dark: (0.55, 0.55, 0.60))

    static func status(_ status: SemanticStatus) -> Color {
        switch status {
        case .normal: return normal
        case .watch: return watch
        case .attention: return attention
        case .critical: return critical
        case .unknown: return unknown
        }
    }

    /// Provenance is shown with weight, not hue: measured values read as certain,
    /// derived ones read as quieter.
    static func provenance(_ provenance: DataProvenance) -> Color {
        switch provenance {
        case .measured: return primaryText
        case .estimated, .inferred: return secondaryText
        case .unavailable: return unknown
        }
    }
}

extension View {
    /// The standard card surface.
    func dlCard(padding: CGFloat = DL.Spacing.medium) -> some View {
        self
            .padding(padding)
            .background(DLColor.surface, in: RoundedRectangle(cornerRadius: DL.Radius.card, style: .continuous))
    }

    func dlScreenPadding() -> some View {
        padding(.horizontal, DL.Spacing.screen)
    }
}
