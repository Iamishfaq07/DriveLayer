import XCTest
@testable import DriveLayerCore

final class TelemetryTrustRegressionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func warmedTelemetry() -> VehicleTelemetry {
        var t = VehicleTelemetry(updatedAt: now)
        for (metric, value) in [(VehicleMetric.engineRPM, 1800.0), (.vehicleSpeedKmh, 60),
                                (.coolantTemperatureC, 90), (.engineLoadPercent, 40),
                                (.controlModuleVoltageV, 14), (.intakeAirTemperatureC, 50),
                                (.ambientAirTemperatureC, 30)] {
            t.set(metric, value: value, at: now)
        }
        return t
    }

    func testRejectedReadingIsHeldOnlyForDiagnostics() throws {
        var t = warmedTelemetry()
        let descriptor = try XCTUnwrap(OBDPIDCatalog.descriptor(for: .current(0x05)))
        let bad = try descriptor.makeReading(from: [255], at: now)
        t.apply(bad, plausibleRange: descriptor.plausibleRange)
        XCTAssertEqual(t.lastKnownValue(.coolantTemperatureC), 90)
        XCTAssertNil(t.trustedValue(.coolantTemperatureC, freshWithin: 60, now: now))
        XCTAssertNil(t.provenancedTrustedReading(.coolantTemperatureC, freshWithin: 60, now: now).value)
        XCTAssertNotNil(t.rejectionReason(.coolantTemperatureC))
        XCTAssertNil(t.sample(at: now)[.coolantTemperatureC])
        var sampler = TelemetryDownsampler()
        XCTAssertNil(sampler.consider(t, at: now)?[.coolantTemperatureC])
    }

    func testFirstRejectionRetainsReasonWithoutCreatingEntry() throws {
        var t = VehicleTelemetry(updatedAt: now)
        let descriptor = try XCTUnwrap(OBDPIDCatalog.descriptor(for: .current(0x05)))
        t.apply(try descriptor.makeReading(from: [255], at: now))
        XCTAssertNil(t.lastKnownEntry(.coolantTemperatureC))
        XCTAssertNotNil(t.rejectionReason(.coolantTemperatureC))
    }

    func testTrustedReadRejectsOldFutureAndNonFiniteValues() {
        for (date, value) in [(now.addingTimeInterval(-61), 90.0),
                              (now.addingTimeInterval(1), 90), (now, .infinity), (now, .nan)] {
            var t = VehicleTelemetry(updatedAt: now)
            t.set(.coolantTemperatureC, value: value, at: date)
            XCTAssertNil(t.trustedEntry(.coolantTemperatureC, freshWithin: 60, now: now))
        }
    }

    func testFuelPreservesOriginalAgeAndSourceThroughRange() {
        for provenance in [DataProvenance.measured, .simulated] {
            var t = VehicleTelemetry(updatedAt: now)
            let sampledAt = now.addingTimeInterval(-40)
            t.set(.fuelLevelPercent, value: 50, at: sampledAt, provenance: provenance)
            let level = t.provenancedTrustedReading(.fuelLevelPercent, freshWithin: 120, now: now)
            let fuel = FuelIntelligence.status(levelPercent: level, tankCapacityLitres: 50,
                                               economy: (10, .recentTrips))
            XCTAssertEqual(fuel.levelPercent.timestamp, sampledAt)
            XCTAssertEqual(fuel.levelPercent.provenance, provenance)
            XCTAssertEqual(fuel.estimatedRangeKm.timestamp, sampledAt)
            XCTAssertEqual(fuel.estimatedRangeKm.provenance, provenance == .simulated ? .simulated : .estimated)
        }
    }

    func testFuelStaleSuspectAndMissingCannotProduceRange() {
        var stale = VehicleTelemetry(updatedAt: now)
        stale.set(.fuelLevelPercent, value: 50, at: now.addingTimeInterval(-900))
        var suspect = VehicleTelemetry(updatedAt: now)
        suspect.set(.fuelLevelPercent, value: 50, at: now, quality: .suspect)
        for t in [stale, suspect, VehicleTelemetry(updatedAt: now)] {
            let level = t.provenancedTrustedReading(.fuelLevelPercent, freshWithin: 120, now: now)
            let fuel = FuelIntelligence.status(levelPercent: level, tankCapacityLitres: 50,
                                               economy: (10, .recentTrips))
            XCTAssertNil(fuel.estimatedRangeKm.value)
            XCTAssertEqual(FuelIntelligence.assessJourney(distanceKm: 20, status: fuel), .unknown)
        }
    }

    func testProductionCollectorLearnsDeltaAndNeverRecountsHeldFrames() throws {
        let t = warmedTelemetry()
        var collector = BaselineObservationCollector()
        var aggregates: [BaselineDailyAggregate] = []
        for _ in 0..<100 { collector.collect(t, at: now, gradientPercent: nil, into: &aggregates) }
        let delta = try XCTUnwrap(aggregates.first { $0.key.metric == .intakeAmbientDeltaC })
        XCTAssertEqual(delta.mean, 20)
        XCTAssertEqual(delta.key.context, .cruising)
        XCTAssertEqual(delta.count, 1)
        XCTAssertTrue(aggregates.allSatisfy { $0.count == 1 })
        XCTAssertFalse(aggregates.contains { $0.key.metric == .intakeAirTemperatureC })
    }

    func testCollectorRejectsSuspectSimulatedEstimatedAndStaleInputs() {
        for provenance in [DataProvenance.simulated, .estimated, .inferred, .learned, .userEntered] {
            var t = warmedTelemetry()
            t.set(.coolantTemperatureC, value: 90, at: now, provenance: provenance)
            var collector = BaselineObservationCollector()
            var aggregates: [BaselineDailyAggregate] = []
            collector.collect(t, at: now, gradientPercent: nil, into: &aggregates)
            XCTAssertFalse(aggregates.contains { $0.key.metric == .coolantTemperatureC })
        }
        for t in [warmedTelemetry()] {
            var collector = BaselineObservationCollector()
            var aggregates: [BaselineDailyAggregate] = []
            collector.collect(t, at: now.addingTimeInterval(300), gradientPercent: nil, into: &aggregates)
            XCTAssertTrue(aggregates.isEmpty)
        }
        var suspect = warmedTelemetry()
        suspect.set(.intakeAirTemperatureC, value: 50, at: now, quality: .suspect)
        var collector = BaselineObservationCollector()
        var aggregates: [BaselineDailyAggregate] = []
        collector.collect(suspect, at: now, gradientPercent: nil, into: &aggregates)
        XCTAssertFalse(aggregates.contains { $0.key.metric == .intakeAmbientDeltaC })
    }

    func testInsightContextKeepsTrustedTimestampAndProvenance() throws {
        let sampledAt = now.addingTimeInterval(-12)
        for provenance in [DataProvenance.measured, .estimated, .simulated] {
            var telemetry = VehicleTelemetry(updatedAt: sampledAt)
            telemetry.set(.coolantTemperatureC, value: 88, at: sampledAt, provenance: provenance)
            let context = InsightContext(now: now, telemetry: telemetry)
            let entry = try XCTUnwrap(context.trustedEntry(.coolantTemperatureC, freshWithin: 30))
            XCTAssertEqual(entry.timestamp, sampledAt)
            XCTAssertEqual(entry.provenance, provenance)
            let reading = context.trustedReading(.coolantTemperatureC, freshWithin: 30)
            XCTAssertEqual(reading.timestamp, sampledAt)
            XCTAssertEqual(reading.provenance, provenance)
        }
    }

    func testInsightEvidenceUsesSensorAndLearnedProvenance() {
        var telemetry = VehicleTelemetry(updatedAt: now)
        telemetry.set(.coolantTemperatureC, value: 90, at: now, provenance: .simulated)
        let context = InsightContext(now: now, profile: VehicleProfileCatalog.harrier2026AdventureXPlus,
                                     isAdapterConnected: true, telemetry: telemetry)
        let report = VehicleHealthEvaluator.evaluate(context)
        XCTAssertEqual(report.system(.engine)?.dataPoints.first?.provenance, .simulated)
        XCTAssertEqual(InsightSourceDatum.learned("Typical", "90 °C").provenance, .learned)
    }

    func testNoEngineEvidenceDoesNotTeachWarmedBaseline() {
        var t = VehicleTelemetry(updatedAt: now)
        t.set(.coolantTemperatureC, value: 90, at: now)
        var collector = BaselineObservationCollector()
        var aggregates: [BaselineDailyAggregate] = []
        collector.collect(t, at: now, gradientPercent: nil, into: &aggregates)
        XCTAssertTrue(aggregates.isEmpty)
    }

    func testEveryProductionPIDIsReachableWithoutPromotingDiagnosticOnlyPIDs() throws {
        let expected: [UInt8: VehicleMetric] = [
            0x01: .monitorStatusCode, 0x03: .fuelSystemStatusCode, 0x04: .engineLoadPercent,
            0x05: .coolantTemperatureC, 0x06: .shortTermFuelTrimPercent, 0x07: .longTermFuelTrimPercent,
            0x0B: .intakeManifoldPressureKPa, 0x0C: .engineRPM, 0x0D: .vehicleSpeedKmh,
            0x0E: .timingAdvanceDegrees, 0x0F: .intakeAirTemperatureC, 0x10: .massAirFlowGramsPerSecond,
            0x11: .throttlePositionPercent, 0x23: .fuelRailPressureKPa, 0x2F: .fuelLevelPercent,
            0x33: .barometricPressureKPa, 0x3C: .catalystTemperatureC, 0x42: .controlModuleVoltageV,
            0x43: .absoluteLoadPercent, 0x44: .commandedEquivalenceRatio, 0x46: .ambientAirTemperatureC,
            0x5A: .acceleratorPedalPercent, 0x52: .ethanolPercent, 0x5C: .oilTemperatureC,
            0x5E: .fuelRateLitresPerHour
        ]
        let report = OBDCapabilityReport(supportedCodes: Set(OBDPIDCatalog.allDescriptors.compactMap { $0.pid.code }))
        XCTAssertEqual(Set(report.decodableDescriptors.compactMap { $0.pid.code }), Set(expected.keys))
        for (code, metric) in expected {
            XCTAssertEqual(OBDPIDCatalog.descriptor(for: .current(code))?.metric, metric)
            XCTAssertTrue(report.canAttempt(.current(code)))
            XCTAssertTrue(report.availableMetrics.contains(metric))
        }
        XCTAssertFalse(report.decodableDescriptors.contains { $0.pid.code == 0x08 })
    }
}
