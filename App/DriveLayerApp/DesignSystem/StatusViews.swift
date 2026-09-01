import SwiftUI

/// A status indicator that works without colour.
///
/// The shape changes with severity — a filled disc for normal, a triangle for watch
/// and attention, an octagon for critical, a question mark for unknown — so the
/// meaning survives greyscale, glare, and colour blindness.
struct StatusIndicator: View {
    let status: SemanticStatus
    var showsLabel: Bool = true
    /// A base size, not a fixed one — it is multiplied by the text-size scale below.
    var size: CGFloat = 15

    /// Anchored to `callout`, the size of the label beside it, so the mark and the
    /// word grow together instead of the symbol staying stubbornly small.
    @ScaledMetric(relativeTo: .callout) private var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: DL.Spacing.tight) {
            Image(systemName: status.symbolName)
                .font(.system(size: size * scale, weight: .semibold))
                .foregroundStyle(DLColor.status(status))
            if showsLabel {
                Text(status.label)
                    .font(DL.Font.callout)
                    .foregroundStyle(DLColor.primaryText)
            }
        }
        // One combined element carrying the status name, whether or not the label is
        // drawn — the symbol on its own is meaningless to VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(status.label))
    }
}

/// A small uppercase section label.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(DL.Font.label)
            .tracking(0.8)
            .foregroundStyle(DLColor.secondaryText)
    }
}

/// One value with its label, and — when it isn't a plain measurement — a marker
/// saying so. This is the component that keeps estimates from reading as facts.
struct MetricView: View {
    let label: String
    let value: String?
    var unit: String?
    var provenance: DataProvenance = .measured
    var status: SemanticStatus?
    var emphasis: Emphasis = .standard

    enum Emphasis {
        case standard, large, hero

        var font: DL.ScaledFont {
            switch self {
            case .standard: return .metric
            case .large: return .display
            case .hero: return .hero
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DL.Spacing.hairline) {
            SectionLabel(text: label)
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .dlFont(emphasis.font)
                        .foregroundStyle(status.map(DLColor.status) ?? DLColor.primaryText)
                        .contentTransition(.numericText())
                    if let unit {
                        Text(unit)
                            .font(DL.Font.callout)
                            .foregroundStyle(DLColor.secondaryText)
                    }
                }
                if provenance != .measured, let qualifier = provenance.userFacingQualifier {
                    Text(qualifier)
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.secondaryText)
                }
            } else {
                // An unavailable value is a dash and a reason, never a zero.
                Text("—")
                    .dlFont(emphasis.font)
                    .foregroundStyle(DLColor.unknown)
            }
        }
        // One element, one sentence. Read as separate children this is four swipes
        // — "Range", "326", "km", "estimated" — and the qualifier ends up detached
        // from the number it qualifies, which is exactly the thing it must not be.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenDescription))
    }

    private var spokenDescription: String {
        guard let value else { return "\(label): not available" }
        var spoken = "\(label): \(value)"
        if let unit { spoken += " \(unit)" }
        if provenance != .measured, let qualifier = provenance.userFacingQualifier {
            spoken += ", \(qualifier)"
        }
        if let status { spoken += ", \(status.label)" }
        return spoken
    }
}

/// A tappable row summarising one vehicle system.
struct SystemRow: View {
    let system: VehicleHealthSystem

    var body: some View {
        HStack(alignment: .top, spacing: DL.Spacing.medium) {
            Image(systemName: system.kind.symbolName)
                .font(.system(size: 18))
                .foregroundStyle(DLColor.secondaryText)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(system.kind.displayName)
                    .font(DL.Font.body.weight(.medium))
                    .foregroundStyle(DLColor.primaryText)
                Text(system.headline)
                    .font(DL.Font.callout)
                    .foregroundStyle(DLColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DL.Spacing.small)
            StatusIndicator(status: system.status, showsLabel: false, size: 17)
        }
        .padding(.vertical, DL.Spacing.tight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(system.kind.displayName), \(system.status.label). \(system.headline)"))
    }
}

/// The card an insight is rendered as.
struct InsightCard: View {
    let insight: DriveInsight
    var isCompact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DL.Spacing.small) {
            HStack(spacing: DL.Spacing.tight) {
                Image(systemName: insight.severity == .normal ? insight.category.symbolName : insight.severity.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DLColor.status(insight.severity))
                    .accessibilityHidden(true)
                Text(insight.title)
                    .font(DL.Font.label)
                    .tracking(0.8)
                    .foregroundStyle(DLColor.status(insight.severity))
                Spacer()
            }
            Text(insight.summary)
                .font(DL.Font.body)
                .foregroundStyle(DLColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if !isCompact {
                if let details = insight.details {
                    Text(details)
                        .font(DL.Font.callout)
                        .foregroundStyle(DLColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action = insight.recommendedAction {
                    Label(action, systemImage: "arrow.turn.down.right")
                        .font(DL.Font.callout)
                        .foregroundStyle(DLColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !insight.sourceData.isEmpty {
                    EvidenceRow(data: insight.sourceData)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Tinted by severity when it is anything above normal, so a column of insights
        // can be scanned for the amber one without reading a word of it. A normal
        // insight stays on the plain surface: colour is spent on what needs it.
        .dlCard(tint: insight.severity > .normal ? DLColor.status(insight.severity) : nil)
        // A card is one thought. Combining keeps the title, the summary and the
        // reasoning in one utterance instead of four separate swipes.
        .accessibilityElement(children: .combine)
    }
}

/// The evidence behind an insight, so "how do you know that?" has an answer on screen.
struct EvidenceRow: View {
    let data: [InsightSourceDatum]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().opacity(DL.Opacity.separator)
            ForEach(data) { datum in
                HStack(spacing: DL.Spacing.tight) {
                    Text(datum.label)
                        .font(DL.Font.caption)
                        .foregroundStyle(DLColor.secondaryText)
                    Spacer(minLength: DL.Spacing.small)
                    Text(datum.formattedValue)
                        .font(DL.Font.caption.monospacedDigit())
                        .foregroundStyle(DLColor.provenance(datum.provenance))
                    if datum.provenance != .measured {
                        Text(datum.provenance.label.lowercased())
                            .font(DL.Font.caption)
                            .foregroundStyle(DLColor.unknown)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(spoken(datum)))
            }
        }
    }

    private func spoken(_ datum: InsightSourceDatum) -> String {
        var text = "\(datum.label): \(datum.formattedValue)"
        if datum.provenance != .measured { text += ", \(datum.provenance.label.lowercased())" }
        return text
    }
}

/// A minimal trend line. Deliberately axis-free: it shows shape, and the numbers
/// beside it carry the precision.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = DLColor.accent

    var body: some View {
        GeometryReader { proxy in
            let points = normalised(in: proxy.size)
            if points.count >= 2 {
                Path { path in
                    path.move(to: points[0])
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: 34)
        .accessibilityHidden(true)
    }

    private func normalised(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2, let minimum = values.min(), let maximum = values.max() else { return [] }
        let span = maximum - minimum
        let stepX = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            // A flat series draws through the middle rather than dividing by zero.
            let fraction = span > 0.000_001 ? (value - minimum) / span : 0.5
            return CGPoint(x: CGFloat(index) * stepX, y: size.height * (1 - fraction))
        }
    }
}
