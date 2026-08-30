import XCTest
import SwiftData

/// Telemetry journals on disk versus the drives the database knows about.
///
/// Two of the three cases were handled. The third — a journal whose drive is not in the
/// database at all — was handled nowhere: nothing enumerated the journal directory and
/// compared it against known drives, and retention deliberately leaves journalled chunks
/// alone, so an orphan stayed for the life of the install.
///
/// `TelemetryFileStore.interruptedTrips()` existed for precisely this and said so in its
/// own doc comment. It had no production caller.
@MainActor
final class JournalReconciliationTests: XCTestCase {

    private var container: ModelContainer!
    private var settings: AppSettings!
    private var environment: AppEnvironment!
    private var createdJournals: [(vehicleID: UUID, tripID: UUID)] = []

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        let schema = Schema(DriveLayerSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        let suiteName = "drivelayer.tests.\(UUID().uuidString)"
        settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        environment = AppEnvironment(container: container, settings: settings)
    }

    override func tearDownWithError() throws {
        for journal in createdJournals {
            TelemetryFileStore.shared.discardJournal(vehicleID: journal.vehicleID, tripID: journal.tripID)
            TelemetryFileStore.shared.delete(vehicleID: journal.vehicleID, tripID: journal.tripID)
        }
        createdJournals = []
        environment = nil
        settings = nil
        container = nil
    }

    private func writeJournal(vehicleID: UUID, tripID: UUID) {
        let samples = (0..<5).map { index in
            TelemetrySample(timestamp: start.addingTimeInterval(Double(index)),
                            values: [.engineRPM: Double(1_000 + index)])
        }
        TelemetryFileStore.shared.appendChunk(samples: samples, vehicleID: vehicleID, tripID: tripID)
        createdJournals.append((vehicleID: vehicleID, tripID: tripID))
    }

    private func journalExists(tripID: UUID) -> Bool {
        TelemetryFileStore.shared.interruptedTrips().contains { $0.tripID == tripID }
    }

    // MARK: - Case 3: a journal with no drive

    func testAnOrphanJournalIsRemovedOnceItIsOldEnough() {
        let vehicleID = UUID()
        let tripID = UUID()
        writeJournal(vehicleID: vehicleID, tripID: tripID)
        XCTAssertTrue(journalExists(tripID: tripID))
        XCTAssertNil(environment.store.trip(id: tripID), "no drive row: this is the orphan case")

        // Three days later, well past the grace period.
        environment.reconcileTelemetryJournals(now: Date().addingTimeInterval(72 * 3_600))

        XCTAssertFalse(journalExists(tripID: tripID), "the orphan is gone")
        XCTAssertEqual(environment.reconciledOrphanJournals, 1, "and it is counted")
    }

    /// The safety property that matters most: a journal being written right now belongs to
    /// a live drive, and reconciliation must never be able to delete one.
    func testARecentJournalIsLeftAloneEvenWithNoDriveRow() {
        let vehicleID = UUID()
        let tripID = UUID()
        writeJournal(vehicleID: vehicleID, tripID: tripID)

        environment.reconcileTelemetryJournals(now: Date())

        XCTAssertTrue(journalExists(tripID: tripID),
                      "a journal written moments ago is a drive in progress, not litter")
        XCTAssertEqual(environment.reconciledOrphanJournals, 0)
    }

    // MARK: - Cases 1 and 2: a journal whose drive is known

    func testAJournalBelongingToAKnownDriveIsKept() throws {
        let vehicle = Vehicle(nickname: "Harrier",
                              profileID: SupportedVehicles.defaultProfileID,
                              modelYear: 2026,
                              odometerKm: 20_000,
                              isPrimary: true)
        environment.store.add(vehicle: vehicle)
        environment.reloadVehicles()

        environment.drive.startDriveManually()
        let tripID = try XCTUnwrap(environment.drive.currentTrip?.id)
        writeJournal(vehicleID: vehicle.id, tripID: tripID)

        // Far in the future, so the grace period cannot be what saves it.
        environment.reconcileTelemetryJournals(now: Date().addingTimeInterval(365 * 24 * 3_600))

        XCTAssertTrue(journalExists(tripID: tripID),
                      "the drive is in the database, so its telemetry is not an orphan")
        XCTAssertEqual(environment.reconciledOrphanJournals, 0)

        environment.drive.abandonActiveDrive()
    }

    /// A row that exists but will not decode is emphatically not an orphan: a later build
    /// may still recover the drive, and its telemetry has to outlive this one.
    func testAJournalIsKeptWhenItsDriveRowExistsButCannotBeDecoded() throws {
        let vehicle = Vehicle(nickname: "Harrier",
                              profileID: SupportedVehicles.defaultProfileID,
                              modelYear: 2026,
                              odometerKm: 20_000,
                              isPrimary: true)
        environment.store.add(vehicle: vehicle)
        environment.reloadVehicles()
        environment.drive.startDriveManually()
        let tripID = try XCTUnwrap(environment.drive.currentTrip?.id)
        writeJournal(vehicleID: vehicle.id, tripID: tripID)
        environment.drive.checkpoint(force: true)

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<StoredTrip>(predicate: #Predicate { $0.id == tripID }))
        let row = try XCTUnwrap(rows.first)
        row.payload = Data("a payload this build cannot read".utf8)
        try context.save()

        XCTAssertNil(environment.store.trip(id: tripID), "it will not decode")
        XCTAssertTrue(environment.store.tripRowExists(id: tripID), "but it is still there")

        environment.reconcileTelemetryJournals(now: Date().addingTimeInterval(365 * 24 * 3_600))

        XCTAssertTrue(journalExists(tripID: tripID),
                      "undecodable is not the same as absent, and deleting here is irreversible")
        XCTAssertEqual(environment.reconciledOrphanJournals, 0)

        environment.drive.abandonActiveDrive()
    }
}
