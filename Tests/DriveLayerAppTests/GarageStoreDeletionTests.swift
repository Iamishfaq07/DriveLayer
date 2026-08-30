import XCTest
import SwiftData

/// Covers the deletion paths the core suite cannot reach.
///
/// `swift test` cannot see any of this: `GarageStore` needs SwiftData and
/// `DocumentFileStore` needs a real directory, so before this target existed the only
/// evidence that vehicle deletion worked was that it compiled — which is exactly how
/// it came to delete the document rows and leave the scanned files behind.
@MainActor
final class GarageStoreDeletionTests: XCTestCase {

    private var store: GarageStore!

    override func setUpWithError() throws {
        let schema = Schema(DriveLayerSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        store = GarageStore(context: ModelContext(container))
    }

    override func tearDownWithError() throws {
        store = nil
    }

    private func makeVehicle(_ nickname: String = "Harrier") -> Vehicle {
        Vehicle(nickname: nickname,
                profileID: SupportedVehicles.defaultProfileID,
                modelYear: 2026,
                odometerKm: 12_000,
                isPrimary: true)
    }

    /// A document with a real file behind it, as the scanner would produce.
    private func addDocument(to vehicleID: UUID, kind: DocumentKind) throws -> (UUID, String) {
        let id = UUID()
        let fileName = try XCTUnwrap(
            DocumentFileStore.shared.store(data: Data("scanned page".utf8),
                                           documentID: id,
                                           fileExtension: "jpg"))
        store.add(document: DocumentRecord(id: id,
                                          vehicleID: vehicleID,
                                          kind: kind,
                                          title: "Test document",
                                          fileName: fileName))
        return (id, fileName)
    }

    // MARK: - The brief's test 5

    func testDeletingAVehicleRemovesItsScannedFiles() throws {
        let vehicle = makeVehicle()
        store.add(vehicle: vehicle)
        let (insuranceID, insuranceFile) = try addDocument(to: vehicle.id, kind: .insurance)
        let (rcID, rcFile) = try addDocument(to: vehicle.id, kind: .registration)

        XCTAssertEqual(store.documents(vehicleID: vehicle.id).count, 2)
        XCTAssertNotNil(DocumentFileStore.shared.read(fileName: insuranceFile))
        XCTAssertNotNil(DocumentFileStore.shared.read(fileName: rcFile))

        store.delete(vehicleID: vehicle.id)

        // Database empty.
        XCTAssertTrue(store.vehicles().isEmpty)
        XCTAssertTrue(store.documents(vehicleID: vehicle.id).isEmpty)

        // And the files actually gone, which is the part that used to fail. An
        // insurance policy and a registration certificate are precisely what a driver
        // means when they say delete.
        XCTAssertNil(DocumentFileStore.shared.read(fileName: insuranceFile),
                     "the insurance scan outlived the vehicle before this was fixed")
        XCTAssertNil(DocumentFileStore.shared.read(fileName: rcFile))

        addTeardownBlock {
            DocumentFileStore.shared.delete(documentID: insuranceID)
            DocumentFileStore.shared.delete(documentID: rcID)
        }
    }

    func testDeletingAVehicleLeavesAnotherVehiclesFilesAlone() throws {
        let keep = makeVehicle("Keep")
        let remove = makeVehicle("Remove")
        store.add(vehicle: keep)
        store.add(vehicle: remove)
        let (keepID, keepFile) = try addDocument(to: keep.id, kind: .insurance)
        let (removeID, removeFile) = try addDocument(to: remove.id, kind: .insurance)

        store.delete(vehicleID: remove.id)

        XCTAssertNil(DocumentFileStore.shared.read(fileName: removeFile))
        XCTAssertNotNil(DocumentFileStore.shared.read(fileName: keepFile),
                        "deleting one vehicle must not take another's documents")
        XCTAssertEqual(store.documents(vehicleID: keep.id).count, 1)

        addTeardownBlock {
            DocumentFileStore.shared.delete(documentID: keepID)
            DocumentFileStore.shared.delete(documentID: removeID)
        }
    }

    func testDeletingASingleDocumentRemovesItsFile() throws {
        let vehicle = makeVehicle()
        store.add(vehicle: vehicle)
        let (id, fileName) = try addDocument(to: vehicle.id, kind: .pollutionCertificate)

        store.delete(documentID: id)

        XCTAssertTrue(store.documents(vehicleID: vehicle.id).isEmpty)
        XCTAssertNil(DocumentFileStore.shared.read(fileName: fileName))
    }

    // MARK: - The brief's test 8

    func testDeleteEverythingRemovesTelemetryAndDocumentFiles() throws {
        let vehicle = makeVehicle()
        store.add(vehicle: vehicle)
        let (documentID, fileName) = try addDocument(to: vehicle.id, kind: .insurance)

        let tripID = UUID()
        TelemetryFileStore.shared.appendChunk(
            samples: [TelemetrySample(timestamp: Date(), values: [.engineRPM: 1_500])],
            vehicleID: vehicle.id,
            tripID: tripID)
        TelemetryFileStore.shared.finalise(vehicleID: vehicle.id, tripID: tripID)
        XCTAssertFalse(TelemetryFileStore.shared.read(vehicleID: vehicle.id, tripID: tripID).isEmpty)

        store.deleteEverything()

        XCTAssertTrue(store.vehicles().isEmpty)
        XCTAssertTrue(TelemetryFileStore.shared.read(vehicleID: vehicle.id, tripID: tripID).isEmpty)
        XCTAssertNil(DocumentFileStore.shared.read(fileName: fileName))

        addTeardownBlock { DocumentFileStore.shared.delete(documentID: documentID) }
    }

    /// `deleteEverything` used to remove the directory itself, and both stores hold a
    /// resolved `lazy var` URL to it — so the next write went nowhere, silently.
    func testStoresAreStillUsableAfterDeletingEverything() throws {
        let vehicle = makeVehicle()
        store.add(vehicle: vehicle)
        store.deleteEverything()

        let tripID = UUID()
        TelemetryFileStore.shared.appendChunk(
            samples: [TelemetrySample(timestamp: Date(), values: [.engineRPM: 1_200])],
            vehicleID: vehicle.id,
            tripID: tripID)

        XCTAssertFalse(TelemetryFileStore.shared.read(vehicleID: vehicle.id, tripID: tripID).isEmpty,
                       "writing after a delete-all must still land somewhere real")

        addTeardownBlock { TelemetryFileStore.shared.delete(vehicleID: vehicle.id, tripID: tripID) }
    }

    // MARK: - The brief's test 9

    func testRetentionDeletesExpiredTelemetryThroughTheAppStore() throws {
        let vehicle = makeVehicle()
        let oldTrip = UUID()
        let recentTrip = UUID()
        for tripID in [oldTrip, recentTrip] {
            TelemetryFileStore.shared.appendChunk(
                samples: [TelemetrySample(timestamp: Date(), values: [.engineRPM: 1_000])],
                vehicleID: vehicle.id,
                tripID: tripID)
            TelemetryFileStore.shared.finalise(vehicleID: vehicle.id, tripID: tripID)
        }

        // Retention works on file dates, so the old drive's file has to look old.
        let journal = TelemetryJournal(root: try telemetryRoot())
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-400 * 24 * 3_600)],
            ofItemAtPath: journal.compactedURL(vehicleID: vehicle.id, tripID: oldTrip).path)

        let cutoff = Date().addingTimeInterval(-180 * 24 * 3_600)
        XCTAssertGreaterThanOrEqual(TelemetryFileStore.shared.deleteCompacted(olderThan: cutoff), 1)

        XCTAssertTrue(TelemetryFileStore.shared.read(vehicleID: vehicle.id, tripID: oldTrip).isEmpty,
                      "this is what 'keep engine samples for 180 days' has to mean")
        XCTAssertFalse(TelemetryFileStore.shared.read(vehicleID: vehicle.id, tripID: recentTrip).isEmpty,
                       "and it must not touch anything inside the window")

        addTeardownBlock {
            TelemetryFileStore.shared.delete(vehicleID: vehicle.id, tripID: recentTrip)
        }
    }

    /// Retention must not touch the learned baselines. That inversion is what P0-6 was.
    func testRetentionLeavesLearnedBaselinesAlone() throws {
        let vehicle = makeVehicle()
        store.add(vehicle: vehicle)
        let aggregate = BaselineDailyAggregate(
            key: BaselineKey(metric: .coolantTemperatureC, context: .any),
            dayStart: Date().addingTimeInterval(-400 * 24 * 3_600),
            firstValue: 90)
        store.merge(aggregates: [aggregate], vehicleID: vehicle.id)
        XCTAssertFalse(store.baselineAggregates(vehicleID: vehicle.id).isEmpty)

        TelemetryFileStore.shared.deleteCompacted(olderThan: Date())

        XCTAssertFalse(store.baselineAggregates(vehicleID: vehicle.id).isEmpty,
                       "months of learning must survive a driver reclaiming disk space")
    }

    func testResettingLearningDropsBaselinesAndNothingElse() throws {
        let vehicle = makeVehicle()
        store.add(vehicle: vehicle)
        store.merge(aggregates: [BaselineDailyAggregate(
            key: BaselineKey(metric: .coolantTemperatureC, context: .any),
            dayStart: Date(),
            firstValue: 90)],
                    vehicleID: vehicle.id)

        store.deleteBaselines(vehicleID: vehicle.id)

        XCTAssertTrue(store.baselineAggregates(vehicleID: vehicle.id).isEmpty)
        XCTAssertEqual(store.vehicles().count, 1, "the car itself is not the learning")
    }

    private func telemetryRoot() throws -> URL {
        var base = try XCTUnwrap(FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        base.appendPathComponent("DriveLayer/Telemetry", isDirectory: true)
        return base
    }
}
