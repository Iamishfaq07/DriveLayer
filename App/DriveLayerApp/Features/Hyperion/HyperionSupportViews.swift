import SwiftUI

/// Confidence as a small, honest badge: three bars, filled to the level, with the
/// hedge in words beside them so a driver never has to decode the bars.
struct ConfidenceBadge: View {

    let confidence: InsightConfidence

    var body: some View {
        HStack(spacing: DL.Spacing.tight) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(index < filled ? DLColor.accent : DLColor.primaryText.opacity(DL.Opacity.fill))
                        .frame(width: 4, height: CGFloat(6 + index * 3))
                }
            }
            .accessibilityHidden(true)
            Text(confidence.displayName)
                .font(DL.Font.caption.weight(.medium))
                .foregroundStyle(DLColor.secondaryText)
        }
        .accessibilityLabel(Text(confidence.displayName))
    }

    private var filled: Int {
        switch confidence {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }
}

/// Baseline maturity, so a quiet screen reads as "still learning" rather than as
/// broken. This is the difference between a driver trusting a screen that says little
/// and a driver assuming it does nothing.
struct HyperionLearningCard: View {

    let assessment: HyperionAssessment

    var body: some View {
        let lowest = assessment.assessedSections.map(\.confidence).min()
        VStack(alignment: .leading, spacing: DL.Spacing.small) {
            SectionLabel(text: "Learning")
            if let lowest {
                HStack(alignment: .top, spacing: DL.Spacing.small) {
                    ConfidenceBadge(confidence: lowest)
                        .padding(.top, 2)
                    Text(line(for: lowest))
                        .font(DL.Font.callout)
                        .foregroundStyle(DLColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Baselines build from real drives. The more comparable drives DriveLayer sees, the more specific each area's judgement becomes.")
                    .font(DL.Font.callout)
                    .foregroundStyle(DLColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dlCard()
    }

    private func line(for confidence: InsightConfidence) -> String {
        switch confidence {
        case .low: return "Early days. Judgements rest on limited data and will sharpen with more drives."
        case .medium: return "A pattern is forming. Several comparable drives are in; a few more will make this firm."
        case .high: return "Well established. These judgements rest on a consistent pattern across your drives."
        }
    }
}

/// The compact Hyperion tile for the Today screen: the overall ring, the verdict, and
/// the one-line summary. Tapping it opens the full screen. This is how the engine
/// intelligence earns a place on the home screen without a separate tab.
struct HyperionSummaryCard: View {

    let assessment: HyperionAssessment

    var body: some View {
        HStack(alignment: .center, spacing: DL.Spacing.medium) {
            StatusRing(status: assessment.overall, size: 56, lineWidth: 5)
            VStack(alignment: .leading, spacing: DL.Spacing.hairline) {
                SectionLabel(text: "Hyperion")
                Text(assessment.isSilent ? "Not reading yet" : assessment.overall.label)
                    .dlFont(.metric, weight: .semibold)
                    .foregroundStyle(assessment.isSilent ? DLColor.secondaryText : DLColor.status(assessment.overall))
                    .contentTransition(.interpolate)
                Text(assessment.summary)
                    .font(DL.Font.caption)
                    .foregroundStyle(DLColor.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DLColor.unknown)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dlCard(tint: assessment.isSilent ? nil : DLColor.status(assessment.overall))
        .accessibilityElement(children: .combine)
    }
}
