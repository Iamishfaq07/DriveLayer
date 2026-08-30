import XCTest
@testable import DriveLayerCore

/// The brief's test 15: a sensor spike must not create a false critical insight.
final class SensorSanityTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Range and defaults

    func testValueOutsideThePlausibleRangeIsRejected() {
        let verdict = SensorSanity.check(300,
                                         metric: .coolantTemperatureC,
                                         at: start,
                                         plausibleRange: -40...215,
                                         previous: nil)
        XCTAssertEqual(verdict, .rejected(.outsidePlausibleRange(low: -40, high: 215)))
        XCTAssertNil(verdict.value, "and it must not come back as a number at all")
    }

    func testARejectedReadingIsNeverTurnedIntoZero() {
        var gate = SensorGate(metric: .coolantTemperatureC, plausibleRange: -40...215)
        gate.offer(90, at: start)
        XCTAssertNil(gate.offer(400, at: start.addingTimeInterval(1)))

        // The whole point: a dropped sensor must not read as "engine ice cold".
        XCTAssertEqual(gate.current.value, 90, "the last good reading is held")
        XCTAssertNotNil(gate.current.basis, "and the UI is told why it is stale")
    }

    func testRunningEngineAtZeroRPMIsASensorDefaultNotAReading() {
        XCTAssertTrue(SensorSanity.isSensorDefault(0, for: .engineRPM, engineRunning: true))
        XCTAssertFalse(SensorSanity.isSensorDefault(0, for: .engineRPM, engineRunning: false),
                       "a stopped engine really is at zero")
    }

    func testGenuineZeroesAreNotTreatedAsDefaults() {
        // An idling car is really doing 0 km/h and a warm engine really can report 0%
        // fuel trim. Rejecting those would be worse than accepting a false zero.
        XCTAssertFalse(SensorSanity.isSensorDefault(0, for: .vehicleSpeedKmh, engineRunning: true))
        XCTAssertFalse(SensorSanity.isSensorDefault(0, for: .shortTermFuelTrimPercent, engineRunning: true))
        XCTAssertFalse(SensorSanity.isSensorDefault(0, for: .engineLoadPercent, engineRunning: true))
    }

    // MARK: - Rate of change

    func testAnImpossibleJumpIsRejected() {
        let verdict = SensorSanity.check(170,
                                         metric: .coolantTemperatureC,
                                         at: start.addingTimeInterval(1),
                                         plausibleRange: -40...215,
                                         previous: (90, start))
        guard case let .rejected(.impossibleRateOfChange(perSecond, limit)) = verdict else {
            return XCTFail("expected a rate rejection, got \(verdict)")
        }
        XCTAssertEqual(perSecond, 80, accuracy: 0.01)
        XCTAssertEqual(limit, 5)
    }

    func testRealDrivingIsNotFilteredOut() {
        // An engine really does gain 3,000 rpm in a second. Over-smoothing live data is
        // its own kind of dishonesty.
        var gate = SensorGate(metric: .engineRPM, plausibleRange: 0...8_000)
        gate.offer(900, at: start)
        XCTAssertEqual(gate.offer(3_900, at: start.addingTimeInterval(1)), 3_900)
    }

    func testMetricsWithNoUsefulLimitOnlyGetARangeCheck() {
        XCTAssertNil(SensorSanity.maximumRateOfChange(for: .engineLoadPercent))
        var gate = SensorGate(metric: .engineLoadPercent, plausibleRange: 0...100)
        gate.offer(10, at: start)
        XCTAssertEqual(gate.offer(95, at: start.addingTimeInterval(0.5)), 95,
                       "load can genuinely slam from 10% to 95%")
    }

    // MARK: - Yielding

    func testOneSpikeIsIgnoredButAPersistentChangeIsAccepted() {
        var gate = SensorGate(metric: .coolantTemperatureC, plausibleRange: -40...215)
        gate.offer(90, at: start)

        // Three impossible jumps in a row is not a spike: it is the limit being wrong,
        // and a filter that refuses forever has stopped filtering and started lying.
        XCTAssertNil(gate.offer(170, at: start.addingTimeInterval(1)))
        XCTAssertNil(gate.offer(170, at: start.addingTimeInterval(2)))
        XCTAssertEqual(gate.offer(170, at: start.addingTimeInterval(3)), 170)
        XCTAssertEqual(gate.current.value, 170)
        XCTAssertNil(gate.current.basis, "and it is a clean reading again, not a held one")
    }

    func testAcceptedReadingClearsTheRejectionStreak() {
        var gate = SensorGate(metric: .coolantTemperatureC, plausibleRange: -40...215)
        gate.offer(90, at: start)
        XCTAssertNil(gate.offer(400, at: start.addingTimeInterval(1)))
        XCTAssertEqual(gate.consecutiveRejections, 1)
        gate.offer(91, at: start.addingTimeInterval(2))
        XCTAssertEqual(gate.consecutiveRejections, 0)
    }

    /// The gate used to count rejections without looking at why, so three repeats of
    /// anything at all were believed. A coolant sensor reading 500 C is not reporting a
    /// hot engine, it is reporting that it is broken, and repetition is the evidence for
    /// that rather than against it.
    func testAnImpossibleReadingIsNeverAcceptedHoweverOftenItRepeats() {
        var gate = SensorGate(metric: .coolantTemperatureC, plausibleRange: -40...215)
        gate.offer(90, at: start)

        for second in 1...10 {
            XCTAssertNil(gate.offer(500, at: start.addingTimeInterval(Double(second))),
                         "offer \(second) of an out-of-range value was accepted")
        }

        XCTAssertEqual(gate.current.value, 90, "the last good reading still stands")
        XCTAssertNotNil(gate.current.basis, "and the UI is told the newest was rejected")
    }

    func testASensorDefaultIsNeverAcceptedHoweverOftenItRepeats() {
        var gate = SensorGate(metric: .engineRPM, plausibleRange: 0...8_000)
        gate.offer(2_000, at: start)

        // Zero rpm is inside the plausible range, so only the sensor-default rule stands
        // between this and DriveLayer believing a running engine has stopped turning.
        for second in 1...10 {
            XCTAssertNil(gate.offer(0, at: start.addingTimeInterval(Double(second)), engineRunning: true),
                         "offer \(second) of a sensor default was accepted")
        }

        XCTAssertEqual(gate.current.value, 2_000)
    }

    func testAStaleReadingIsHeldRatherThanEventuallyBelievedFresh() {
        var gate = SensorGate(metric: .engineRPM, plausibleRange: 0...8_000, staleAfter: 10)
        gate.offer(2_000, at: start)

        for second in 11...20 {
            XCTAssertNil(gate.offer(2_000, at: start.addingTimeInterval(Double(second))),
                         "a frozen reading must not be re-accepted as a fresh one")
        }

        XCTAssertEqual(gate.current.value, 2_000, "held, with a basis explaining why")
        XCTAssertNotNil(gate.current.basis)
    }

    func testTheStreakStopsClimbingForAReadingThatCanNeverBeAccepted() {
        var gate = SensorGate(metric: .coolantTemperatureC, plausibleRange: -40...215)
        gate.offer(90, at: start)
        for second in 1...50 {
            gate.offer(500, at: start.addingTimeInterval(Double(second)))
        }
        // Capped rather than climbing to fifty: nothing downstream benefits from the
        // difference, and an unbounded counter is a slow-motion overflow.
        XCTAssertEqual(gate.consecutiveRejections, gate.rejectionsBeforeYielding)
    }

    func testOnlyAnImpossibleRateOfChangeMayEverYield() {
        XCTAssertTrue(SensorSanity.Rejection.impossibleRateOfChange(perSecond: 80, limit: 5)
            .mayYieldToPersistence)
        XCTAssertFalse(SensorSanity.Rejection.outsidePlausibleRange(low: -40, high: 215)
            .mayYieldToPersistence)
        XCTAssertFalse(SensorSanity.Rejection.sensorDefault.mayYieldToPersistence)
        XCTAssertFalse(SensorSanity.Rejection.stale(seconds: 30).mayYieldToPersistence)
    }

    // MARK: - Staleness

    func testAnUnchangingValueGoesStale() {
        var gate = SensorGate(metric: .engineRPM, plausibleRange: 0...8_000, staleAfter: 10)
        gate.offer(2_000, at: start)
        XCTAssertNil(gate.offer(2_000, at: start.addingTimeInterval(11)),
                     "an adapter handing back the same number after the ECU stopped "
                     + "answering is not a measurement")
    }

    func testStalenessIsOptOut() {
        var gate = SensorGate(metric: .ambientAirTemperatureC, plausibleRange: -40...60)
        gate.offer(24, at: start)
        XCTAssertEqual(gate.offer(24, at: start.addingTimeInterval(3_600)), 24,
                       "ambient temperature is allowed to sit still for an hour")
    }

    func testUnreadGateHasNoValueRatherThanZero() {
        let gate = SensorGate(metric: .coolantTemperatureC)
        XCTAssertNil(gate.current.value)
        XCTAssertEqual(gate.current.provenance, .unavailable)
    }
}

final class EngineThermalModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func observation(secondsToOperating: TimeInterval,
                            ambientC: Double,
                            at offsetDays: Double) -> WarmUpObservation {
        WarmUpObservation(startedAt: now.addingTimeInterval(-offsetDays * 86_400),
                          secondsToOperating: secondsToOperating,
                          startingCoolantC: 20,
                          ambientC: ambientC,
                          averageRPM: 1_800,
                          distanceKm: 6)
    }

    // MARK: - Phases

    func testNoCoolantReadingIsUnknownNotCold() {
        XCTAssertEqual(EngineThermalModel.phase(coolantC: nil, profile: nil), .unknown)
        let assessment = EngineThermalModel.assess(coolantC: .unavailable(),
                                                   oilC: .unavailable(),
                                                   ambientC: 24,
                                                   runtimeSeconds: 300,
                                                   history: [],
                                                   profile: nil)
        XCTAssertEqual(assessment.phase, .unknown)
        XCTAssertEqual(assessment.confidence, .low)
    }

    func testPhaseBoundaries() {
        XCTAssertEqual(EngineThermalModel.phase(coolantC: 20, profile: nil), .cold)
        XCTAssertEqual(EngineThermalModel.phase(coolantC: 61, profile: nil), .warming)
        XCTAssertEqual(EngineThermalModel.phase(coolantC: 92, profile: nil), .operating)
        XCTAssertEqual(EngineThermalModel.phase(coolantC: 112, profile: nil), .hot)
    }

    func testHotIsAWatchRatherThanNormal() {
        XCTAssertEqual(EngineThermalPhase.hot.status, .watch)
        XCTAssertEqual(EngineThermalPhase.operating.status, .normal)
        XCTAssertEqual(EngineThermalPhase.unknown.status, .unknown)
    }

    func testWarmingDetailMentionsTheWeatherItIsBeingJudgedAgainst() {
        let assessment = EngineThermalModel.assess(coolantC: .measured(61),
                                                   oilC: .unavailable(),
                                                   ambientC: 14,
                                                   runtimeSeconds: 180,
                                                   history: [],
                                                   profile: nil)
        XCTAssertEqual(assessment.phase, .warming)
        XCTAssertTrue(assessment.detail.contains("61"))
        XCTAssertTrue(assessment.detail.contains("14"),
                      "61 degrees means different things in January and July")
    }

    // MARK: - Comparison against this car's own history

    func testNoComparisonUntilThereAreEnoughComparableWarmUps() {
        let history = [observation(secondsToOperating: 300, ambientC: 15, at: 1)]
        let assessment = EngineThermalModel.assess(coolantC: .measured(55),
                                                   oilC: .unavailable(),
                                                   ambientC: 15,
                                                   runtimeSeconds: 600,
                                                   history: history,
                                                   profile: nil)
        XCTAssertNil(assessment.comparison, "one previous warm-up is not a baseline")
        XCTAssertEqual(assessment.confidence, .medium)
    }

    func testASlowWarmUpIsReportedOnceThereIsABaseline() throws {
        let history = (1...6).map { observation(secondsToOperating: 300, ambientC: 15, at: Double($0)) }
        let assessment = EngineThermalModel.assess(coolantC: .measured(55),
                                                   oilC: .unavailable(),
                                                   ambientC: 15,
                                                   runtimeSeconds: 480,
                                                   history: history,
                                                   profile: nil)
        let comparison = try XCTUnwrap(assessment.comparison)
        XCTAssertTrue(comparison.contains("60%"), "480s against a 300s median")
        XCTAssertTrue(comparison.contains("not a fault"),
                      "one slow warm-up must not read as a diagnosis")
    }

    func testAWarmUpWithinTheUsualTimeSaysNothing() {
        let history = (1...6).map { observation(secondsToOperating: 300, ambientC: 15, at: Double($0)) }
        let assessment = EngineThermalModel.assess(coolantC: .measured(55),
                                                   oilC: .unavailable(),
                                                   ambientC: 15,
                                                   runtimeSeconds: 280,
                                                   history: history,
                                                   profile: nil)
        XCTAssertNil(assessment.comparison, "normal is not news")
    }

    func testWinterWarmUpsAreNotComparedAgainstSummerOnes() {
        let summer = (1...6).map { observation(secondsToOperating: 240, ambientC: 34, at: Double($0)) }
        let comparable = EngineThermalModel.comparableObservations(to: 2, in: summer)
        XCTAssertTrue(comparable.isEmpty,
                      "a January start taking longer than a July one is the weather, not a fault")
    }

    func testNeighbouringTemperatureBandsDoCount() {
        let history = (1...6).map { observation(secondsToOperating: 300, ambientC: 16, at: Double($0)) }
        // 16 °C is band 3; 19 °C is also band 3, and 12 °C is band 2 - within one.
        XCTAssertEqual(EngineThermalModel.comparableObservations(to: 19, in: history).count, 6)
        XCTAssertEqual(EngineThermalModel.comparableObservations(to: 12, in: history).count, 6)
        XCTAssertEqual(EngineThermalModel.comparableObservations(to: 40, in: history).count, 0)
    }

    func testObservationsWithoutAnAmbientReadingAreNotComparable() {
        let blind = [WarmUpObservation(startedAt: now, secondsToOperating: 300,
                                       startingCoolantC: 20, ambientC: nil,
                                       averageRPM: nil, distanceKm: nil)]
        XCTAssertTrue(EngineThermalModel.comparableObservations(to: 15, in: blind).isEmpty)
    }

    // MARK: - Recording

    func testTheSameWarmUpOfferedTwiceIsOnlyCountedOnce() {
        let one = observation(secondsToOperating: 300, ambientC: 15, at: 1)
        let history = EngineThermalModel.record(one, into: [])
        XCTAssertEqual(EngineThermalModel.record(one, into: history).count, 1,
                       "a baseline built from duplicates is not a baseline")
    }

    func testDistinctWarmUpsAccumulate() {
        var history: [WarmUpObservation] = []
        for day in 1...5 {
            history = EngineThermalModel.record(observation(secondsToOperating: 300,
                                                            ambientC: 15,
                                                            at: Double(day)),
                                                 into: history)
        }
        XCTAssertEqual(history.count, 5)
        XCTAssertTrue(zip(history, history.dropFirst()).allSatisfy { $0.startedAt < $1.startedAt },
                      "kept in order, so the median is over the right window")
    }

    func testHistoryIsBounded() {
        var history: [WarmUpObservation] = []
        for day in 1...200 {
            history = EngineThermalModel.record(observation(secondsToOperating: 300,
                                                            ambientC: 15,
                                                            at: Double(day * 2)),
                                                 into: history, limit: 60)
        }
        XCTAssertEqual(history.count, 60, "an unbounded array on a car kept for years is a leak")
    }

    func testAmbientBanding() {
        XCTAssertEqual(observation(secondsToOperating: 300, ambientC: 17, at: 1).ambientBand, 3)
        XCTAssertEqual(observation(secondsToOperating: 300, ambientC: -3, at: 1).ambientBand, -1)
    }
}

final class InsightConfidenceTests: XCTestCase {

    func testItRoundTripsThroughTheNumericValueDriveInsightRanksBy() {
        for confidence in InsightConfidence.allCases {
            XCTAssertEqual(InsightConfidence(numericValue: confidence.numericValue), confidence)
        }
    }

    func testOrdering() {
        XCTAssertLessThan(InsightConfidence.low, .medium)
        XCTAssertLessThan(InsightConfidence.medium, .high)
    }

    func testOneObservationIsNeverHighConfidence() {
        XCTAssertEqual(InsightConfidence.from(observations: 1, required: 4), .low)
        XCTAssertEqual(InsightConfidence.from(observations: 3, required: 4), .low)
    }

    func testCorroborationRaisesConfidence() {
        XCTAssertEqual(InsightConfidence.from(observations: 4, required: 4), .medium)
        XCTAssertEqual(InsightConfidence.from(observations: 12, required: 4), .high)
    }

    func testAnInferenceCannotBecomeHighConfidenceByRepetition() {
        XCTAssertEqual(InsightConfidence.from(observations: 500, required: 4,
                                              sensorProvenance: .inferred), .medium,
                       "repeating an inference does not turn it into a measurement")
        XCTAssertEqual(InsightConfidence.from(observations: 500, required: 4,
                                              sensorProvenance: .unavailable), .low)
    }

    func testUserEnteredDataIsAsTrustworthyAsASensor() {
        XCTAssertEqual(InsightConfidence.ceiling(for: .userEntered), .high,
                       "the driver knows their own tank size better than a carried-over spec")
    }

    func testTheWeakestInputDecides() {
        XCTAssertEqual(InsightConfidence.weakest([.high, .high, .low]), .low,
                       "averaging would let strong inputs disguise a missing one")
        XCTAssertEqual(InsightConfidence.weakest([]), .low)
    }

    func testOnlyHighConfidenceMayInterruptADriver() {
        XCTAssertTrue(InsightConfidence.high.warrantsInterruption)
        XCTAssertFalse(InsightConfidence.medium.warrantsInterruption)
        XCTAssertFalse(InsightConfidence.low.warrantsInterruption,
                       "a guess is not worth a glance away from the road")
    }

    func testQualifiersMatchTheConfidence() {
        XCTAssertTrue(InsightConfidence.low.qualifier.contains("limited data"))
        XCTAssertTrue(InsightConfidence.high.qualifier.contains("consistent"))
    }
}

final class HyperionPIDTests: XCTestCase {

    private func decode(_ code: UInt8, _ bytes: [UInt8]) throws -> Double {
        let descriptor = try XCTUnwrap(OBDPIDCatalog.descriptor(for: .current(code)))
        let reading = try descriptor.makeReading(from: bytes, at: Date())
        return try XCTUnwrap(reading.numericValue)
    }

    func testFuelTrimEncoding() throws {
        // 128 is the centre: no correction being applied.
        XCTAssertEqual(try decode(0x06, [128]), 0, accuracy: 0.01)
        XCTAssertEqual(try decode(0x06, [0]), -100, accuracy: 0.01)
        XCTAssertEqual(try decode(0x07, [131]), 2.34, accuracy: 0.01)
    }

    func testFuelTrimsCarryMetricsSoTheyCanBeBaselined() throws {
        let stft = try XCTUnwrap(OBDPIDCatalog.descriptor(for: .current(0x06)))
        let ltft = try XCTUnwrap(OBDPIDCatalog.descriptor(for: .current(0x07)))
        XCTAssertEqual(stft.metric, .shortTermFuelTrimPercent)
        XCTAssertEqual(ltft.metric, .longTermFuelTrimPercent)
    }

    func testBankTwoTrimsAreReadButNotBaselined() throws {
        // A four-cylinder engine has one bank. A reply here means the assumption was
        // wrong, which belongs in the Debug Center rather than averaged into bank 1.
        let bank2 = try XCTUnwrap(OBDPIDCatalog.descriptor(for: .current(0x08)))
        XCTAssertNil(bank2.metric)
    }

    func testCommandedEquivalenceRatio() throws {
        // 32768 of 65536, times two: exactly lambda 1.0.
        XCTAssertEqual(try decode(0x44, [0x80, 0x00]), 1.0, accuracy: 0.0001)
    }

    func testDirectInjectionRailPressureIsInKilopascals() throws {
        // 0x23 is the GDI one, scaled by 10 kPa.
        XCTAssertEqual(try decode(0x23, [0x0D, 0xAC]), 35_000, accuracy: 1)
    }

    func testCatalystTemperature() throws {
        // J1979 scales this one by 10 with a 40 degree offset: 0x1AF8 is 6904, so
        // 6904 / 10 - 40 = 650.4. Spelled out because the first version of this test
        // asserted 651.2, which is the answer for 0x1B00, and the formula was blamed.
        XCTAssertEqual(try decode(0x3C, [0x1A, 0xF8]), 650.4, accuracy: 0.1)
    }

    func testEthanolPercentage() throws {
        XCTAssertEqual(try decode(0x52, [51]), 20, accuracy: 0.2)
    }

    func testBarometricPressureNowCarriesAMetric() throws {
        // Estimated boost is MAP minus baro, and the subtraction needs both sides in
        // the telemetry snapshot rather than one of them as display text.
        let baro = try XCTUnwrap(OBDPIDCatalog.descriptor(for: .current(0x33)))
        XCTAssertEqual(baro.metric, .barometricPressureKPa)
    }

    func testOilAndPedalAndAbsoluteLoadAreNowBaselineable() throws {
        XCTAssertEqual(try XCTUnwrap(OBDPIDCatalog.descriptor(for: .current(0x5C))).metric,
                       .oilTemperatureC)
        XCTAssertEqual(try XCTUnwrap(OBDPIDCatalog.descriptor(for: .current(0x5A))).metric,
                       .acceleratorPedalPercent)
        XCTAssertEqual(try XCTUnwrap(OBDPIDCatalog.descriptor(for: .current(0x43))).metric,
                       .absoluteLoadPercent)
    }

    func testNoManufacturerSpecificRequestsWereAdded() {
        // Every PID added for the Hyperion work is a standardised mode 01 parameter.
        // Capability discovery decides what this ECU actually answers.
        for code: UInt8 in [0x06, 0x07, 0x08, 0x09, 0x22, 0x23, 0x24, 0x25,
                            0x30, 0x3C, 0x3E, 0x44, 0x4D, 0x4E, 0x52] {
            let descriptor = OBDPIDCatalog.descriptor(for: .current(code))
            XCTAssertNotNil(descriptor, "0x\(String(format: "%02X", code)) should be catalogued")
            XCTAssertEqual(descriptor?.pid.mode, .currentData)
        }
    }

    func testEveryNewMetricSurvivesTheTelemetryCodec() throws {
        // The wire format stores a metric's index, so a metric missing from metricOrder
        // silently vanishes from every saved drive.
        let metrics: [VehicleMetric] = [
            .shortTermFuelTrimPercent, .longTermFuelTrimPercent, .commandedEquivalenceRatio,
            .fuelRailPressureKPa, .catalystTemperatureC, .ethanolPercent,
            .barometricPressureKPa, .oilTemperatureC, .absoluteLoadPercent,
            .acceleratorPedalPercent, .massAirFlowGramsPerSecond, .timingAdvanceDegrees
        ]
        var sample = TelemetrySample(timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        for (index, metric) in metrics.enumerated() {
            sample[metric] = Double(index + 1)
        }

        let decoded = try XCTUnwrap(TelemetrySeriesCodec.decode(
            try TelemetrySeriesCodec.encode([sample])).first)

        for (index, metric) in metrics.enumerated() {
            XCTAssertEqual(try XCTUnwrap(decoded[metric]), Double(index + 1), accuracy: 0.05,
                           "\(metric.rawValue) did not survive the round trip")
        }
    }
}
