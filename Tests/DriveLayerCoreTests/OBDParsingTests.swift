import XCTest
@testable import DriveLayerCore

/// The parser is where a cheap adapter's bad day becomes either a handled error or a
/// wrong number on a driver's screen, so it gets the most hostile tests in the suite.
final class OBDResponseParserTests: XCTestCase {

    private let rpmPID = OBDPID.current(0x0C)

    func testParsesSimpleResponse() throws {
        let response = try OBDResponseParser.parse(raw: "41 0C 1A F8\r\r>", for: rpmPID)
        XCTAssertEqual(response.data, [0x1A, 0xF8])
        XCTAssertEqual(response.additionalResponderCount, 0)
    }

    func testStripsCommandEchoAndSearchingChatter() throws {
        let raw = "010C\rSEARCHING...\r41 0C 1A F8\r\r>"
        let response = try OBDResponseParser.parse(raw: raw, for: rpmPID)
        XCTAssertEqual(response.data, [0x1A, 0xF8])
    }

    func testStripsCanHeaderAndSingleFrameLength() throws {
        let response = try OBDResponseParser.parse(raw: "7E8 04 41 0C 1A F8 00 00\r\r>", for: rpmPID)
        XCTAssertEqual(response.data, [0x1A, 0xF8], "padding after the declared length must be dropped")
    }

    func testParsesResponseWithSpacesDisabled() throws {
        let response = try OBDResponseParser.parse(raw: "410C1AF8\r>", for: rpmPID)
        XCTAssertEqual(response.data, [0x1A, 0xF8])
    }

    func testCountsAdditionalResponders() throws {
        let response = try OBDResponseParser.parse(raw: "41 05 5A\r41 05 5B\r\r>", for: .current(0x05))
        XCTAssertEqual(response.data, [0x5A])
        XCTAssertEqual(response.additionalResponderCount, 1)
    }

    func testAssemblesMultiFrameResponse() throws {
        let raw = """
        014\r0: 49 02 01 31 44 34\r1: 47 50 30 30 52 35\r2: 35 42 31 32 33 34 35 36\r\r>
        """
        let response = try OBDResponseParser.parse(raw: raw, for: OBDPID(mode: .vehicleInformation, code: 0x02))
        XCTAssertEqual(response.fullBytes.count, 20, "the declared length header must truncate padding")
        XCTAssertEqual(response.fullBytes.prefix(3), [0x49, 0x02, 0x01])
    }

    // MARK: - Failure modes

    func testNoDataThrows() {
        XCTAssertThrowsError(try OBDResponseParser.parse(raw: "NO DATA\r\r>", for: rpmPID)) { error in
            XCTAssertEqual(error as? OBDError, .noData)
        }
    }

    func testUnrecognisedCommandThrows() {
        XCTAssertThrowsError(try OBDResponseParser.parse(raw: "?\r\r>", for: rpmPID)) { error in
            XCTAssertEqual(error as? OBDError, .unrecognisedCommand)
        }
    }

    func testBufferFullThrows() {
        XCTAssertThrowsError(try OBDResponseParser.parse(raw: "BUFFER FULL\r>", for: rpmPID)) { error in
            XCTAssertEqual(error as? OBDError, .bufferFull)
        }
    }

    func testNegativeResponseThrowsWithReason() {
        XCTAssertThrowsError(try OBDResponseParser.parse(raw: "7F 01 12\r>", for: rpmPID)) { error in
            XCTAssertEqual(error as? OBDError, .negativeResponse(mode: 0x01, code: 0x12))
        }
    }

    func testMismatchedPIDThrowsRatherThanReturningWrongValue() {
        XCTAssertThrowsError(try OBDResponseParser.parse(raw: "41 0D 40\r>", for: rpmPID)) { error in
            guard case .mismatchedResponse = (error as? OBDError) else {
                return XCTFail("expected a mismatch, got \(error)")
            }
        }
    }

    func testNonHexTokenThrows() {
        XCTAssertThrowsError(try OBDResponseParser.parse(raw: "41 ZZ 00 00\r>", for: rpmPID)) { error in
            guard case .malformedResponse = (error as? OBDError) else {
                return XCTFail("expected malformed response, got \(error)")
            }
        }
    }

    func testEmptyReplyIsTimeoutNotZero() {
        XCTAssertThrowsError(try OBDResponseParser.parse(raw: "\r\r>", for: rpmPID)) { error in
            XCTAssertEqual(error as? OBDError, .timeout)
        }
    }

    func testFrameClaimingMoreBytesThanItCarriesThrows() {
        XCTAssertThrowsError(try OBDResponseParser.bytes(fromLine: "06 41 0C")) { error in
            guard case .malformedResponse = (error as? OBDError) else {
                return XCTFail("expected malformed response, got \(error)")
            }
        }
    }

    func testOddLengthContinuousHexThrows() {
        XCTAssertThrowsError(try OBDResponseParser.bytes(fromLine: "410C1A F"))
    }
}

final class OBDPIDDecodingTests: XCTestCase {

    private func decode(_ code: UInt8, _ bytes: [UInt8]) throws -> OBDReading {
        let descriptor = try XCTUnwrap(OBDPIDCatalog.descriptor(for: .current(code)))
        return try descriptor.makeReading(from: bytes, at: Date())
    }

    func testEngineSpeed() throws {
        XCTAssertEqual(try decode(0x0C, [0x1A, 0xF8]).numericValue ?? 0, 1_726, accuracy: 0.001)
    }

    func testCoolantTemperatureAppliesOffset() throws {
        XCTAssertEqual(try decode(0x05, [0x7B]).numericValue ?? 0, 83, accuracy: 0.001)
    }

    func testSubZeroTemperatureDecodesNegative() throws {
        XCTAssertEqual(try decode(0x05, [0x14]).numericValue ?? 0, -20, accuracy: 0.001)
    }

    func testEngineLoadPercentage() throws {
        XCTAssertEqual(try decode(0x04, [0xFF]).numericValue ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(try decode(0x04, [0x00]).numericValue ?? 0, 0, accuracy: 0.001)
    }

    func testControlModuleVoltage() throws {
        XCTAssertEqual(try decode(0x42, [0x31, 0x0E]).numericValue ?? 0, 12.558, accuracy: 0.0001)
    }

    func testFuelRate() throws {
        XCTAssertEqual(try decode(0x5E, [0x00, 0x64]).numericValue ?? 0, 5.0, accuracy: 0.001)
    }

    func testTimingAdvanceCanBeNegative() throws {
        XCTAssertEqual(try decode(0x0E, [0x00]).numericValue ?? 0, -64, accuracy: 0.001)
    }

    func testMonitorStatusReportsWarningLamp() throws {
        let reading = try decode(0x01, [0x83, 0x07, 0xE5, 0x00])
        XCTAssertEqual(reading.value, .text("MIL on, 3 stored"))
    }

    func testShortPayloadThrowsInsteadOfPaddingWithZero() {
        XCTAssertThrowsError(try decode(0x0C, [0x1A])) { error in
            guard case .malformedResponse = (error as? OBDError) else {
                return XCTFail("expected malformed response, got \(error)")
            }
        }
    }

    func testImplausibleValueIsFlaggedNotDiscarded() throws {
        // 0xFF km/h decodes fine but is beyond what the plausibility band allows for
        // a road vehicle; the reading survives, flagged, so baselines can reject it.
        let speed = try decode(0x0D, [0xFF])
        XCTAssertEqual(speed.numericValue ?? 0, 255, accuracy: 0.001)
        XCTAssertTrue(speed.isPlausible, "255 km/h is at the edge of the band but still inside it")

        let rpm = try decode(0x0C, [0xFF, 0xFF])
        XCTAssertEqual(rpm.numericValue ?? 0, 16_383.75, accuracy: 0.01)
        XCTAssertFalse(rpm.isPlausible, "16,000 rpm cannot be real and must be flagged")
    }

    func testUnknownPIDHasNoDescriptorRatherThanAGuessedOne() {
        // 0x7A is a real standard identifier whose scaling DriveLayer has not verified.
        XCTAssertNil(OBDPIDCatalog.descriptor(for: .current(0x7A)))
        XCTAssertEqual(OBDPIDCatalog.knownUndecodedNames[0x7A], "Diesel particulate filter, bank 1")
    }
}

final class OBDCapabilityTests: XCTestCase {

    func testDecodesWellKnownBitmap() {
        let codes = OBDSupportBitmap.decode(base: 0x00, bytes: [0xBE, 0x1F, 0xA8, 0x13])
        XCTAssertEqual(codes, [0x01, 0x03, 0x04, 0x05, 0x06, 0x07,
                               0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11,
                               0x13, 0x15, 0x1C, 0x1F, 0x20])
    }

    func testBitmapRoundTrips() {
        let original: Set<UInt8> = [0x01, 0x05, 0x0C, 0x0D, 0x1F, 0x20]
        let encoded = OBDSupportBitmap.encode(base: 0x00, codes: original)
        XCTAssertEqual(OBDSupportBitmap.decode(base: 0x00, bytes: encoded), original)
    }

    func testShortBitmapDecodesToNothingRatherThanCrashing() {
        XCTAssertTrue(OBDSupportBitmap.decode(base: 0x00, bytes: [0xBE, 0x1F]).isEmpty)
    }

    func testUnsupportedPIDIsRejectedByReport() {
        let report = OBDCapabilityReport(supportedCodes: [0x0C, 0x0D])
        XCTAssertTrue(report.supports(.current(0x0C)))
        XCTAssertFalse(report.supports(.current(0x05)))
    }

    func testDTCModeSupportDefaultsToUnknownNotFalse() {
        let report = OBDCapabilityReport(supportedCodes: [0x0C])
        XCTAssertEqual(report.storedDTCSupport, .unknown)
        XCTAssertFalse(report.supports(OBDPID(mode: .storedDTCs)))
    }

    func testReportSeparatesDecodableFromMerelyReported() {
        let report = OBDCapabilityReport(supportedCodes: [0x0C, 0x05, 0x7A])
        XCTAssertEqual(report.reportedButNotDecodable, [0x7A])
        XCTAssertTrue(report.availableMetrics.contains(.engineRPM))
        XCTAssertTrue(report.availableMetrics.contains(.coolantTemperatureC))
    }

    /// Records requests from inside a `@Sendable` closure without capturing a local var.
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ value: String) { lock.lock(); items.append(value); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testDiscoveryStopsWhenNextBlockIsNotAdvertised() async {
        // The first block does not set bit 0x20, so no second request should be made.
        let requested = RequestLog()
        let discovery = OBDCapabilityDiscovery { pid in
            requested.append(pid.requestString)
            if pid.mode == .currentData {
                let bytes = OBDSupportBitmap.encode(base: 0x00, codes: [0x0C, 0x0D])
                return OBDResponse(pid: pid, fullBytes: [0x41, 0x00] + bytes, data: bytes,
                                   additionalResponderCount: 0, raw: "")
            }
            throw OBDError.noData
        }
        let report = await discovery.discover()
        XCTAssertTrue(report.supportedCodes.contains(0x0C))
        XCTAssertFalse(requested.all.contains("0120"), "the 0x20 block was never advertised")
        XCTAssertEqual(report.storedDTCSupport, .unknown, "NO DATA on mode 03 is ambiguous")
    }
}
