import XCTest
@testable import DriveLayerCore

/// The 12V logic the health view already had, lifted out so the Hyperion assessment reads
/// the same implementation rather than growing a second one.
///
/// The reason is not tidiness. This project already has an example of the failure mode:
/// `EngineTemperatureRule` thresholds coolant independently of `EngineThermalModel`, and two
/// subsystems judging the same metric separately is how two screens end up disagreeing about
/// the same car.
final class BatteryIntelligenceTests: XCTestCase {

    private let harrier = VehicleProfileCatalog.harrier2026AdventureXPlus
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// A baseline built through `BaselineEngine`, matching the rest of the suite.
    /// `decliningBy` is volts per day of *decline*, so a positive number falls over time.
    private func baseline(around value: Double, decliningBy perDay: Double = 0) -> MetricBaseline {
        let key = BaselineKey(metric: .controlModuleVoltageV, context: .engineOff)
        var aggregates: [BaselineDailyAggregate] = []
        for daysAgo in 0..<30 {
            let day = start.addingTimeInterval(-Double(daysAgo) * 86_400)
            // Older days sit higher, so the trend through to today is downward.
            let daily = value + Double(daysAgo) * perDay
            BaselineEngine.accumulate(into: &aggregates, key: key, value: daily, at: day)
            BaselineEngine.accumulate(into: &aggregates, key: key, value: daily + 0.01, at: day)
        }
        return BaselineEngine.build(key: key, from: aggregates, now: start)!
    }

    private func assess(_ volts: Double?,
                        running: Bool? = true,
                        baseline: MetricBaseline? = nil,
                        connected: Bool = true) -> BatteryAssessment {
        BatteryIntelligence.assess(voltage: volts.map { .measured($0, at: start) } ?? .unavailable(),
                                   isEngineRunning: running,
                                   baseline: baseline,
                                   profile: harrier,
                                   isAdapterConnected: connected)
    }

    // MARK: - Nothing to read

    func testNoVoltageWithAnAdapterMeansTheCarDoesNotReportIt() {
        let assessment = assess(nil, connected: true)
        XCTAssertFalse(assessment.isAvailable)
        XCTAssertEqual(assessment.unavailability, .pidNotSupportedByVehicle("Control module voltage"))
        XCTAssertEqual(assessment.status, .unknown)
    }

    func testNoVoltageWithoutAnAdapterSaysSoInstead() {
        // Two different sentences for two different situations, and the driver can act on
        // exactly one of them.
        XCTAssertEqual(assess(nil, connected: false).unavailability, .obdNotConnected)
    }

    // MARK: - Judged against the right condition

    func testAHealthyChargingVoltageIsNormal() {
        XCTAssertEqual(assess(13.8, running: true).status, .normal)
    }

    func testAHealthyRestingVoltageIsNormal() {
        XCTAssertEqual(assess(12.5, running: false).status, .normal)
    }

    /// The reason the condition is chosen rather than assumed: a resting voltage judged
    /// against charging thresholds looks like a flat battery, and a charging voltage judged
    /// against resting thresholds looks like an over-voltage fault. Both are wrong.
    func testTheSameVoltageIsJudgedDifferentlyRunningAndResting() {
        let resting = assess(12.5, running: false).status
        let charging = assess(12.5, running: true).status
        XCTAssertEqual(resting, .normal, "12.5 V at rest is a healthy battery")
        XCTAssertNotEqual(charging, .normal, "12.5 V while running is not a charging voltage")
    }

    func testAnUnknownEngineStateIsTreatedAsRunning() {
        // The common case while an adapter is connected. Assuming resting would report a
        // perfectly good charging voltage as an over-voltage.
        XCTAssertEqual(assess(13.8, running: nil).status, assess(13.8, running: true).status)
    }

    func testAVeryLowRestingVoltageIsNotSoftened() {
        XCTAssertGreaterThan(assess(11.4, running: false).status, .watch,
                             "below the profile's critical floor is not a watch")
    }

    // MARK: - Trend

    func testASteadyBaselineIsNotReportedAsATrend() {
        let assessment = assess(12.5, running: false, baseline: baseline(around: 12.5))
        XCTAssertEqual(assessment.status, .normal)
        XCTAssertNil(assessment.detail, "nothing is drifting, so there is nothing to say")
        XCTAssertEqual(assessment.confidence, .high, "an established baseline earns confidence")
    }

    func testAFallingBaselineRaisesAWatchAndExplainsItself() {
        // Roughly 0.03 V per day downward over a month: about -0.9 V across the window.
        let assessment = assess(12.5, running: false, baseline: baseline(around: 12.5, decliningBy: 0.03))
        XCTAssertGreaterThanOrEqual(assessment.status, .watch)
        XCTAssertNotNil(assessment.detail)
        XCTAssertEqual(assessment.detail?.contains("trending"), true)
        // Suggests a test, does not diagnose a battery.
        XCTAssertEqual(assessment.detail?.contains("battery test"), true)
    }

    func testWithoutABaselineConfidenceIsLowerAndNoTrendIsClaimed() {
        let assessment = assess(12.5, running: false, baseline: nil)
        XCTAssertEqual(assessment.confidence, .medium)
        XCTAssertNil(assessment.detail)
    }

    // MARK: - What it must never say

    func testItNeverClaimsAStateOfChargeOrHealth() {
        // Generic OBD gives control module voltage, which is neither. A percentage invented
        // from it would be the most confidently wrong number in the app.
        let assessments = [assess(13.8), assess(12.5, running: false), assess(11.4, running: false),
                           assess(12.5, running: false, baseline: baseline(around: 12.5, decliningBy: 0.03))]
        for assessment in assessments {
            let text = (assessment.headline + " " + (assessment.detail ?? "")).lowercased()
            for forbidden in ["%", "state of charge", "state of health", "battery is failing",
                              "replace the battery", "dead battery"] {
                XCTAssertFalse(text.contains(forbidden),
                               "\(assessment.headline) claims more than voltage can support")
            }
        }
    }

    func testVoltageIsAlwaysShownAsEvidence() {
        let points = assess(13.8).dataPoints
        XCTAssertEqual(points.first?.label, "Voltage")
        XCTAssertEqual(points.first?.formattedValue, "13.80 V")
    }

    func testTheProvenanceOfTheReadingIsCarriedIntoTheEvidence() {
        let assessment = BatteryIntelligence.assess(
            voltage: Provenanced(value: 13.8, provenance: .simulated, timestamp: start),
            isEngineRunning: true,
            baseline: nil,
            profile: harrier)
        XCTAssertEqual(assessment.dataPoints.first?.provenance, .simulated,
                       "a simulated reading must not present as measured")
    }
}
