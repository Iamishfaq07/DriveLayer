import XCTest
@testable import DriveLayerCore

final class StatisticsTests: XCTestCase {

    func testEmptyInputReturnsNothing() {
        XCTAssertNil(Statistics.mean([]))
        XCTAssertNil(Statistics.median([]))
        XCTAssertNil(Statistics.standardDeviation([1]))
        XCTAssertNil(Statistics.percentile([], 0.5))
    }

    func testMedianHandlesBothParities() {
        XCTAssertEqual(Statistics.median([3, 1, 2]) ?? 0, 2, accuracy: 0.0001)
        XCTAssertEqual(Statistics.median([4, 1, 3, 2]) ?? 0, 2.5, accuracy: 0.0001)
    }

    func testPercentileInterpolates() {
        let values = [1.0, 2, 3, 4, 5]
        XCTAssertEqual(Statistics.percentile(values, 0.5) ?? 0, 3, accuracy: 0.0001)
        XCTAssertEqual(Statistics.percentile(values, 0.25) ?? 0, 2, accuracy: 0.0001)
        XCTAssertEqual(Statistics.percentile(values, 0) ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(Statistics.percentile(values, 1) ?? 0, 5, accuracy: 0.0001)
    }

    func testOutlierRejectionRemovesASpikeButKeepsSpread() {
        let clean = [12.4, 12.5, 12.45, 12.55, 12.5, 12.48]
        let withSpike = clean + [0.0]
        let filtered = Statistics.rejectingOutliers(withSpike)
        XCTAssertFalse(filtered.contains(0.0), "a dropped-byte reading must not define normal")
        XCTAssertEqual(filtered.count, clean.count)
    }

    func testOutlierRejectionLeavesSmallSamplesAlone() {
        let values = [1.0, 90.0, 2.0]
        XCTAssertEqual(Statistics.rejectingOutliers(values).count, 3,
                       "three points are not enough to call one of them an outlier")
    }

    func testSlopePerDayMatchesAKnownDecline() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let times = (0..<10).map { start.addingTimeInterval(Double($0) * 86_400) }
        let values = (0..<10).map { 12.6 - Double($0) * 0.01 }
        let slope = try XCTUnwrap(Statistics.slopePerDay(values: values, times: times))
        XCTAssertEqual(slope, -0.01, accuracy: 0.0001)
    }

    func testZScoreNeedsSpread() {
        XCTAssertNil(Statistics.zScore(value: 5, sample: [5, 5, 5]))
    }
}

final class ProvenanceTests: XCTestCase {

    func testMissingValueIsAlwaysUnavailable() {
        let value = Provenanced<Double>(value: nil, provenance: .measured)
        XCTAssertEqual(value.provenance, .unavailable)
        XCTAssertFalse(value.isAvailable)
    }

    func testPresentValueCannotClaimUnavailable() {
        let value = Provenanced<Double>(value: 3, provenance: .unavailable)
        XCTAssertEqual(value.provenance, .estimated)
    }

    func testConfidenceCeilingsDescendWithTrust() {
        XCTAssertGreaterThan(DataProvenance.measured.confidenceCeiling, DataProvenance.estimated.confidenceCeiling)
        XCTAssertGreaterThan(DataProvenance.estimated.confidenceCeiling, DataProvenance.inferred.confidenceCeiling)
        XCTAssertEqual(DataProvenance.unavailable.confidenceCeiling, 0)
    }
}

final class SemanticStatusTests: XCTestCase {

    func testRollUpTakesTheWorst() {
        XCTAssertEqual(SemanticStatus.rollUp([.normal, .watch, .attention]), .attention)
        XCTAssertEqual(SemanticStatus.rollUp([.normal, .normal]), .normal)
    }

    func testEmptyRollUpIsUnknownNotHealthy() {
        XCTAssertEqual(SemanticStatus.rollUp([SemanticStatus]()), .unknown)
    }

    func testUnknownOutranksNormalButNotWatch() {
        XCTAssertEqual(SemanticStatus.rollUp([.normal, .unknown]), .unknown)
        XCTAssertEqual(SemanticStatus.rollUp([.unknown, .watch]), .watch)
    }

    func testEveryStatusHasDistinctSymbolAndLabel() {
        let symbols = Set(SemanticStatus.allCases.map(\.symbolName))
        XCTAssertEqual(symbols.count, SemanticStatus.allCases.count,
                       "status must be legible without colour")
    }
}

final class VehicleTelemetryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testStaleValuesAreNotReturnedAsCurrent() {
        var telemetry = VehicleTelemetry(updatedAt: now)
        telemetry.set(.coolantTemperatureC, value: 92, at: now.addingTimeInterval(-240))
        XCTAssertNotNil(telemetry.value(.coolantTemperatureC))
        XCTAssertNil(telemetry.value(.coolantTemperatureC, freshWithin: 60, now: now))
    }

    func testImplausibleReadingsAreNotApplied() {
        var telemetry = VehicleTelemetry(updatedAt: now)
        let reading = OBDReading(pid: .current(0x0C), name: "Engine speed", metric: .engineRPM,
                                value: .number(16_000), unitLabel: "rpm", timestamp: now, isPlausible: false)
        telemetry.apply(reading)
        XCTAssertNil(telemetry.value(.engineRPM))
    }

    func testEngineRunningIsUnknownWithoutEvidence() {
        let telemetry = VehicleTelemetry(updatedAt: now)
        XCTAssertNil(telemetry.isEngineRunning(now: now), "no data means unknown, not off")
    }

    func testEngineRunningFromRPMThenVoltage() {
        var telemetry = VehicleTelemetry(updatedAt: now)
        telemetry.set(.controlModuleVoltageV, value: 14.1, at: now)
        XCTAssertEqual(telemetry.isEngineRunning(now: now), true)

        telemetry.set(.engineRPM, value: 0, at: now)
        XCTAssertEqual(telemetry.isEngineRunning(now: now), false, "engine speed outranks voltage")
    }

    func testMissingMetricIsUnavailableNotZero() {
        let telemetry = VehicleTelemetry(updatedAt: now)
        XCTAssertEqual(telemetry.provenanced(.fuelLevelPercent).provenance, .unavailable)
    }
}

final class TelemetrySamplingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testDeadbandSuppressesUnchangedValues() {
        let policy = TelemetrySamplingPolicy.default
        let last = (value: 92.0, timestamp: now)
        XCTAssertFalse(policy.shouldPersist(metric: .coolantTemperatureC, value: 92.2,
                                            lastPersisted: last, now: now.addingTimeInterval(5)))
        XCTAssertTrue(policy.shouldPersist(metric: .coolantTemperatureC, value: 95.0,
                                           lastPersisted: last, now: now.addingTimeInterval(5)))
    }

    func testMaximumIntervalForcesASampleEventually() {
        let policy = TelemetrySamplingPolicy.default
        let last = (value: 92.0, timestamp: now)
        XCTAssertTrue(policy.shouldPersist(metric: .coolantTemperatureC, value: 92.0,
                                           lastPersisted: last, now: now.addingTimeInterval(120)))
    }

    func testFirstValueIsAlwaysPersisted() {
        XCTAssertTrue(TelemetrySamplingPolicy.default.shouldPersist(metric: .engineRPM, value: 800,
                                                                    lastPersisted: nil, now: now))
    }

    func testDownsamplerEmitsNothingWhenNothingChanged() {
        var downsampler = TelemetryDownsampler()
        var telemetry = VehicleTelemetry(updatedAt: now)
        telemetry.set(.coolantTemperatureC, value: 92, at: now)

        XCTAssertNotNil(downsampler.consider(telemetry, at: now))
        var later = VehicleTelemetry(updatedAt: now.addingTimeInterval(5))
        later.set(.coolantTemperatureC, value: 92.1, at: now.addingTimeInterval(5))
        XCTAssertNil(downsampler.consider(later, at: now.addingTimeInterval(5)))
    }
}

final class TelemetryCodecTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func sampleRun(count: Int) -> [TelemetrySample] {
        (0..<count).map { index in
            TelemetrySample(timestamp: start.addingTimeInterval(Double(index)), values: [
                .engineRPM: 1_500 + Double(index),
                .coolantTemperatureC: 88.4,
                .controlModuleVoltageV: 14.123,
                .vehicleSpeedKmh: 62.5
            ])
        }
    }

    func testRoundTripPreservesValuesWithinQuantisationError() throws {
        let samples = sampleRun(count: 50)
        let decoded = try TelemetrySeriesCodec.decode(TelemetrySeriesCodec.encode(samples))

        XCTAssertEqual(decoded.count, samples.count)
        for (original, restored) in zip(samples, decoded) {
            XCTAssertEqual(original.timestamp.timeIntervalSince1970,
                           restored.timestamp.timeIntervalSince1970, accuracy: 0.002)
            for (metric, value) in original.values {
                let tolerance = TelemetrySeriesCodec.scale(for: metric) / 2 + 0.0001
                XCTAssertEqual(try XCTUnwrap(restored[metric]), value, accuracy: tolerance)
            }
        }
    }

    func testAbsentMetricsStayAbsent() throws {
        let sample = TelemetrySample(timestamp: start, values: [.engineRPM: 900])
        let decoded = try TelemetrySeriesCodec.decode(TelemetrySeriesCodec.encode([sample]))
        XCTAssertEqual(decoded.first?.values.count, 1)
        XCTAssertNil(decoded.first?[.coolantTemperatureC], "a metric never reported must not decode as zero")
    }

    func testEncodingIsCompact() throws {
        let data = try TelemetrySeriesCodec.encode(sampleRun(count: 1_000))
        // Header plus 8 bytes of framing and 2 bytes per present metric per sample.
        XCTAssertLessThan(data.count, 1_000 * 20, "an hour of driving must not cost megabytes")
    }

    func testEmptySeriesRoundTrips() throws {
        XCTAssertTrue(try TelemetrySeriesCodec.decode(TelemetrySeriesCodec.encode([])).isEmpty)
    }

    func testCorruptedDataThrowsRatherThanReturningNonsense() throws {
        var data = try TelemetrySeriesCodec.encode(sampleRun(count: 10))
        data.removeLast(10)
        XCTAssertThrowsError(try TelemetrySeriesCodec.decode(data))
    }

    func testBadMagicIsRejected() {
        XCTAssertThrowsError(try TelemetrySeriesCodec.decode(Data([0x00, 0x01, 0x02, 0x03, 0x01, 0x0F]))) { error in
            XCTAssertEqual(error as? TelemetryCodecError, .badMagic)
        }
    }

    func testMetricOrderIsCompleteSoNothingIsSilentlyDropped() {
        XCTAssertEqual(Set(TelemetrySeriesCodec.metricOrder), Set(VehicleMetric.allCases))
        XCTAssertLessThanOrEqual(TelemetrySeriesCodec.metricOrder.count, 32,
                                 "the presence bitmask is 32 bits wide")
    }
}
