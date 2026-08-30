import XCTest
@testable import DriveLayerCore

private func point(_ latitude: Double,
                   _ longitude: Double,
                   speedKmh: Double,
                   at time: Date,
                   altitude: Double? = nil) -> GeoPoint {
    GeoPoint(latitude: latitude,
             longitude: longitude,
             altitudeMetres: altitude,
             horizontalAccuracyMetres: 8,
             verticalAccuracyMetres: 6,
             speedMetresPerSecond: Convert.metresPerSecond(fromKmh: speedKmh),
             courseDegrees: 90,
             timestamp: time)
}

final class TripRecorderTests: XCTestCase {

    private let vehicleID = UUID()
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func drivingRecorder() -> TripRecorder {
        TripRecorder(vehicleID: vehicleID, tankCapacityLitres: 50,
                     profile: VehicleProfileCatalog.harrier2026AdventureXPlus)
    }

    func testDoesNotStartFromBriefMovement() {
        var recorder = drivingRecorder()
        _ = recorder.update(location: point(12.90, 77.60, speedKmh: 20, at: start), telemetry: nil, now: start)
        let outcome = recorder.update(location: point(12.901, 77.60, speedKmh: 0, at: start.addingTimeInterval(5)),
                                      telemetry: nil, now: start.addingTimeInterval(5))
        XCTAssertEqual(outcome, .none)
        XCTAssertFalse(recorder.isRecording, "a five-second roll is not a drive")
    }

    func testStartsAfterSustainedMovement() {
        var recorder = drivingRecorder()
        _ = recorder.update(location: point(12.90, 77.60, speedKmh: 40, at: start), telemetry: nil, now: start)
        let outcome = recorder.update(location: point(12.905, 77.60, speedKmh: 45, at: start.addingTimeInterval(15)),
                                      telemetry: nil, now: start.addingTimeInterval(15))
        guard case .started = outcome else { return XCTFail("expected the drive to start, got \(outcome)") }
        XCTAssertTrue(recorder.isRecording)
    }

    func testManualStartTwiceDoesNotCreateASecondTrip() {
        var recorder = drivingRecorder()
        guard case let .started(firstID) = recorder.startManually(now: start) else {
            return XCTFail("first manual start should begin a drive")
        }
        let second = recorder.startManually(now: start.addingTimeInterval(10))
        XCTAssertEqual(second, .none, "a duplicate start must be ignored, not stacked")
        XCTAssertEqual(recorder.currentTrip?.id, firstID)
    }

    func testAccumulatesDistanceAndEndsAfterSustainedStop() {
        var recorder = drivingRecorder()
        _ = recorder.startManually(now: start)

        var time = start
        var latitude = 12.90
        for _ in 0..<40 {
            time = time.addingTimeInterval(10)
            latitude += 0.0015          // roughly 165 m per step
            _ = recorder.update(location: point(latitude, 77.60, speedKmh: 60, at: time), telemetry: nil, now: time)
        }

        // Stop, then wait out the stop-confirmation window.
        time = time.addingTimeInterval(10)
        _ = recorder.update(location: point(latitude, 77.60, speedKmh: 0, at: time), telemetry: nil, now: time)
        time = time.addingTimeInterval(200)
        let outcome = recorder.update(location: point(latitude, 77.60, speedKmh: 0, at: time), telemetry: nil, now: time)

        guard case let .ended(trip) = outcome else { return XCTFail("expected the drive to end, got \(outcome)") }
        XCTAssertEqual(trip.endReason, .stoppedMoving)
        XCTAssertEqual(trip.distanceMetres, 6_600, accuracy: 900)
        XCTAssertFalse(recorder.isRecording)
    }

    func testVeryShortDriveIsDiscardedRatherThanSaved() {
        var recorder = drivingRecorder()
        _ = recorder.startManually(now: start)
        let time = start.addingTimeInterval(20)
        _ = recorder.update(location: point(12.90, 77.60, speedKmh: 0, at: time), telemetry: nil, now: time)
        let outcome = recorder.endManually(now: time.addingTimeInterval(1))
        guard case .discarded = outcome else { return XCTFail("expected a discard, got \(outcome)") }
    }

    func testLongSilenceClosesTheDriveAtItsLastKnownPoint() {
        var recorder = drivingRecorder()
        _ = recorder.startManually(now: start)
        var time = start
        var latitude = 12.90
        for _ in 0..<30 {
            time = time.addingTimeInterval(10)
            latitude += 0.002
            _ = recorder.update(location: point(latitude, 77.60, speedKmh: 70, at: time), telemetry: nil, now: time)
        }
        let lastSeen = time

        // The app was suspended for twenty minutes.
        let outcome = recorder.update(location: nil, telemetry: nil, now: time.addingTimeInterval(1_200))
        guard case let .ended(trip) = outcome else { return XCTFail("expected the drive to close, got \(outcome)") }
        XCTAssertEqual(trip.endReason, .recoveredAfterInterruption)
        XCTAssertEqual(trip.endedAt, lastSeen, "the missing time must not be invented")
    }

    func testEngineOffEndsTheDrive() {
        var recorder = drivingRecorder()
        _ = recorder.startManually(now: start)

        var running = VehicleTelemetry(updatedAt: start)
        running.set(.engineRPM, value: 1_800, at: start)
        var time = start.addingTimeInterval(10)
        _ = recorder.update(location: point(12.90, 77.60, speedKmh: 50, at: time), telemetry: running, now: time)

        var off = VehicleTelemetry(updatedAt: time)
        off.set(.engineRPM, value: 0, at: time)
        time = time.addingTimeInterval(60)
        let outcome = recorder.update(location: point(12.90, 77.60, speedKmh: 0, at: time), telemetry: off, now: time)
        guard case let .ended(trip) = outcome else { return XCTFail("expected the drive to end, got \(outcome)") }
        XCTAssertEqual(trip.endReason, .engineOff)
    }

    func testAdapterDropIsRecordedAsAnEventAndTheDriveContinues() {
        var recorder = drivingRecorder()
        _ = recorder.startManually(now: start)
        recorder.noteAdapterConnectionChange(connected: false, at: start.addingTimeInterval(30))
        recorder.noteAdapterConnectionChange(connected: true, at: start.addingTimeInterval(90))

        let trip = recorder.currentTrip
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(trip?.events.map(\.kind), [.adapterDisconnected, .adapterReconnected])
    }

    func testImplausibleGPSJumpDoesNotInflateDistance() {
        var recorder = drivingRecorder()
        _ = recorder.startManually(now: start)

        var time = start.addingTimeInterval(10)
        _ = recorder.update(location: point(12.90, 77.60, speedKmh: 60, at: time), telemetry: nil, now: time)
        time = time.addingTimeInterval(2)
        // A fix 300 km away two seconds later cannot be real.
        _ = recorder.update(location: point(15.60, 77.60, speedKmh: 60, at: time), telemetry: nil, now: time)

        XCTAssertLessThan(recorder.currentTrip?.distanceMetres ?? .greatestFiniteMagnitude, 1_000)
    }

    func testInterruptedTripRecoveryDropsTripsTooShortToMatter() {
        let trip = Trip(vehicleID: vehicleID, startedAt: start, distanceMetres: 40)
        XCTAssertNil(TripRecovery.finalise(trip, lastKnownActivityAt: start.addingTimeInterval(20)))

        let realTrip = Trip(vehicleID: vehicleID, startedAt: start, distanceMetres: 9_000)
        let recovered = TripRecovery.finalise(realTrip, lastKnownActivityAt: start.addingTimeInterval(600))
        XCTAssertEqual(recovered?.endReason, .recoveredAfterInterruption)
    }
}

final class TripFuelAndAnalyticsTests: XCTestCase {

    private let vehicleID = UUID()
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testFuelIsUnavailableRatherThanZeroOnAPhoneOnlyDrive() {
        var recorder = TripRecorder(vehicleID: vehicleID, tankCapacityLitres: 50)
        _ = recorder.startManually(now: start)
        let trip = recorder.currentTrip
        XCTAssertEqual(trip?.fuelUsedLitres.provenance, .unavailable)
        XCTAssertNil(trip?.fuelUsedLitres.value)
        XCTAssertNil(trip?.economyKmPerLitre, "economy must be absent, not zero")
    }

    func testFuelIsIntegratedFromReportedRate() {
        var builder = TripBuilder(vehicleID: vehicleID, startedAt: start, tankCapacityLitres: 50)
        var telemetry = VehicleTelemetry(updatedAt: start)
        telemetry.set(.fuelRateLitresPerHour, value: 6.0, at: start)
        telemetry.set(.vehicleSpeedKmh, value: 80, at: start)

        // One hour at six litres an hour.
        for step in 0..<60 {
            let now = start.addingTimeInterval(Double(step + 1) * 60)
            telemetry.set(.fuelRateLitresPerHour, value: 6.0, at: now)
            telemetry.set(.vehicleSpeedKmh, value: 80, at: now)
            builder.ingest(location: nil, telemetry: telemetry, interval: 60, now: now)
        }
        let trip = builder.finish(at: start.addingTimeInterval(3_600), reason: .manual)
        XCTAssertEqual(trip.fuelUsedLitres.value ?? 0, 6.0, accuracy: 0.01)
        XCTAssertEqual(trip.fuelUsedLitres.provenance, .estimated)
        XCTAssertNotNil(trip.fuelUsedLitres.basis)
    }

    func testTankLevelFallbackNeedsAMeaningfulDrop() {
        func tripDroppingLevel(from first: Double, to last: Double) -> Trip {
            var builder = TripBuilder(vehicleID: vehicleID, startedAt: start, tankCapacityLitres: 50)
            var telemetry = VehicleTelemetry(updatedAt: start)
            telemetry.set(.fuelLevelPercent, value: first, at: start)
            builder.ingest(location: nil, telemetry: telemetry, interval: 0, now: start)
            let end = start.addingTimeInterval(1_800)
            telemetry.set(.fuelLevelPercent, value: last, at: end)
            builder.ingest(location: nil, telemetry: telemetry, interval: 1_800, now: end)
            return builder.finish(at: end, reason: .manual)
        }

        // A one-point wobble is sender noise, not fuel.
        XCTAssertFalse(tripDroppingLevel(from: 60, to: 59).fuelUsedLitres.isAvailable)

        let real = tripDroppingLevel(from: 60, to: 50)
        XCTAssertEqual(real.fuelUsedLitres.value ?? 0, 5.0, accuracy: 0.01)
    }

    func testAnalyticsIgnoreDrivesWithoutFuelRatherThanTreatingThemAsZero() {
        let withFuel = Trip(vehicleID: vehicleID, startedAt: start,
                            endedAt: start.addingTimeInterval(3_600),
                            distanceMetres: 60_000,
                            fuelUsedLitres: .estimated(4.0))
        let withoutFuel = Trip(vehicleID: vehicleID, startedAt: start.addingTimeInterval(7_200),
                               endedAt: start.addingTimeInterval(10_800),
                               distanceMetres: 40_000)

        let analytics = TripAnalytics.summarise([withFuel, withoutFuel])
        XCTAssertEqual(analytics.tripCount, 2)
        XCTAssertEqual(analytics.totalDistanceKm, 100, accuracy: 0.001)
        XCTAssertEqual(analytics.averageEconomyKmPerLitre ?? 0, 15, accuracy: 0.001)
        XCTAssertEqual(analytics.totalFuelLitres ?? 0, 4.0, accuracy: 0.001)
    }

    func testEmptyAnalyticsReportNothingRatherThanZeroes() {
        let analytics = TripAnalytics.summarise([])
        XCTAssertEqual(analytics.tripCount, 0)
        XCTAssertNil(analytics.averageEconomyKmPerLitre)
        XCTAssertNil(analytics.idleFraction)
    }

    func testIncompleteTripsAreExcluded() {
        let open = Trip(vehicleID: vehicleID, startedAt: start, distanceMetres: 5_000)
        XCTAssertEqual(TripAnalytics.summarise([open]).tripCount, 0)
    }
}

final class TripComparisonTests: XCTestCase {

    private let vehicleID = UUID()
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func commute(daysAgo: Int, minutes: Double, idleMinutes: Double, litres: Double) -> Trip {
        let began = start.addingTimeInterval(-Double(daysAgo) * 86_400)
        return Trip(vehicleID: vehicleID,
                    startedAt: began,
                    endedAt: began.addingTimeInterval(minutes * 60),
                    endReason: .stoppedMoving,
                    distanceMetres: 11_200,
                    idleDurationSeconds: idleMinutes * 60,
                    fuelUsedLitres: .estimated(litres),
                    startLatitude: 12.9010, startLongitude: 77.6010,
                    endLatitude: 12.9700, endLongitude: 77.6400)
    }

    func testNeedsEnoughHistoryBeforeClaimingATypicalRun() {
        let today = commute(daysAgo: 0, minutes: 47, idleMinutes: 14, litres: 1.0)
        let history = [commute(daysAgo: 1, minutes: 41, idleMinutes: 8, litres: 0.875)]
        XCTAssertNil(TripComparisonEngine.compare(today, against: history))
    }

    func testDetectsWorseEconomyAndAssociatesItWithIdling() throws {
        let today = commute(daysAgo: 0, minutes: 47, idleMinutes: 14, litres: 1.0)
        let history = (1...4).map { commute(daysAgo: $0, minutes: 41, idleMinutes: 8, litres: 0.875) }

        let comparison = try XCTUnwrap(TripComparisonEngine.compare(today, against: history))
        XCTAssertEqual(comparison.comparableTripCount, 4)
        let economyDelta = try XCTUnwrap(comparison.economyDeltaPercent)
        XCTAssertEqual(economyDelta, -12.5, accuracy: 0.5)

        let summary = try XCTUnwrap(comparison.summary)
        XCTAssertTrue(summary.contains("associated with"), "wording must not imply causation")
        XCTAssertFalse(summary.lowercased().contains("because"))
    }

    func testAnUnremarkableDriveProducesNoSummary() throws {
        let today = commute(daysAgo: 0, minutes: 41, idleMinutes: 8, litres: 0.88)
        let history = (1...4).map { commute(daysAgo: $0, minutes: 41, idleMinutes: 8, litres: 0.875) }
        let comparison = try XCTUnwrap(TripComparisonEngine.compare(today, against: history))
        XCTAssertNil(comparison.summary, "saying nothing is the right output for a normal drive")
    }

    func testADifferentJourneyIsNotTreatedAsTheSameRoute() {
        let today = commute(daysAgo: 0, minutes: 47, idleMinutes: 14, litres: 1.0)
        var elsewhere = commute(daysAgo: 1, minutes: 41, idleMinutes: 8, litres: 0.875)
        elsewhere.endLatitude = 13.4000
        elsewhere.endLongitude = 77.9000
        XCTAssertTrue(TripComparisonEngine.comparableTrips(to: today, in: [elsewhere]).isEmpty)
    }

    func testTripWithoutEndpointsHasNoSignature() {
        let trip = Trip(vehicleID: vehicleID, startedAt: start, endedAt: start.addingTimeInterval(600))
        XCTAssertNil(RouteSignature(trip: trip))
    }
}
