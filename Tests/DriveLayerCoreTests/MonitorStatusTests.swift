import XCTest
@testable import DriveLayerCore

/// PID 01 decoded straight to a display string with no metric, so nothing downstream could
/// act on it. That is why stored codes were read on connect and on demand only: a string
/// cannot be compared against the previous reading, so nothing could notice a lamp coming
/// on mid-drive.
final class MonitorStatusTests: XCTestCase {

    // MARK: - The lamp byte

    func testTheLampBitAndCountAreReadSeparately() {
        // 0x83: bit 7 set, low bits 3.
        let status = MonitorStatus.decode(lampByte: 0x83)
        XCTAssertTrue(status.isWarningLampOn)
        XCTAssertEqual(status.confirmedFaultCount, 3)
    }

    func testACleanCarReportsNeitherLampNorCodes() {
        let status = MonitorStatus.decode(lampByte: 0x00)
        XCTAssertFalse(status.isWarningLampOn)
        XCTAssertEqual(status.confirmedFaultCount, 0)
    }

    func testStoredCodesWithoutALampArePossible() {
        // A fault that has not recurred: codes stored, lamp extinguished.
        let status = MonitorStatus.decode(lampByte: 0x02)
        XCTAssertFalse(status.isWarningLampOn)
        XCTAssertEqual(status.confirmedFaultCount, 2)
        XCTAssertEqual(status.status, .watch, "worth noting, not worth a warning light")
    }

    func testTheCountUsesSevenBitsNotEight() {
        // 0xFF would be 127 codes with the lamp on, not 255.
        let status = MonitorStatus.decode(lampByte: 0xFF)
        XCTAssertTrue(status.isWarningLampOn)
        XCTAssertEqual(status.confirmedFaultCount, 127)
    }

    func testAnOutOfRangeCodeIsRefused() {
        XCTAssertNil(MonitorStatus.decode(code: -1))
        XCTAssertNil(MonitorStatus.decode(code: 256))
        XCTAssertNil(MonitorStatus.decode(code: 3.5))
    }

    // MARK: - Readiness

    /// A test that is not supported is not outstanding — it does not exist. Counting
    /// unsupported monitors as incomplete would report every car as permanently unready.
    func testUnsupportedMonitorsAreNotCountedAsIncomplete() throws {
        // Byte B: no continuous monitors supported. C: no non-continuous supported.
        let status = try XCTUnwrap(MonitorStatus.decode(bytes: [0x00, 0x00, 0x00, 0xFF]))
        let readiness = try XCTUnwrap(status.readiness)
        XCTAssertEqual(readiness.supportedCount, 0)
        XCTAssertEqual(readiness.completeCount, 0)
        XCTAssertNil(readiness.fraction, "nothing supported means no fraction to report")
    }

    func testSupportedAndFinishedMonitorsCountAsComplete() throws {
        // Byte B: three continuous monitors supported (0x07), none incomplete.
        // Byte C: one non-continuous supported (0x01), byte D: not incomplete.
        let status = try XCTUnwrap(MonitorStatus.decode(bytes: [0x00, 0x07, 0x01, 0x00]))
        let readiness = try XCTUnwrap(status.readiness)
        XCTAssertEqual(readiness.supportedCount, 4)
        XCTAssertEqual(readiness.completeCount, 4)
        XCTAssertTrue(readiness.isComplete)
    }

    func testOutstandingMonitorsAreCounted() throws {
        // Byte B: three supported, and the middle one flagged incomplete (bit 5 = 0x20).
        let status = try XCTUnwrap(MonitorStatus.decode(bytes: [0x00, 0x27, 0x00, 0x00]))
        let readiness = try XCTUnwrap(status.readiness)
        XCTAssertEqual(readiness.supportedCount, 3)
        XCTAssertEqual(readiness.completeCount, 2)
        XCTAssertFalse(readiness.isComplete)
    }

    /// The distinction that matters after a battery disconnect: no faults stored because
    /// the car has not finished looking is not a clean bill of health.
    func testAnIncompleteSelfTestWithNoFaultsIsUnknownRatherThanNormal() throws {
        let status = try XCTUnwrap(MonitorStatus.decode(bytes: [0x00, 0x27, 0x00, 0x00]))
        XCTAssertEqual(status.status, .unknown)
        XCTAssertTrue(status.detail.contains("not finished its self-tests"))
    }

    func testACompleteSelfTestWithNoFaultsIsNormal() throws {
        let status = try XCTUnwrap(MonitorStatus.decode(bytes: [0x00, 0x07, 0x00, 0x00]))
        XCTAssertEqual(status.status, .normal)
    }

    func testAShortFrameIsRefusedRatherThanPartiallyRead() {
        XCTAssertNil(MonitorStatus.decode(bytes: [0x83, 0x07]))
        XCTAssertNil(MonitorStatus.decode(bytes: []))
    }

    func testTheLampByteDecodeCarriesNoReadinessClaim() {
        // Assembled from the telemetry path, which carries one number, so it knows the lamp
        // and the count and honestly does not know readiness.
        XCTAssertNil(MonitorStatus.decode(lampByte: 0x83).readiness)
    }

    // MARK: - How it reads

    func testTheLampIsAttentionAndNotCritical() {
        // Have this looked at, not stop the car. DriveLayer is not in a position to know
        // which, so it does not claim to.
        XCTAssertEqual(MonitorStatus.decode(lampByte: 0x81).status, .attention)
    }

    func testEveryStateExplainsItselfWithoutDiagnosing() throws {
        let cases = [MonitorStatus.decode(lampByte: 0x00),
                     MonitorStatus.decode(lampByte: 0x02),
                     MonitorStatus.decode(lampByte: 0x83),
                     try XCTUnwrap(MonitorStatus.decode(bytes: [0x00, 0x27, 0x00, 0x00]))]
        for status in cases {
            XCTAssertFalse(status.displayName.isEmpty)
            XCTAssertFalse(status.detail.isEmpty)
            for forbidden in ["you must", "broken", "replace the"] {
                XCTAssertFalse(status.detail.lowercased().contains(forbidden),
                               "\(status.displayName) reads as an instruction")
            }
        }
    }

    func testTheDisplayNameCountsCodesInPlainLanguage() {
        XCTAssertEqual(MonitorStatus.decode(lampByte: 0x00).displayName, "No warning light")
        XCTAssertEqual(MonitorStatus.decode(lampByte: 0x01).displayName,
                       "No warning light, 1 stored code")
        XCTAssertEqual(MonitorStatus.decode(lampByte: 0x83).displayName,
                       "Check engine light on, 3 stored codes")
    }
}
