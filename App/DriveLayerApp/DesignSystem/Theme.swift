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
    ///
    /// These are all built on text styles, so they follow the driver's text-size
    /// setting. The three chosen sizes that are not text styles live in
    /// `DL.ScaledFont` and are applied with `.dlFont(_:)`.
    enum Font {
        static var title: SwiftUI.Font { .system(.title3, design: .default).weight(.semibold) }
        static var body: SwiftUI.Font { .system(.body) }
        static var callout: SwiftUI.Font { .system(.callout) }
        static var caption: SwiftUI.Font { .system(.caption) }
        /// Small uppercase label with tracking, used for section headers.
        static var label: SwiftUI.Font { .system(.caption, design: .default).weight(.semibold) }
    }

    /// The three sizes chosen by hand rather than inherited from a text style.
    ///
    /// `Font.system(size:)` ignores the text-size setting completely. Used naively
    /// that makes the large, meaningful numbers — the whole point of the design — the
    /// one thing on screen that will not grow for a driver who needs it larger.
    /// Anchoring each size to a text style with `@ScaledMetric` gives that back.
    enum ScaledFont {
        /// The one number a screen is about.
        case hero
        case display
        case metric

        var size: CGFloat {
            switch self {
            case .hero: return 56
            case .display: return 34
            case .metric: return 24
            }
        }

        /// The style each size scales in step with. `largeTitle` is 34pt by default,
        /// which is `display` exactly; `title` is 28pt, nearest to `metric`.
        var textStyle: SwiftUI.Font.TextStyle {
            switch self {
            case .hero, .display: return .largeTitle
            case .metric: return .title
            }
        }
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
/// The values themselves live in `Palette`, in the core, where `PaletteTests` checks
/// every one of them against every surface it can land on. This layer only turns
/// them into `Color` and picks the appearance — so a colour cannot be changed to
/// something unreadable without a test failing.
enum DLColor {

    /// Resolves per trait collection, so it follows the system appearance and, on a
    /// CarPlay screen, the car's day/night mode.
    private static func dynamic(_ resolve: @escaping @Sendable (Palette.Appearance) -> RGB) -> Color {
        Color(uiColor: UIColor { traits in
            let colour = resolve(traits.userInterfaceStyle == .dark ? .dark : .light)
            return UIColor(red: colour.red, green: colour.green, blue: colour.blue, alpha: 1)
        })
    }

    // Surfaces. Dark mode is the primary case: this is an app used in a car at night.
    static let background = dynamic { Palette.background($0) }
    static let surface = dynamic { Palette.surface($0) }
    static let surfaceRaised = dynamic { Palette.surfaceRaised($0) }

    static let primaryText = dynamic { Palette.primaryText($0) }
    static let secondaryText = dynamic { Palette.secondaryText($0) }

    /// The single accent, used for interactive elements only.
    static let accent = dynamic { Palette.accent($0) }

    static let normal = status(.normal)
    static let watch = status(.watch)
    static let attention = status(.attention)
    static let critical = status(.critical)
    static let unknown = status(.unknown)

    static func status(_ status: SemanticStatus) -> Color {
        dynamic { Palette.status(status, $0) }
    }

    /// Provenance is shown with weight, not hue: measured values read as certain,
    /// derived ones read as quieter.
    static func provenance(_ provenance: DataProvenance) -> Color {
        switch provenance {
        // A value you typed is as certain as one the car measured -- the uncertainty in
        // `DataProvenance.confidence` is 1.0 for both -- so it reads at full weight.
        case .measured, .userEntered: return primaryText
        case .estimated, .inferred: return secondaryText
        case .unavailable: return unknown
        }
    }
}

/// Applies a chosen point size that still honours Dynamic Type.
private struct ScaledSystemFont: ViewModifier {

    @ScaledMetric private var size: CGFloat
    private let weight: SwiftUI.Font.Weight
    private let usesMonospacedDigits: Bool

    init(_ font: DL.ScaledFont, weight: SwiftUI.Font.Weight, usesMonospacedDigits: Bool) {
        _size = ScaledMetric(wrappedValue: font.size, relativeTo: font.textStyle)
        self.weight = weight
        self.usesMonospacedDigits = usesMonospacedDigits
    }

    func body(content: Content) -> some View {
        let font = SwiftUI.Font.system(size: size, weight: weight, design: .rounded)
        return content.font(usesMonospacedDigits ? font.monospacedDigit() : font)
    }
}

extension View {
    /// One of the design system's large sizes, scaled to the driver's text setting.
    ///
    /// Monospaced digits are an option rather than the default: they stop a live
    /// value jittering as it counts, and cost a little legibility everywhere else.
    func dlFont(_ font: DL.ScaledFont,
                weight: SwiftUI.Font.Weight = .medium,
                usesMonospacedDigits: Bool = false) -> some View {
        modifier(ScaledSystemFont(font, weight: weight, usesMonospacedDigits: usesMonospacedDigits))
    }

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

/// A row that becomes a column once the text is large enough that a row would
/// squeeze each item down to a few characters.
///
/// Children size themselves, so give each one
/// `.frame(maxWidth: .infinity, alignment: .leading)` to share the width evenly —
/// that reads correctly in both directions, where a `Spacer` between them would
/// turn into a gap once stacked.
struct DLAdaptiveRow<Content: View>: View {

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var spacing: CGFloat = DL.Spacing.medium
    @ViewBuilder var content: Content

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: spacing) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: spacing) { content }
        }
    }
}
