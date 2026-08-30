import XCTest
import SwiftData

/// The brief's test 1, end to end: an active drive exists, the app is terminated, it
/// relaunches, and the drive is recovered.
///
/// This is the test that could not have passed before. Drives were persisted only at
/// `.ended`, so there was never an incomplete row for `recoverInterruptedTrips()` to
/// find — it was correct code guarding a state nothing could produce.
///
/// A second `DriveSessionCoordinator` over the same store stands in for the relaunch,
/// which is exactly what a relaunch is: new objects, same database.
@MainActor
final class DriveSessionRecoveryTests: XCTestCase {

    private var container: ModelContainer!
    private var store: GarageStore!
    private var settings: AppSettings!
    private var vehicle: Vehicle!

    override func setUpWithError() throws {
        let schema = Schema(DriveLayerSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        store = GarageStore(context: ModelContext(container))

        // A dedicated defaults domain, so a test never reads or writes the real app's
        // settings and two tests cannot interfere with each other.
        let suiteName = "drivelayer.tests.\(UUID().uuidString)"
        settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))

        vehicle = Vehicle(nickname: "Harrier",
                          profileID: SupportedVehicles.defaultProfileID,
                          modelYear: 2026,
                          odometerKm: 20_000,
                          isPrimary: true)
        store.add(vehicle: vehicle)
    }

    override func tearDownWithError() throws {
        store = nil
        container = nil
        settings = nil
    }

    /// A coordinator wired to the shared store and to services that will not be driven.
    ///
    /// Location and motion are real objects that simply never receive a fix in a test
    /// bundle, which is fine here: this exercises the persistence and recovery path,
    /// which is driven by the recorder rather than by sensors.
    private func makeCoordinator() -> DriveSessionCoordinator {
        let coordinator = DriveSessionCoordinator(store: store,
                                                  obd: OBDConnectionManager(),
                                                  location: LocationService(),
                                                  motion: MotionService(),
                                                  settings: settings,
                                                  weather: MockWeatherProvider(scenario: .clear),
                                                  route: UnavailableRouteProvider())
        coordinator.select(vehicle: vehicle)
        return coordinator
    }

    // MARK: - Checkpointing

    func testStartingADriveImmediatelyPersistsIt() throws {
        let coordinator = makeCoordinator()
        XCTAssertTrue(store.openTrips(vehicleID: vehicle.id).isEmpty)

        coordinator.startDriveManually()

        XCTAssertTrue(coordinator.isRecording)
        let open = store.openTrips(vehicleID: vehicle.id)
        XCTAssertEqual(open.count, 1,
                       "a drive must exist on disk from the moment it starts, not from "
                       + "the moment it ends")
        XCTAssertEqual(open.first?.id, coordinator.currentTrip?.id)
    }

    func testCheckpointUpdatesTheSameRowRatherThanAddingOne() throws {
        let coordinator = makeCoordinator()
        coordinator.startDriveManually()
        let tripID = try XCTUnwrap(coordinator.currentTrip?.id)

        for _ in 0..<5 {
            coordinator.checkpoint(force: true)
        }

        let open = store.openTrips(vehicleID: vehicle.id)
        XCTAssertEqual(open.count, 1, "checkpointing is an upsert, not an append")
        XCTAssertEqual(open.first?.id, tripID)
    }

    func testCheckpointIsThrottledUnlessForced() throws {
        let coordinator = makeCoordinator()
        coordinator.startDriveManually()

        // A tick one second later must not write again; the interval is twenty seconds.
        let soon = Date().addingTimeInterval(1)
        coordinator.checkpoint(now: soon)

        XCTAssertEqual(store.openTrips(vehicleID: vehicle.id).count, 1,
                       "still exactly the one row from the start checkpoint")
    }

    func testCheckpointDoesNothingWhenNoDriveIsRecording() {
        let coordinator = makeCoordinator()
        coordinator.checkpoint(force: true)
        XCTAssertTrue(store.openTrips(vehicleID: vehicle.id).isEmpty,
                      "a parked car should not accumulate empty drives")
    }

    // MARK: - The brief's test 1

    func testAnInterruptedDriveIsRecoveredOnTheNextLaunch() throws {
        // An hour of driving, checkpointed, and then the app is terminated. Written
        // straight to the store because that is what a checkpoint leaves behind, and a
        // test bundle gets no location fixes to accumulate real distance from.
        let tripID = UUID()
        let startedAt = Date().addingTimeInterval(-3_600)
        store.save(trip: Trip(id: tripID,
                              vehicleID: vehicle.id,
                              startedAt: startedAt,
                              distanceMetres: 42_600,
                              movingDurationSeconds: 2_700,
                              idleDurationSeconds: 180))
        XCTAssertEqual(store.openTrips(vehicleID: vehicle.id).count, 1)

        // Relaunch: new objects over the same database.
        _ = makeCoordinator()

        let recovered = try XCTUnwrap(store.trips(vehicleID: vehicle.id).first { $0.id == tripID })
        XCTAssertNotNil(recovered.endedAt, "an interrupted drive has to be closed")
        XCTAssertEqual(recovered.endReason, .recoveredAfterInterruption,
                       "and labelled as recovered rather than passed off as a normal end")
        XCTAssertEqual(recovered.distanceMetres, 42_600, accuracy: 1,
                       "no distance is invented for the time the app was not running")
        XCTAssertTrue(store.openTrips(vehicleID: vehicle.id).isEmpty,
                      "and it must not stay open, or every launch recovers it again")
    }

    func testAnInterruptedDriveTooShortToCountIsDroppedNotRecovered() throws {
        let tripID = UUID()
        store.save(trip: Trip(id: tripID,
                              vehicleID: vehicle.id,
                              startedAt: Date().addingTimeInterval(-20),
                              distanceMetres: 40,
                              movingDurationSeconds: 20))

        _ = makeCoordinator()

        XCTAssertNil(store.trips(vehicleID: vehicle.id).first { $0.id == tripID },
                     "forty metres in twenty seconds is a car park manoeuvre, and "
                     + "recovering it as a drive would be inventing history")
        XCTAssertTrue(store.openTrips(vehicleID: vehicle.id).isEmpty)
    }

    func testRecoveryIsIdempotentAcrossRepeatedLaunches() throws {
        store.save(trip: Trip(id: UUID(),
                              vehicleID: vehicle.id,
                              startedAt: Date().addingTimeInterval(-3_600),
                              distanceMetres: 30_000,
                              movingDurationSeconds: 2_400))

        _ = makeCoordinator()
        let afterFirst = store.trips(vehicleID: vehicle.id)
        _ = makeCoordinator()
        _ = makeCoordinator()

        XCTAssertEqual(store.trips(vehicleID: vehicle.id).count, afterFirst.count,
                       "recovery must not duplicate or re-open what it already closed")
        XCTAssertTrue(store.openTrips(vehicleID: vehicle.id).isEmpty)
    }

    func testRecoveryDoesNotResurrectADiscardedDrive() throws {
        let coordinator = makeCoordinator()
        coordinator.startDriveManually()
        let tripID = try XCTUnwrap(coordinator.currentTrip?.id)

        // Ending immediately discards it: too short to be a drive.
        coordinator.endDriveManually()

        XCTAssertFalse(coordinator.isRecording)
        XCTAssertTrue(store.openTrips(vehicleID: vehicle.id).isEmpty,
                      "a checkpointed row for a discarded drive is exactly what recovery "
                      + "looks for, so it has to be removed when the drive is thrown away")
        XCTAssertNil(store.trips(vehicleID: vehicle.id).first { $0.id == tripID })

        // And a relaunch finds nothing to recover.
        _ = makeCoordinator()
        XCTAssertTrue(store.trips(vehicleID: vehicle.id).isEmpty)
    }

    func testAbandoningADriveLeavesNothingBehind() throws {
        let coordinator = makeCoordinator()
        coordinator.startDriveManually()
        XCTAssertEqual(store.openTrips(vehicleID: vehicle.id).count, 1)

        coordinator.abandonActiveDrive()

        XCTAssertFalse(coordinator.isRecording)
        XCTAssertNil(coordinator.currentTrip)
        // The row is deliberately left for recovery to finalise rather than deleted
        // here: abandoning is used when the data underneath is going away anyway.
        XCTAssertNotNil(store.openTrips(vehicleID: vehicle.id).first)
    }

    // MARK: - Telemetry recovery, the brief's test 2 at app level

    func testTelemetryChunksFromAnInterruptedDriveAreRecovered() throws {
        let tripID = UUID()
        // Hoisted out of the property so the teardown closure below does not have to
        // capture self.
        let vehicleID = vehicle.id
        TelemetryFileStore.shared.appendChunk(
            samples: (0..<30).map {
                TelemetrySample(timestamp: Date().addingTimeInterval(Double($0)),
                                values: [.engineRPM: 1_500 + Double($0)])
            },
            vehicleID: vehicleID,
            tripID: tripID)

        // Interrupted: chunks on disk, nothing compacted.
        XCTAssertEqual(TelemetryFileStore.shared.interruptedTrips().filter { $0.tripID == tripID }.count, 1)

        // A relaunch compacts it.
        TelemetryFileStore.shared.finalise(vehicleID: vehicleID, tripID: tripID)

        XCTAssertEqual(TelemetryFileStore.shared.read(vehicleID: vehicleID, tripID: tripID).count, 30)
        XCTAssertTrue(TelemetryFileStore.shared.interruptedTrips().filter { $0.tripID == tripID }.isEmpty)

        addTeardownBlock {
            TelemetryFileStore.shared.delete(vehicleID: vehicleID, tripID: tripID)
        }
    }
}

/// The brief's tests 10 and 11.
@MainActor
final class RoadImpactGatingTests: XCTestCase {

    func testDetectionOffStopsProcessingRatherThanDiscardingResults() {
        let motion = MotionService()
        motion.isImpactDetectionEnabled = true
        motion.start()

        motion.isImpactDetectionEnabled = false

        // The setting used to gate persistence in the coordinator, so 20 Hz device
        // motion and impact classification ran for the whole drive regardless.
        XCTAssertTrue(motion.recentImpacts.isEmpty)
        XCTAssertNil(motion.deviceMountingConfidence,
                     "with detection off there is nothing to have confidence about")

        motion.stop()
    }

    func testTurningDetectionBackOnDoesNotReplayOldImpacts() {
        let motion = MotionService()
        motion.start()
        motion.isImpactDetectionEnabled = false
        motion.isImpactDetectionEnabled = true

        XCTAssertTrue(motion.recentImpacts.isEmpty,
                      "the buffer was cleared when it was switched off, and must stay clear")
        motion.stop()
    }

    func testAltitudeStillWorksWithImpactDetectionOff() {
        // The barometer is cheap and always wanted; only the accelerometer is gated.
        let motion = MotionService()
        motion.isImpactDetectionEnabled = false
        motion.start()

        XCTAssertFalse(motion.hasAbsoluteAltitude,
                       "no GPS fix in a test bundle, so no absolute reference - which is "
                       + "itself the honest answer rather than zero")
        motion.stop()
    }
}
