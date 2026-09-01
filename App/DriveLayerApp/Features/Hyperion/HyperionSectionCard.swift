import SwiftUI

/// One area of the engine as a card that opens to its reasoning.
///
/// Collapsed, it is a status and a headline - enough to scan six areas in a glance.
/// Expanded, it shows the detail, the comparison against this car's own baseline, the
/// confidence, and the evidence: the actual readings the judgement rests on, each
/// tagged with where it came from. "How do you know that?" has an answer one tap away,
/// which is the whole difference between intelligence and a coloured dot.
///
/// An area that has not been assessed says so, and says why, rather than hiding. That
/// is a written-down promise the screen keeps visible.
struct HyperionSectionCard: View {

    let section: HyperionSection
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: DL.Spacing.small) {
                header
                if isExpanded {
                    expandedBody
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dlCard(tint: section.isAssessed ? DLColor.status(section.status) : nil)
        }
        .dlPressable()
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(isExpanded ? "Collapses the reasoning" : "Shows the reasoning"))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DL.Spacing.small) {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(section.isAssessed ? DLColor.status(section.status) : DLColor.unknown)
                .frame(width: 28)
                .symbolEffect(.bounce, value: isExpanded)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DL.Spacing.hairline) {
                SectionLabel(text: section.area.displayName)
                Text(section.headline)
                    .font(DL.Font.body.weight(.medium))
                    .foregroundStyle(section.isAssessed ? DLColor.primaryText : DLColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DL.Spacing.small)

            if section.isAssessed {
                StatusIndicator(status: section.status, showsLabel: false, size: 16)
            }
            Image(systemName: "chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DLColor.unknown)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var expandedBody: some View {
        Divider().opacity(DL.Opacity.separator)

        Text(section.detail)
            .font(DL.Font.callout)
            .foregroundStyle(DLColor.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

        if let comparison = section.comparison {
            // The comparison is the intelligence: this car, against itself, over time.
            // Set apart so it reads as the sentence that matters.
            HStack(alignment: .top, spacing: DL.Spacing.tight) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DLColor.accent)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                Text(comparison)
                    .font(DL.Font.callout)
                    .foregroundStyle(DLColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if section.isAssessed {
            ConfidenceBadge(confidence: section.confidence)
        }

        if !section.dataPoints.isEmpty {
            EvidenceRow(data: section.dataPoints)
        }
    }

    /// One symbol per area, chosen to survive at small size in a car.
    private var symbol: String {
        switch section.area {
        case .thermal: return "thermometer.medium"
        case .airAndTurbo: return "wind"
        case .fuelSystem: return "fuelpump"
        case .aftertreatment: return "leaf"
        case .battery: return "bolt.batteryblock"
        case .diagnostics: return "stethoscope"
        }
    }
}
