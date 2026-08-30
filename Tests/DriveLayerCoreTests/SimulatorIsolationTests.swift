import XCTest
@testable import DriveLayerCore

/// Simulated readings used to be stamped `.measured`, which made them indistinguishable
/// from a real Harrier everywhere downstream: baselines, health trends, history, UI.
///
/// The isolation is deliberately narrow. A scenario should still drive the insight rules
/// hard — a hot-coolant scenario has to be able to raise a hot-coolant insight — so what
/// must not happen is simulated data teaching DriveLayer what is *normal* for a car it
/// has never seen.
final class SimulatorIsolationTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func reading(_ metric: VehicleMetric, _ value: Double) -> OBDReading {
        OBDReading(pid: .current(0x05),
                   name: "Test reading",
                   metric: metric,
                   value: .number(value),
                   unitLabel: "",
                   timestamp: start,
                   isPlausible: true)
    }

    // MARK: - The provenance itself

    func testSimulatedDataDoesNotDescribeTheRealVehicle() {
        XCTAssertFalse(DataProvenance.simulated.describesRealVehicle)
        for provenance in DataProvenance.allCases where provenance != .simulated {
            XCTAssertTrue(provenance.describesRealVehicle,
                          "\(provenance) is about the car, whatever else is true of it")
        }
    }

    func testSimulatedDataSaysSoInCopy() {
        XCTAssertEqual(DataProvenance.simulated.label, "Simulated")
        let qualifier = DataProvenance.simulated.userFacingQualifier
        XCTAssertNotNil(qualifier, "a measured value needs no hedge; this one does")
        XCTAssertEqual(qualifier?.contains("not from your car"), true)
    }

    /// Full confidence on purpose: within a scenario the number is exactly what it claims.
    /// The isolation belongs on the learning path, not on the insight path.
    func testSimulatedDataCanStillCarryAConfidentInsight() {
        XCTAssertEqual(DataProvenance.simulated.confidenceCeiling, 1.0)
        XCTAssertEqual(InsightConfidence.ceiling(for: .simulated), .high)
    }

    // MARK: - Telemetry carries its transport

    func testAppliedReadingsKeepTheProvenanceTheyWereGiven() {
        var telemetry = VehicleTelemetry(updatedAt: start)
        telemetry.apply(reading(.coolantTemperatureC, 92), provenance: .simulated)
        XCTAssertEqual(telemetry.entry(.coolantTemperatureC)?.provenance, .simulated)
        XCTAssertEqual(telemetry.value(.coolantTemperatureC), 92, "the value is still the value")
    }

    func testApplyStillDefaultsToMeasuredForRealAdapters() {
        var telemetry = VehicleTelemetry(updatedAt: start)
        telemetry.apply(reading(.coolantTemperatureC, 92))
        XCTAssertEqual(telemetry.entry(.coolantTemperatureC)?.provenance, .measured)
    }

    func testTelemetryKnowsWhenAnythingInItIsSimulated() {
        var real = VehicleTelemetry(updatedAt: start)
        real.apply(reading(.coolantTemperatureC, 92))
        real.apply(reading(.engineRPM, 1_800))
        XCTAssertFalse(real.containsSimulatedData)

        // One synthetic reading is enough to disqualify the whole snapshot: the baseline
        // guard reads this, and a mixed snapshot is not a real observation of anything.
        var mixed = real
        mixed.apply(reading(.vehicleSpeedKmh, 60), provenance: .simulated)
        XCTAssertTrue(mixed.containsSimulatedData)
    }

    func testAnEmptySnapshotIsNotSimulated() {
        XCTAssertFalse(VehicleTelemetry(updatedAt: start).containsSimulatedData)
    }
}
