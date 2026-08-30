import XCTest
@testable import DriveLayerCore

/// Heat soak is the case where the honest answer is "this is fine".
///
/// A turbocharged engine crawling in traffic really does draw intake air far hotter than
/// ambient, and the failure mode for this file is not missing a fault -- it is inventing
/// one. So most of what follows checks that a large, alarming-looking number stays worded
/// and statused as the normal operating condition it is.
final class HeatSoakAnalyserTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixtures

    /// A baseline built the way the rest of the suite builds them: through
    /// `BaselineEngine` over a synthetic month, rather than hand-filling the struct.
    ///
    /// Daily values step over a one degree spread, so the 10th-90th percentile band is
    /// narrow but real and `isOutsideUsualRange` means something.
    private func establishedBaseline(around value: Double) -> MetricBaseline {
        let key = BaselineKey(metric: .intakeAirTemperatureC, context: .idle)
        var aggregates: [BaselineDailyAggregate] = []
        for daysAgo in 0..<30 {
            let day = start.addingTimeInterval(-Double(daysAgo) * 86_400)
            let daily = value + Double(daysAgo % 3) - 1
            BaselineEngine.accumulate(into: &aggregates, key: key, value: daily, at: day)
            BaselineEngine.accumulate(into: &aggregates, key: key, value: daily + 0.01, at: day)
        }
        return BaselineEngine.build(key: key, from: aggregates, now: start)!
    }

    /// The same shape, trimmed below `minimumDays` / `minimumObservations`.
    ///
    /// Trimmed after the fact because `BaselineEngine.build` deliberately refuses to
    /// return a baseline that thin at all, and the case under test is a baseline that
    /// exists but has not earned the right to be compared against yet.
    private func youngBaseline() -> MetricBaseline {
        var baseline = establishedBaseline(around: 15)
        baseline.dayCount = 2
        baseline.observationCount = 10
        return baseline
    }

    private func assess(intake: Double?,
                        ambient: Double?,
                        speedKmh: Double? = nil,
                        idleSeconds: TimeInterval? = nil,
                        peakDeltaC: Double? = nil,
                        baseline: MetricBaseline? = nil) -> HeatSoakAssessment {
        HeatSoakAnalyser.assess(intakeC: intake.map { .measured($0, at: start) } ?? .unavailable(),
                                ambientC: ambient.map { .measured($0, at: start) } ?? .unavailable(),
                                speedKmh: speedKmh,
                                idleSeconds: idleSeconds,
                                peakDeltaC: peakDeltaC,
                                baseline: baseline)
    }

    // MARK: - Missing inputs

    func testMissingIntakeIsUnavailableRatherThanAZeroDelta() {
        let assessment = assess(intake: nil, ambient: 30)
        XCTAssertEqual(assessment.phase, .unknown)
        XCTAssertNil(assessment.deltaC.value, "a missing side must not subtract to zero")
        XCTAssertEqual(assessment.status, .unknown)
        XCTAssertEqual(assessment.confidence, .low)
    }

    func testMissingAmbientIsAlsoUnavailable() {
        XCTAssertEqual(assess(intake: 55, ambient: nil), .unknown,
                       "one absent input makes the whole comparison meaningless")
    }

    func testUnavailableStateSaysWhichReadingsAreMissing() {
        // A state view renders this, so it has to explain itself rather than say "no data".
        XCTAssertTrue(HeatSoakAssessment.unknown.detail.contains("intake and ambient"))
        XCTAssertTrue(HeatSoakAssessment.unknown.dataPoints.isEmpty)
    }

    // MARK: - Phases

    func testIntakeCloseToAmbientIsNormal() {
        let assessment = assess(intake: 38, ambient: 30, speedKmh: 60)
        XCTAssertEqual(assessment.phase, .normal)
        XCTAssertEqual(assessment.status, .normal)
        XCTAssertEqual(assessment.deltaC.value, 8)
    }

    func testTheNormalCopyDoesNotClaimAirflowWhileStationary() {
        XCTAssertTrue(assess(intake: 38, ambient: 30, speedKmh: 60).detail
            .contains("air moving through the engine bay"))

        // The same benign reading, sitting still. The explanation no longer applies, so
        // it is dropped rather than asserted anyway.
        let stopped = assess(intake: 38, ambient: 30, speedKmh: 0).detail
        XCTAssertFalse(stopped.contains("air moving"))
        XCTAssertTrue(stopped.hasSuffix("which is what it should be."))
    }

    func testSustainedRiseWithNoAirflowIsHeatSoak() {
        let assessment = assess(intake: 68, ambient: 32, speedKmh: 4, idleSeconds: 600)
        XCTAssertEqual(assessment.phase, .soaking)
        XCTAssertEqual(assessment.deltaC.value, 36)
        XCTAssertEqual(assessment.headline, "HEAT SOAK")
    }

    func testFallingFromThePeakIsRecoveringEvenWhileStillHot() {
        // 40 over ambient is a lot, but it was 50 a minute ago. The direction is the
        // thing worth telling the driver, not the magnitude.
        let assessment = assess(intake: 72, ambient: 32, peakDeltaC: 50)
        XCTAssertEqual(assessment.phase, .recovering)
        XCTAssertEqual(assessment.headline, "INTAKE COOLING")
    }

    func testAirflowBelowTheElevatedThresholdReadsAsRecovering() {
        let assessment = assess(intake: 50, ambient: 32, speedKmh: 80)
        XCTAssertEqual(assessment.deltaC.value, 18, "between the normal and elevated thresholds")
        XCTAssertEqual(assessment.phase, .recovering)
    }

    func testAFallShorterThanTheRecoveryThresholdIsNotYetRecovering() {
        // Two degrees off a peak of 38 is noise, not a trend, and calling it "cooling"
        // would be a promise the next sample might not keep.
        let assessment = assess(intake: 68, ambient: 32, peakDeltaC: 38)
        XCTAssertEqual(assessment.phase, .soaking)
    }

    // MARK: - The point of the file: no manufactured alarm

    func testHeatSoakIsNeverWorseThanAWatch() {
        // Deliberately absurd: 90 over ambient, stationary, for half an hour.
        let assessment = assess(intake: 125, ambient: 35, speedKmh: 0, idleSeconds: 1_800)
        XCTAssertEqual(assessment.phase, .soaking)
        XCTAssertEqual(assessment.status, .watch,
                       "physics working as designed is not an attention or a critical")
    }

    func testNoInputEverProducesAttentionOrCritical() {
        let cases: [(intake: Double, ambient: Double, speed: Double?)] = [
            (36, 30, 90),   // normal, moving
            (60, 30, 0),    // soaking, stationary
            (70, 30, 100),  // hot, but with airflow
            (31, 30, nil)   // barely any difference at all
        ]
        for cased in cases {
            let status = assess(intake: cased.intake, ambient: cased.ambient, speedKmh: cased.speed).status
            XCTAssertTrue(status == .normal || status == .watch,
                          "intake \(cased.intake) over ambient \(cased.ambient) escalated to \(status)")
        }
    }

    func testSoakingCopyExplainsTheCauseRatherThanJustReportingTheNumber() {
        let detail = assess(intake: 68, ambient: 32, speedKmh: 2, idleSeconds: 600).detail
        XCTAssertTrue(detail.contains("intercooler"), "the driver is told why it happens")
        XCTAssertTrue(detail.contains("falls again"), "and that it resolves on its own")
    }

    func testLongIdleIsMentionedInMinutesOnlyWhenItIsTheExplanation() {
        XCTAssertTrue(assess(intake: 68, ambient: 32, idleSeconds: 600).detail.contains("10 minutes"))

        // Under two minutes it explains nothing, so it is left out rather than padded
        // with a figure the driver would have to discount.
        XCTAssertFalse(assess(intake: 68, ambient: 32, idleSeconds: 30).detail.contains("minutes"))
    }

    // MARK: - Provenance

    func testTheDeltaIsEstimatedBecauseItIsDerived() {
        let assessment = assess(intake: 60, ambient: 30)
        XCTAssertEqual(assessment.intakeC.provenance, .measured)
        XCTAssertEqual(assessment.ambientC.provenance, .measured)
        XCTAssertEqual(assessment.deltaC.provenance, .estimated,
                       "a subtraction of two measurements is not itself a measurement")
        XCTAssertNotNil(assessment.deltaC.basis, "and the UI can show how it was derived")
    }

    func testSpeedAppearsInTheEvidenceOnlyWhenItIsKnown() {
        XCTAssertEqual(assess(intake: 60, ambient: 30).dataPoints.map(\.label),
                       ["Intake", "Ambient", "Above ambient"])
        XCTAssertTrue(assess(intake: 60, ambient: 30, speedKmh: 50).dataPoints
            .map(\.label).contains("Speed"))
    }

    func testTheDerivedRowIsLabelledAsEstimatedInTheEvidence() {
        let points = assess(intake: 60, ambient: 30).dataPoints
        XCTAssertEqual(points.first(where: { $0.label == "Intake" })?.provenance, .measured)
        XCTAssertEqual(points.first(where: { $0.label == "Above ambient" })?.provenance, .estimated)
    }

    // MARK: - Baseline comparison

    func testNoComparisonWithoutABaseline() {
        let assessment = assess(intake: 60, ambient: 30)
        XCTAssertNil(assessment.comparison)
        XCTAssertEqual(assessment.confidence, .medium)
    }

    func testAYoungBaselineIsNotComparedAgainst() {
        let assessment = assess(intake: 60, ambient: 30, baseline: youngBaseline())
        XCTAssertNil(assessment.comparison, "too little history to claim what is usual")
        XCTAssertEqual(assessment.confidence, .medium)
    }

    func testADeltaInsideTheUsualRangeIsNotRemarkedOn() {
        // 15 over ambient against a learned median of 15: there is nothing to say.
        let assessment = assess(intake: 45, ambient: 30, baseline: establishedBaseline(around: 15))
        XCTAssertNil(assessment.comparison)
        XCTAssertEqual(assessment.confidence, .high, "an established baseline raises confidence")
    }

    func testADeltaOutsideTheUsualRangeIsRemarkedOnButNotEscalated() throws {
        let assessment = assess(intake: 60, ambient: 30, baseline: establishedBaseline(around: 15))
        let comparison = try XCTUnwrap(assessment.comparison)
        XCTAssertTrue(comparison.contains("higher"))
        XCTAssertTrue(comparison.contains("not worth acting on by itself"),
                      "a difference from baseline is context, not a diagnosis")
        XCTAssertEqual(assessment.status, .watch,
                       "an unusual reading is still only a watch: the comparison does not escalate")
    }

    func testALowerThanUsualDeltaIsDescribedAsLower() throws {
        let assessment = assess(intake: 35, ambient: 30, baseline: establishedBaseline(around: 30))
        let comparison = try XCTUnwrap(assessment.comparison)
        XCTAssertTrue(comparison.contains("lower"))
    }

    // MARK: - Peak tracking

    func testThePeakStartsAtTheFirstReading() {
        XCTAssertEqual(HeatSoakAnalyser.updatedPeak(current: nil, delta: 22), 22)
    }

    func testThePeakRisesImmediately() {
        XCTAssertEqual(HeatSoakAnalyser.updatedPeak(current: 20, delta: 31), 31)
    }

    func testThePeakDecaysRatherThanLatching() {
        // A latched maximum would report "cooling" for the rest of a long drive, so the
        // peak has to forget -- but slowly, so one low sample cannot erase it.
        XCTAssertEqual(HeatSoakAnalyser.updatedPeak(current: 40, delta: 10), 39.95, accuracy: 0.0001)

        var peak = 40.0
        for _ in 0..<200 { peak = HeatSoakAnalyser.updatedPeak(current: peak, delta: 10) }
        XCTAssertEqual(peak, 30, accuracy: 0.0001, "and decays steadily towards the current delta")
    }

    func testThePeakNeverFallsBelowTheCurrentDelta() {
        XCTAssertEqual(HeatSoakAnalyser.updatedPeak(current: 12, delta: 11.99), 11.99, accuracy: 0.0001)
    }

    // MARK: - Display

    func testEveryPhaseHasSomethingToShow() {
        for phase in HeatSoakPhase.allCases {
            XCTAssertFalse(phase.displayName.isEmpty)
            XCTAssertFalse(phase.rawValue.isEmpty)
        }
    }
}
