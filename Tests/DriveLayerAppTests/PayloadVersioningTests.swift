import XCTest
import SwiftData

/// Stored payloads used to carry no version, and every load site turned a payload it
/// could not read into a row that had simply never existed.
///
/// Both halves mattered. Without a version, the first field rename to ship would make
/// every stored drive undecodable; with `compactMap { try? }` underneath, the driver
/// would have opened DriveLayer to an empty history, no error, nothing to recover from.
@MainActor
final class PayloadVersioningTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var store: GarageStore!

    override func setUpWithError() throws {
        let schema = Schema(DriveLayerSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        store = GarageStore(context: context)
    }

    override func tearDownWithError() throws {
        store = nil
        context = nil
        container = nil
    }

    private func makeVehicle(_ nickname: String = "Harrier") -> Vehicle {
        Vehicle(nickname: nickname,
                profileID: SupportedVehicles.defaultProfileID,
                modelYear: 2026,
                odometerKm: 20_000,
                isPrimary: true)
    }

    // MARK: - The envelope

    func testAPayloadRoundTripsThroughItsEnvelope() throws {
        let vehicle = makeVehicle()
        let data = try StoredCoding.encode(vehicle)
        let decoded = try StoredCoding.decode(Vehicle.self, from: data)
        XCTAssertEqual(decoded.id, vehicle.id)
        XCTAssertEqual(decoded.nickname, vehicle.nickname)
    }

    func testAnEncodedPayloadDeclaresTheCurrentVersion() throws {
        let data = try StoredCoding.encode(makeVehicle())
        XCTAssertEqual(StoredCoding.version(of: data), StoredCoding.currentVersion)
    }

    /// The migration case that actually exists today: everything already on a driver's
    /// phone was written before versioning and is a bare payload.
    func testDataWrittenBeforeVersioningStillDecodes() throws {
        let vehicle = makeVehicle("Legacy")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bare = try encoder.encode(vehicle)

        XCTAssertEqual(StoredCoding.version(of: bare), StoredCoding.legacyVersion,
                       "an unversioned payload reports version zero rather than failing")
        let decoded = try StoredCoding.decode(Vehicle.self, from: bare)
        XCTAssertEqual(decoded.nickname, "Legacy", "and a driver keeps their history")
    }

    /// A build that meets a payload from a newer build must refuse it, not guess. Writing
    /// a half-understood value back is how a downgrade destroys data permanently.
    func testAPayloadFromANewerBuildIsRefusedRatherThanGuessedAt() throws {
        let vehicle = makeVehicle()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let inner = try encoder.encode(vehicle)
        let future = StoredCoding.currentVersion + 7
        var envelope = Data("{\"v\":\(future),\"p\":".utf8)
        envelope.append(inner)
        envelope.append(Data("}".utf8))

        XCTAssertThrowsError(try StoredCoding.decode(Vehicle.self, from: envelope)) { error in
            XCTAssertEqual(error as? StoredCoding.Failure,
                           .unsupportedVersion(found: future, supported: StoredCoding.currentVersion))
        }
    }

    // MARK: - Failing loudly rather than deleting

    func testAnUnreadableRowIsCountedAndKeptRatherThanVanishing() throws {
        store.add(vehicle: makeVehicle())
        XCTAssertEqual(store.vehicles().count, 1)

        // Stand in for a payload this build cannot read: a future shape, a migration not
        // yet written, a partial write.
        let stored = try context.fetch(FetchDescriptor<StoredVehicle>())
        let row = try XCTUnwrap(stored.first)
        row.payload = Data("not a vehicle".utf8)
        try context.save()

        XCTAssertTrue(store.vehicles().isEmpty, "it cannot be presented, which is correct")
        XCTAssertEqual(store.undecodablePayloads, 1, "but it is counted rather than silent")
        XCTAssertNotNil(store.lastError, "and surfaced")

        // The important part: the row is still on disk for a build that can read it.
        let survivors = try context.fetch(FetchDescriptor<StoredVehicle>())
        XCTAssertEqual(survivors.count, 1, "an unreadable row must not be deleted")
    }

    func testReadableRowsSurviveAnUnreadableNeighbour() throws {
        store.add(vehicle: makeVehicle("First"))
        store.add(vehicle: makeVehicle("Second"))

        let stored = try context.fetch(FetchDescriptor<StoredVehicle>())
        let doomed = try XCTUnwrap(stored.first { $0.nickname == "First" })
        doomed.payload = Data("corrupt".utf8)
        try context.save()

        let loaded = store.vehicles()
        XCTAssertEqual(loaded.map(\.nickname), ["Second"],
                       "one bad payload must not take the rest of the garage with it")
        XCTAssertEqual(store.undecodablePayloads, 1)
    }
}
