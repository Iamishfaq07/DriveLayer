import SwiftUI

/// A status indicator that works without colour.
///
/// The shape changes with severity — a filled disc for normal, a triangle for watch
/// and attention, an octagon for critical, a question mark for unknown — so the
/// meaning survives greyscale, glare, and colour blindness.
struct StatusIndicator: View {
    let status: SemanticStatus
    var showsLabel: Bool = true
    var size: CGFloat = 15

    var body: some View {
        HStack(spacing: DL.Spacing.tight) {
            Image(systemName: status.symbolName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(DLColor.status(status))
                .accessibilityHidden(showsLabel)
            if showsLabel {
                Text(status.label)
                    .font(DL.Font.callout)
                    .foregroundStyle(DLColor.primaryText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(showsLabel ? status.label : Text(status.label))
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

    enum Emphasis { case standard, large, hero }

    private var valueFont: Font {
        switch emphasis {
        case .standard: return DL.Font.metric
        case .large: return DL.Font.display
        case .hero: return DL.Font.hero
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DL.Spacing.hairline) {
            SectionLabel(text: label)
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(valueFont)
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
                    .font(valueFont)
                    .foregroundStyle(DLColor.unknown)
                    .accessibilityLabel("Not available")
            }
        }
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
        .dlCard()
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
            }
        }
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
