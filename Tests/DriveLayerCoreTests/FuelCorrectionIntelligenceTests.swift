import XCTest
@testable import DriveLayerCore

final class FuelCorrectionIntelligenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func baseline(metric: VehicleMetric) -> MetricBaseline {
        MetricBaseline(key: BaselineKey(metric: metric, context: .cruising),
                       dayCount: 7, observationCount: 70,
                       mean: 2, median: 2, standardDeviation: 1,
                       percentile10: 0, percentile90: 4,
                       trendPerDay: nil, windowDays: 30, updatedAt: now)
    }

    func testOpenLoopNeverInterpretsFuelTrim() {
        XCTAssertNil(FuelCorrectionIntelligence.assess(
            shortTerm: .measured(12, at: now), longTerm: .measured(8, at: now),
            fuelSystem: .openLoopInsufficientTemperature, isWarmedCruise: true,
            shortTermBaseline: baseline(metric: .shortTermFuelTrimPercent),
            longTermBaseline: baseline(metric: .longTermFuelTrimPercent)))
    }

    func testColdOrTransientDrivingNeverInterpretsFuelTrim() {
        XCTAssertNil(FuelCorrectionIntelligence.assess(
            shortTerm: .measured(12, at: now), longTerm: .measured(8, at: now),
            fuelSystem: .closedLoop, isWarmedCruise: false,
            shortTermBaseline: baseline(metric: .shortTermFuelTrimPercent),
            longTermBaseline: baseline(metric: .longTermFuelTrimPercent)))
    }

    func testEstablishedOutlierIsTrendSignalWithEvidenceProvenance() throws {
        let assessment = try XCTUnwrap(FuelCorrectionIntelligence.assess(
            shortTerm: .measured(3, at: now), longTerm: .measured(8, at: now),
            fuelSystem: .closedLoop, isWarmedCruise: true,
            shortTermBaseline: baseline(metric: .shortTermFuelTrimPercent),
            longTermBaseline: baseline(metric: .longTermFuelTrimPercent)))
        XCTAssertEqual(assessment.status, .watch)
        XCTAssertTrue(assessment.detail.contains("not a diagnosis"))
        XCTAssertTrue(assessment.dataPoints.contains { $0.provenance == .measured })
        XCTAssertTrue(assessment.dataPoints.contains { $0.provenance == .learned })
    }
}
