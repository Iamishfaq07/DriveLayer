import SwiftUI

/// The Hyperion screen: what DriveLayer makes of the engine, as interpretation.
///
/// This is the surface the whole intelligence layer was built to reach, and until now
/// it did not exist on the phone. `HyperionAssessment` was computed on every analysis
/// pass and read by exactly one thing - a single CarPlay list row. Six areas of engine
/// judgement, each with a status, an explanation, a comparison to the car's own
/// baseline and the evidence behind it, and no screen to show any of it.
///
/// It is deliberately not a wall of gauges. The default view is the interpretation:
/// an overall verdict, then each area as a card that opens to its reasoning. Numbers
/// appear as evidence for a judgement, never as the judgement itself.
struct HyperionView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var expanded: Set<HyperionSection.Area> = []

    private var drive: DriveSessionCoordinator { environment.drive }
    private var assessment: HyperionAssessment { drive.hyperion }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DL.Spacing.medium) {
                verdict
                    .dlArrive(index: 0)

                if assessment.isSilent {
                    silentExplanation
                        .dlArrive(index: 1)
                }

                ForEach(Array(assessment.sections.enumerated()), id: \.element.id) { index, section in
                    HyperionSectionCard(section: section,
                                        isExpanded: expanded.contains(section.area)) {
                        toggle(section.area)
                    }
                    .dlArrive(index: index + 2)
                }

                HyperionLearningCard(assessment: assessment)
                    .dlArrive(index: assessment.sections.count + 2)
            }
            .dlScreenPadding()
            .padding(.vertical, DL.Spacing.medium)
        }
        .background(PanelBackground(statusTint: DLColor.status(assessment.overall)))
        .navigationTitle("Hyperion")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { drive.refreshAnalysis(force: true) }
    }

    private func toggle(_ area: HyperionSection.Area) {
        withAnimation(DL.Motion.arrive) {
            if expanded.contains(area) { expanded.remove(area) } else { expanded.insert(area) }
        }
    }

    // MARK: - Verdict

    /// The one thing this screen is about: the overall status, given the weight of a
    /// ring and a sentence, with the roll-up rule visible beneath it so "Normal" can be
    /// read as "normal across the four areas that were assessed" rather than as a
    /// blanket reassurance.
    private var verdict: some View {
        HStack(alignment: .center, spacing: DL.Spacing.large) {
            StatusRing(status: assessment.overall, size: 84, lineWidth: 7)
            VStack(alignment: .leading, spacing: DL.Spacing.tight) {
                SectionLabel(text: "Overall")
                Text(assessment.overall.label)
                    .dlFont(.display, weight: .semibold)
                    .foregroundStyle(DLColor.status(assessment.overall))
                    .contentTransition(.interpolate)
                Text(assessment.summary)
                    .font(DL.Font.callout)
                    .foregroundStyle(DLColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                coverageLine
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dlCard(padding: DL.Spacing.large, tint: DLColor.status(assessment.overall))
        .accessibilityElement(children: .combine)
    }

    /// "4 of 6 areas assessed" - the honesty line. An overall of Normal with two areas
    /// unassessed is a different statement from Normal across all six, and the
    /// difference belongs on screen rather than in a footnote.
    private var coverageLine: some View {
        let assessed = assessment.assessedSections.count
        let total = assessment.sections.count
        return HStack(spacing: DL.Spacing.tight) {
            FillBar(fraction: total == 0 ? nil : Double(assessed) / Double(total),
                    tint: DLColor.status(assessment.overall).opacity(0.8),
                    height: 4)
                .frame(width: 72)
            Text("\(assessed) of \(total) areas assessed")
                .font(DL.Font.caption)
                .foregroundStyle(DLColor.secondaryText)
        }
        .padding(.top, DL.Spacing.hairline)
    }

    @ViewBuilder
    private var silentExplanation: some View {
        let connected = environment.obd.isConnected
        HStack(alignment: .top, spacing: DL.Spacing.small) {
            Image(systemName: connected ? "hourglass" : "cable.connector")
                .font(.title3)
                .foregroundStyle(DLColor.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DL.Spacing.hairline) {
                Text(connected ? "Warming up" : "Nothing to read yet")
                    .font(DL.Font.body.weight(.medium))
                    .foregroundStyle(DLColor.primaryText)
                Text(connected
                     ? "The adapter is connected. Each area below fills in as the engine starts reporting the values it needs."
                     : "Hyperion reads the engine through an OBD-II adapter. Connect one and each area below comes to life.")
                    .font(DL.Font.callout)
                    .foregroundStyle(DLColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dlCard()
    }
}
