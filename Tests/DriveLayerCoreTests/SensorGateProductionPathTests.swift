import XCTest
@testable import DriveLayerCore

/// Tests the real admission path, not the gate in isolation.
///
/// `SensorSanity` and `SensorGate` already had thorough unit tests, and they all passed
/// while the types were called from nowhere: the live path ran one stateless range check
/// in `OBDReading.isPlausible` and stored whatever survived it. Unit tests on an unwired
/// component cannot detect that, which is the whole reason this file starts one step
/// earlier - at the raw OBD bytes - and asserts on what comes out of `VehicleTelemetry`.
///
/// Every test here therefore goes:
///
///     raw bytes -> OBDPIDCatalog decode -> VehicleTelemetry.apply -> assertions
///
/// If the gate is ever unwired again, these fail. Tests written against `SensorGate`
/// directly would not.
final class SensorGateProductionPathTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Decodes through the real catalog, exactly as the poll loop does.
    private func reading(_ code: UInt8, _ bytes: [UInt8], at timestamp: Date) throws -> OBDReading {
        let descriptor = try XCTUnwrap(OBDPIDCatalog.descriptor(for: OBDPID(mode: .currentData, code: code)),
                                       "PID \(code) is missing from the catalog")
        return try descriptor.makeReading(from: bytes, at: timestamp)
    }

    private func plausibleRange(_ code: UInt8) -> ClosedRange<Double>? {
        OBDPIDCatalog.descriptor(for: OBDPID(mode: .currentData, code: code))?.plausibleRange
    }

    /// Feeds a reading the way the connection manager does, range included.
    private func apply(_ reading: OBDReading,
                       code: UInt8,
                       to telemetry: inout VehicleTelemetry) -> VehicleTelemetry.SensorAdmission {
        telemetry.apply(reading, plausibleRange: plausibleRange(code))
    }

    /// A corrupt coolant frame. Forged rather than decoded because no single byte decodes
    /// to 500 C - which is the point: this is what a dropped byte looks like.
    private func corruptCoolant(at timestamp: Date) -> OBDReading {
        OBDReading(pid: OBDPID(mode: .currentData, code: 0x05),
                   name: "Coolant temperature",
                   metric: .coolantTemperatureC,
                   value: .number(500),
                   unitLabel: "C",
                   timestamp: timestamp,
                   isPlausible: false)
    }

    // MARK: - The headline case from the brief

    /// Coolant 500 C, repeated ten times, must never be accepted.
    ///
    /// PID 05 is `A - 40`, so 500 C is unreachable in one byte - the sensor physically
    /// cannot report it. The interesting half is the repetition: `SensorGate` yields to a
    /// persistent value after three rejections, and the reason it does not here is that
    /// `Rejection.mayYieldToPersistence` is false for an out-of-range value. Repetition is
    /// evidence of a broken sensor, not of a hot engine.
    func testCoolantOutsideRangeIsNeverAcceptedHoweverOftenItRepeats() throws {
        var telemetry = VehicleTelemetry(updatedAt: start)

        // A believable reading first, so there is something good to protect.
        let good = try reading(0x05, [130], at: start)           // 130 - 40 = 90 C
        XCTAssertEqual(apply(good, code: 0x05, to: &telemetry).acceptedValue, 90)

        for index in 1...10 {
            let admission = telemetry.apply(corruptCoolant(at: start.addingTimeInterval(Double(index))),
                                            plausibleRange: plausibleRange(0x05))
            XCTAssertFalse(admission.wasAccepted, "500 C was accepted on repeat \(index)")
            XCTAssertEqual(telemetry.value(.coolantTemperatureC), 90,
                           "the last good value should still stand on repeat \(index)")
        }

        // Never stored, and never turned into a zero either.
        XCTAssertEqual(telemetry.value(.coolantTemperatureC), 90)
        XCTAssertEqual(telemetry.quality(.coolantTemperatureC), .suspect)
        XCTAssertNotNil(telemetry.rejectionReason(.coolantTemperatureC))
    }

    // MARK: - A rejected reading reaches nothing downstream

    /// The rejection must not reach the stored sample, which is what feeds the trip, the
    /// baselines and history. Asserting on `sample(at:)` rather than on an internal flag
    /// is deliberate: this is the object that actually travels downstream.
    func testARejectedReadingNeverReachesTheStoredSample() throws {
        var telemetry = VehicleTelemetry(updatedAt: start)

        let good = try reading(0x05, [130], at: start)
        _ = apply(good, code: 0x05, to: &telemetry)
        _ = telemetry.apply(corruptCoolant(at: start.addingTimeInterval(1)),
                            plausibleRange: plausibleRange(0x05))

        let sample = telemetry.sample(at: start.addingTimeInterval(1))
        XCTAssertEqual(sample[.coolantTemperatureC], 90, "the impossible value must not be stored")
    }

    /// A metric whose very first reading is rejected must stay absent - not present as 0.
    /// This is the failure mode `SensorSanity`'s own documentation calls out: a coolant
    /// sensor dropping out becoming "engine ice cold".
    func testAFirstReadingThatIsRejectedLeavesTheMetricAbsentRatherThanZero() {
        var telemetry = VehicleTelemetry(updatedAt: start)

        let admission = telemetry.apply(corruptCoolant(at: start), plausibleRange: plausibleRange(0x05))

        XCTAssertFalse(admission.wasAccepted)
        XCTAssertNil(telemetry.value(.coolantTemperatureC), "absent, not zero")
        XCTAssertFalse(telemetry.availableMetrics.contains(.coolantTemperatureC))
        XCTAssertEqual(telemetry.quality(.coolantTemperatureC), .unavailable)
        XCTAssertNil(telemetry.sample(at: start)[.coolantTemperatureC])
    }

    // MARK: - Rate of change, through the real decoder

    /// A jump of 80 C in one second is a corrupt frame, and both endpoints decode from
    /// real bytes - so this is the gate working on data the catalog produced.
    func testAnImpossibleTemperatureJumpIsRejectedThenYieldsWhenItPersists() throws {
        var telemetry = VehicleTelemetry(updatedAt: start)

        let cool = try reading(0x05, [80], at: start)             // 40 C
        XCTAssertEqual(apply(cool, code: 0x05, to: &telemetry).acceptedValue, 40)

        // 160 - 40 = 120 C, one second later. In range for the sensor, impossible for the
        // engine: 80 C/s against a 5 C/s limit.
        let jump = try reading(0x05, [160], at: start.addingTimeInterval(1))
        XCTAssertFalse(apply(jump, code: 0x05, to: &telemetry).wasAccepted,
                       "an 80 C jump in one second is a bad frame")
        XCTAssertEqual(telemetry.value(.coolantTemperatureC), 40)

        // But if it keeps saying 120, the limit is what is wrong. Unlike an out-of-range
        // value, an impossible rate may yield - that is the one rejection which should.
        let second = try reading(0x05, [160], at: start.addingTimeInterval(2))
        XCTAssertFalse(apply(second, code: 0x05, to: &telemetry).wasAccepted)
        let third = try reading(0x05, [160], at: start.addingTimeInterval(3))
        XCTAssertEqual(apply(third, code: 0x05, to: &telemetry).acceptedValue, 120,
                       "a persistent in-range value should eventually be believed")
        XCTAssertEqual(telemetry.quality(.coolantTemperatureC), .good)
    }

    // MARK: - Sensor defaults

    /// Zero rpm while the engine is running is what the sensor sends when it has nothing.
    /// The engine-running judgement comes from voltage already in telemetry, never from
    /// the reading under test.
    func testZeroRPMIsRejectedAsASensorDefaultWhileTheEngineRuns() throws {
        var telemetry = VehicleTelemetry(updatedAt: start)

        // 14.2 V: the charging system is running, so the engine is.
        let voltage = try reading(0x42, [0x37, 0x78], at: start)
        XCTAssertEqual(apply(voltage, code: 0x42, to: &telemetry).acceptedValue, 14.2)
        XCTAssertEqual(telemetry.isEngineRunning(now: start), true)

        // 0 rpm from a running engine is not a measurement.
        let zeroRPM = try reading(0x0C, [0x00, 0x00], at: start.addingTimeInterval(1))
        let admission = telemetry.apply(zeroRPM,
                                        plausibleRange: plausibleRange(0x0C),
                                        now: start.addingTimeInterval(1))

        XCTAssertEqual(admission, .rejected(.sensorDefault))
        XCTAssertNil(telemetry.value(.engineRPM), "0 rpm must not be stored as a reading")
    }

    /// The same zero is legitimate with the engine off, and must be accepted. A gate that
    /// rejected this would be lying in the other direction.
    func testZeroRPMIsAcceptedWhenNothingSaysTheEngineIsRunning() throws {
        var telemetry = VehicleTelemetry(updatedAt: start)

        let zeroRPM = try reading(0x0C, [0x00, 0x00], at: start)

        XCTAssertEqual(apply(zeroRPM, code: 0x0C, to: &telemetry).acceptedValue, 0,
                       "a stationary engine really does report 0 rpm")
        XCTAssertEqual(telemetry.value(.engineRPM), 0)
    }

    // MARK: - Staleness

    /// An adapter that keeps returning the last frame after the ECU stops answering.
    /// The values are byte-identical and in range, so only the staleness window catches it.
    func testAValueRepeatingPastItsStalenessWindowIsRejected() throws {
        var telemetry = VehicleTelemetry(updatedAt: start)

        let first = try reading(0x0C, [0x0F, 0xA0], at: start)     // 4000/4 = 1000 rpm
        XCTAssertEqual(apply(first, code: 0x0C, to: &telemetry).acceptedValue, 1000)

        // The same bytes 31 s later, past the 30 s window for a fast-moving metric.
        let repeated = try reading(0x0C, [0x0F, 0xA0], at: start.addingTimeInterval(31))
        let admission = apply(repeated, code: 0x0C, to: &telemetry)

        XCTAssertFalse(admission.wasAccepted,
                       "an unchanging rpm for 31 s is the adapter repeating itself")
        if case let .rejected(reason) = admission {
            XCTAssertFalse(reason.mayYieldToPersistence,
                           "a stale reading must never be believed through repetition")
        } else {
            XCTFail("expected a staleness rejection, got \(admission)")
        }
    }

    /// Fuel level has no staleness window on purpose: a full tank on a short drive is not
    /// a fault. Asserting it keeps the table in `staleAfter(for:)` honest.
    func testFuelLevelMayRepeatIndefinitely() throws {
        var telemetry = VehicleTelemetry(updatedAt: start)

        let first = try reading(0x2F, [128], at: start)
        let firstValue = apply(first, code: 0x2F, to: &telemetry).acceptedValue
        XCTAssertNotNil(firstValue)

        let later = try reading(0x2F, [128], at: start.addingTimeInterval(600))
        XCTAssertEqual(apply(later, code: 0x2F, to: &telemetry).acceptedValue, firstValue,
                       "a steady fuel level is the sensor working")
    }

    // MARK: - Gate state is per metric and persists

    /// One gate per metric, kept across readings. A shared or per-reading gate would let
    /// one metric's history judge another's rate of change.
    func testGatesAreIndependentPerMetric() throws {
        var telemetry = VehicleTelemetry(updatedAt: start)

        let coolant = try reading(0x05, [130], at: start)          // 90 C
        _ = apply(coolant, code: 0x05, to: &telemetry)
        let rpm = try reading(0x0C, [0x0F, 0xA0], at: start)       // 1000 rpm
        _ = apply(rpm, code: 0x0C, to: &telemetry)

        // An rpm change no temperature could survive, which is normal for an engine.
        let revving = try reading(0x0C, [0x1F, 0x40], at: start.addingTimeInterval(1)) // 2000 rpm
        XCTAssertEqual(apply(revving, code: 0x0C, to: &telemetry).acceptedValue, 2000,
                       "1000 rpm in a second is ordinary driving")
        XCTAssertEqual(telemetry.value(.coolantTemperatureC), 90, "coolant must be untouched")
    }

    /// Resetting forgets history, so a new adapter does not inherit the last car's
    /// baseline. Without this the first reading from a different vehicle is judged against
    /// a value that has nothing to do with it.
    func testResettingGatesForgetsHistory() throws {
        var telemetry = VehicleTelemetry(updatedAt: start)

        let cool = try reading(0x05, [80], at: start)              // 40 C
        _ = apply(cool, code: 0x05, to: &telemetry)

        telemetry.resetSensorGates()

        // Would have been an impossible jump against the 40 C above.
        let hot = try reading(0x05, [160], at: start.addingTimeInterval(1)) // 120 C
        XCTAssertEqual(apply(hot, code: 0x05, to: &telemetry).acceptedValue, 120,
                       "with no history there is no rate of change to violate")
    }

    // MARK: - Simulated data keeps its provenance through the gate

    /// The gate must not launder provenance: a simulated reading that passes every check is
    /// still simulated, and P0-10 depends on that holding.
    func testSimulatedReadingsKeepTheirProvenanceThroughTheGate() throws {
        var telemetry = VehicleTelemetry(updatedAt: start)

        let coolant = try reading(0x05, [130], at: start)
        let admission = telemetry.apply(coolant,
                                        provenance: .simulated,
                                        plausibleRange: plausibleRange(0x05))

        XCTAssertEqual(admission.acceptedValue, 90)
        XCTAssertTrue(telemetry.containsSimulatedData)
        XCTAssertEqual(telemetry.provenanced(.coolantTemperatureC).provenance, .simulated)
    }
}
