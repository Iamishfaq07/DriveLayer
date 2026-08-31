import XCTest
@testable import DriveLayerCore

/// PID 03 had no descriptor at all, so the fuel system state was not read.
///
/// It matters more than its own section suggests: fuel trims only describe anything while
/// the engine is running closed loop on oxygen sensor feedback. Reading them during a cold
/// start or at high load, and comparing them to a baseline, would turn a normal operating
/// mode into an invented problem. This decodes first so that never happens.
final class FuelSystemStatusTests: XCTestCase {

    // MARK: - J1979 bit encoding

    func testEachDefinedBitDecodesToItsState() {
        XCTAssertEqual(FuelSystemStatus.decode(statusByte: 0x01), .openLoopInsufficientTemperature)
        XCTAssertEqual(FuelSystemStatus.decode(statusByte: 0x02), .closedLoop)
        XCTAssertEqual(FuelSystemStatus.decode(statusByte: 0x04), .openLoopEngineLoad)
        XCTAssertEqual(FuelSystemStatus.decode(statusByte: 0x08), .openLoopSystemFailure)
        XCTAssertEqual(FuelSystemStatus.decode(statusByte: 0x10), .closedLoopWithFault)
    }

    func testNothingReportedIsUnknownRatherThanAState() {
        XCTAssertEqual(FuelSystemStatus.decode(statusByte: 0x00), .unknown)
    }

    /// Only one bit may be set. A byte with several is an adapter or an ECU answering
    /// badly, and choosing which bit was meant is how a bad frame becomes a diagnosis.
    func testSeveralBitsAtOnceIsRefusedRatherThanGuessedAt() {
        XCTAssertEqual(FuelSystemStatus.decode(statusByte: 0x03), .unknown)
        XCTAssertEqual(FuelSystemStatus.decode(statusByte: 0x06), .unknown)
        XCTAssertEqual(FuelSystemStatus.decode(statusByte: 0xFF), .unknown)
    }

    func testUndefinedBitsAreUnknown() {
        // 0x20, 0x40 and 0x80 are single bits with no meaning assigned in J1979.
        for byte: UInt8 in [0x20, 0x40, 0x80] {
            XCTAssertEqual(FuelSystemStatus.decode(statusByte: byte), .unknown,
                           "0x\(String(byte, radix: 16)) has no defined meaning")
        }
    }

    // MARK: - Travelling through telemetry as a number

    func testTheCodeSurvivesTheRoundTripThroughNumericTelemetry() {
        // The path that actually matters: the catalog decodes to a Double, telemetry stores
        // a Double, and the meaning is reconstructed at the point of use.
        XCTAssertEqual(FuelSystemStatus.decode(code: 1), .openLoopInsufficientTemperature)
        XCTAssertEqual(FuelSystemStatus.decode(code: 2), .closedLoop)
        XCTAssertEqual(FuelSystemStatus.decode(code: 4), .openLoopEngineLoad)
        XCTAssertEqual(FuelSystemStatus.decode(code: 8), .openLoopSystemFailure)
        XCTAssertEqual(FuelSystemStatus.decode(code: 16), .closedLoopWithFault)
    }

    func testANonIntegralOrOutOfRangeCodeIsUnknown() {
        XCTAssertEqual(FuelSystemStatus.decode(code: 2.5), .unknown)
        XCTAssertEqual(FuelSystemStatus.decode(code: -1), .unknown)
        XCTAssertEqual(FuelSystemStatus.decode(code: 999), .unknown)
    }

    // MARK: - What the state permits

    func testOnlyCleanClosedLoopPermitsAFuelTrimComparison() {
        XCTAssertTrue(FuelSystemStatus.closedLoop.allowsFuelTrimComparison)

        // Closed loop with a faulty sensor is still closed loop, but the correction is a
        // response to a broken input -- folding it into the baseline would poison what
        // normal means with the very fault it should help spot.
        XCTAssertTrue(FuelSystemStatus.closedLoopWithFault.isClosedLoop)
        XCTAssertFalse(FuelSystemStatus.closedLoopWithFault.allowsFuelTrimComparison)

        for status in [FuelSystemStatus.openLoopInsufficientTemperature,
                       .openLoopEngineLoad,
                       .openLoopSystemFailure,
                       .unknown] {
            XCTAssertFalse(status.isClosedLoop, "\(status) is not closed loop")
            XCTAssertFalse(status.allowsFuelTrimComparison, "\(status) must not be compared")
        }
    }

    // MARK: - How it reads to a driver

    func testANormalOperatingModeIsNotReportedAsAProblem() {
        // Warming up and backing off the throttle are both open loop, and both entirely
        // normal. Only the two states that indicate a fault are worth a watch.
        XCTAssertEqual(FuelSystemStatus.openLoopInsufficientTemperature.status, .normal)
        XCTAssertEqual(FuelSystemStatus.openLoopEngineLoad.status, .normal)
        XCTAssertEqual(FuelSystemStatus.closedLoop.status, .normal)
        XCTAssertEqual(FuelSystemStatus.openLoopSystemFailure.status, .watch)
        XCTAssertEqual(FuelSystemStatus.closedLoopWithFault.status, .watch)
        XCTAssertEqual(FuelSystemStatus.unknown.status, .unknown)
    }

    func testNoStateEverEscalatesPastAWatch() {
        for status in FuelSystemStatus.allCases {
            XCTAssertLessThanOrEqual(status.status, .watch,
                                     "\(status) escalated past a watch on a loop state alone")
        }
    }

    func testEveryStateExplainsItselfInPlainLanguage() {
        for status in FuelSystemStatus.allCases {
            XCTAssertFalse(status.displayName.isEmpty)
            XCTAssertFalse(status.detail.isEmpty)
            // No diagnosis in the copy, whatever the state.
            for forbidden in ["broken", "replace", "failed injector", "faulty pump"] {
                XCTAssertFalse(status.detail.lowercased().contains(forbidden),
                               "\(status) reads as a diagnosis")
            }
        }
    }

    // MARK: - The catalog entry

    func testThePIDIsInTheCatalogAndMappedToItsMetric() throws {
        let descriptor = try XCTUnwrap(OBDPIDCatalog.descriptor(for: .current(0x03)),
                                       "PID 03 used to be absent from the catalog entirely")
        XCTAssertEqual(descriptor.metric, .fuelSystemStatusCode)
        XCTAssertEqual(descriptor.expectedByteCount, 2, "one status byte per fuel system")
    }

    func testTheCatalogDecodesTheFirstSystemsByte() throws {
        let descriptor = try XCTUnwrap(OBDPIDCatalog.descriptor(for: .current(0x03)))
        // Closed loop on system 1, nothing on system 2, which is a single-bank engine.
        guard case let .number(code) = try descriptor.decode([0x02, 0x00]) else {
            return XCTFail("expected a numeric code")
        }
        XCTAssertEqual(FuelSystemStatus.decode(code: code), .closedLoop)
    }
}
