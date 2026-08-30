import XCTest
@testable import DriveLayerCore

/// The simulator is only worth having if it exercises the real code path, so these
/// tests assert that simulated traffic goes through the production parser, decoders
/// and session — not around them.
final class SimulatorTests: XCTestCase {

    private func makeSession(_ scenario: OBDScenarioID,
                             clock: MutableDateProvider) -> (OBDSession, SimulatedOBDTransport) {
        let transport = SimulatedOBDTransport(scenario: scenario, dateProvider: clock)
        let session = OBDSession(transport: transport, dateProvider: clock)
        return (session, transport)
    }

    func testNormalHighwayDriveProducesPlausibleReadings() async throws {
        let clock = MutableDateProvider(Date(timeIntervalSince1970: 1_700_000_000))
        let (session, _) = makeSession(.normalHighway, clock: clock)
        try await session.start()

        clock.advance(by: 60)
        let rpm = try await session.read(.current(0x0C))
        let speed = try await session.read(.current(0x0D))
        let coolant = try await session.read(.current(0x05))

        XCTAssertTrue(rpm.isPlausible)
        XCTAssertGreaterThan(try XCTUnwrap(rpm.numericValue), 600)
        XCTAssertEqual(try XCTUnwrap(speed.numericValue), 95, accuracy: 6)
        XCTAssertEqual(try XCTUnwrap(coolant.numericValue), 89, accuracy: 8)
    }

    func testCapabilityDiscoveryFindsTheSimulatedVehiclesParameters() async throws {
        let clock = MutableDateProvider(Date())
        let (session, _) = makeSession(.normalHighway, clock: clock)
        try await session.start()

        let report = await session.capabilities
        let capabilities = try XCTUnwrap(report)
        XCTAssertTrue(capabilities.supports(.current(0x0C)))
        XCTAssertTrue(capabilities.supports(.current(0x42)))
        XCTAssertTrue(capabilities.availableMetrics.contains(.fuelLevelPercent))
    }

    func testUnsupportedSensorDisappearsRatherThanReadingZero() async throws {
        let clock = MutableDateProvider(Date())
        let (session, _) = makeSession(.sensorUnavailable, clock: clock)
        try await session.start()

        let report = await session.capabilities
        let capabilities = try XCTUnwrap(report)
        XCTAssertFalse(capabilities.supports(.current(0x05)), "coolant is not reported in this scenario")
        XCTAssertFalse(capabilities.availableMetrics.contains(.coolantTemperatureC))

        do {
            _ = try await session.read(.current(0x05))
            XCTFail("reading an unsupported PID must fail rather than return zero")
        } catch let error as OBDError {
            XCTAssertTrue(error.suggestsUnsupported)
        }
    }

    func testColdStartWarmsUpOverTime() async throws {
        let clock = MutableDateProvider(Date())
        let (session, _) = makeSession(.coldStart, clock: clock)
        try await session.start()

        clock.advance(by: 5)
        let cold = try await session.read(.current(0x05))
        clock.advance(by: 900)
        let warm = try await session.read(.current(0x05))

        let coldValue = try XCTUnwrap(cold.numericValue)
        let warmValue = try XCTUnwrap(warm.numericValue)
        XCTAssertLessThan(coldValue, 30, "a cold start begins near ambient")
        XCTAssertGreaterThan(warmValue, 70, "the engine should reach operating temperature")
    }

    func testHighCoolantScenarioEscalatesPastTheNormalBand() async throws {
        let clock = MutableDateProvider(Date())
        let (session, _) = makeSession(.highCoolantTemperature, clock: clock)
        try await session.start()
        clock.advance(by: 1_800)

        let coolant = try await session.read(.current(0x05))
        let range = try XCTUnwrap(VehicleProfileCatalog.harrier2026AdventureXPlus
            .operatingRange(for: .coolantTemperatureC, condition: .warmedUp))
        XCTAssertGreaterThanOrEqual(range.status(for: try XCTUnwrap(coolant.numericValue)), .attention)
    }

    func testTroubleCodeScenarioRoundTripsThroughTheDecoder() async throws {
        let clock = MutableDateProvider(Date())
        let (session, _) = makeSession(.dpfWarning, clock: clock)
        try await session.start()

        let result = await session.readDiagnosticCodes()
        XCTAssertEqual(result.codes.map(\.code), ["P2002"])
        XCTAssertEqual(result.codes.first?.status, .stored)

        let explanation = DTCCatalog.explanation(for: "P2002")
        XCTAssertFalse(explanation.isGenericFallback)
        XCTAssertEqual(explanation.seriousness, .prompt)
    }

    func testLinkDropSurfacesAsAnErrorAndRecovers() async throws {
        let clock = MutableDateProvider(Date())
        let (session, _) = makeSession(.linkDropAndRecover, clock: clock)
        try await session.start()

        clock.advance(by: 70)
        do {
            _ = try await session.read(.current(0x0C))
            XCTFail("the adapter link is down at this point in the scenario")
        } catch let error as OBDError {
            XCTAssertEqual(error, .connectionLost)
            XCTAssertTrue(error.isTransient)
        }

        clock.advance(by: 60)
        let recovered = try await session.read(.current(0x0C))
        XCTAssertNotNil(recovered.numericValue)
    }

    func testInvalidResponsesNeverBecomeReadings() async throws {
        let clock = MutableDateProvider(Date())
        let transport = SimulatedOBDTransport(scenario: .invalidResponses, dateProvider: clock)
        try await transport.connect()

        var failures = 0
        var successes = 0
        for _ in 0..<6 {
            clock.advance(by: 1)
            let raw = try await transport.send("010C", timeout: 1)
            do {
                let response = try OBDResponseParser.parse(raw: raw, for: .current(0x0C))
                let descriptor = try XCTUnwrap(OBDPIDCatalog.descriptor(for: .current(0x0C)))
                _ = try descriptor.makeReading(from: response.data, at: clock.now)
                successes += 1
            } catch {
                failures += 1
            }
        }
        XCTAssertEqual(failures, 5, "five of the six scripted replies are unusable")
        XCTAssertEqual(successes, 1)
    }

    func testFuelLevelFallsAsTheSimulatedDriveBurnsFuel() async throws {
        let clock = MutableDateProvider(Date())
        let (session, _) = makeSession(.fuelRunningLow, clock: clock)
        try await session.start()

        let start = try await session.read(.current(0x2F))
        clock.advance(by: 3_600)
        let later = try await session.read(.current(0x2F))

        XCTAssertLessThan(try XCTUnwrap(later.numericValue), try XCTUnwrap(start.numericValue))
    }

    func testEveryScenarioHasCatalogueCopy() {
        for id in OBDScenarioID.allCases {
            let scenario = OBDScenario.named(id)
            XCTAssertEqual(scenario.id, id, "scenario \(id.rawValue) is missing from the catalog")
            XCTAssertFalse(scenario.title.isEmpty)
            XCTAssertFalse(scenario.exercises.isEmpty)
        }
        XCTAssertEqual(OBDScenario.all.count, OBDScenarioID.allCases.count)
    }
}

final class DTCTests: XCTestCase {

    func testDecodesCodePair() {
        let code = DTCDecoder.decode(first: 0x01, second: 0x43, status: .stored)
        XCTAssertEqual(code?.code, "P0143")
        XCTAssertEqual(code?.system, .powertrain)
    }

    func testDecodesEachSystemPrefix() {
        XCTAssertEqual(DTCDecoder.decode(first: 0x41, second: 0x00, status: .stored)?.code.prefix(1), "C")
        XCTAssertEqual(DTCDecoder.decode(first: 0x81, second: 0x00, status: .stored)?.code.prefix(1), "B")
        XCTAssertEqual(DTCDecoder.decode(first: 0xC1, second: 0x00, status: .stored)?.code.prefix(1), "U")
    }

    func testPaddingIsNotACode() {
        XCTAssertNil(DTCDecoder.decode(first: 0x00, second: 0x00, status: .stored))
    }

    func testCountByteIsStrippedWhenPresent() {
        let codes = DTCDecoder.decodeList(payload: [0x02, 0x01, 0x43, 0x01, 0x96], status: .stored)
        XCTAssertEqual(codes.map(\.code), ["P0143", "P0196"])
    }

    func testPayloadWithoutCountByteStillDecodes() {
        let codes = DTCDecoder.decodeList(payload: [0x01, 0x43, 0x00, 0x00], status: .pending)
        XCTAssertEqual(codes.map(\.code), ["P0143"])
        XCTAssertEqual(codes.first?.status, .pending)
    }

    func testDuplicateCodesFromSeveralModulesAppearOnce() {
        let codes = DTCDecoder.decodeList(payload: [0x01, 0x43, 0x01, 0x43], status: .stored)
        XCTAssertEqual(codes.count, 1)
    }

    func testEncodeRoundTrips() throws {
        for code in ["P0143", "P2002", "U0100", "C1234", "B0001"] {
            let pair = try XCTUnwrap(DTCDecoder.encode(code))
            XCTAssertEqual(DTCDecoder.decode(first: pair.0, second: pair.1, status: .stored)?.code, code)
        }
    }

    func testEncodeRejectsMalformedCodes() {
        XCTAssertNil(DTCDecoder.encode("P014"))
        XCTAssertNil(DTCDecoder.encode("X0143"))
        XCTAssertNil(DTCDecoder.encode("P9143"), "the first digit cannot exceed 3")
    }

    func testUnknownCodeGetsStructuralExplanationNotAnInvention() {
        let explanation = DTCCatalog.explanation(for: "P0455")
        XCTAssertTrue(explanation.isGenericFallback)
        XCTAssertTrue(explanation.commonSymptoms.isEmpty, "DriveLayer must not invent symptoms")
        XCTAssertEqual(explanation.standardDefinition, "Auxiliary emission controls")
    }

    func testManufacturerSpecificCodeSaysSoRatherThanGuessing() {
        let explanation = DTCCatalog.explanation(for: "P1234")
        XCTAssertTrue(explanation.isGenericFallback)
        XCTAssertTrue(explanation.plainLanguage.contains("manufacturer-specific"))
    }

    func testKnownCodeCarriesRealGuidance() {
        let explanation = DTCCatalog.explanation(for: "P0401")
        XCTAssertFalse(explanation.isGenericFallback)
        XCTAssertFalse(explanation.possibleCauses.isEmpty)
        XCTAssertEqual(explanation.seriousness, .service)
    }
}
