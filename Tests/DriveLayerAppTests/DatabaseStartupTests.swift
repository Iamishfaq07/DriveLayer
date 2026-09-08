import XCTest
import SwiftData

@MainActor
final class DatabaseStartupTests: XCTestCase {
    func testOpeningFailureRemainsUnavailableUntilExplicitRetrySucceeds() throws {
        let schema = Schema(DriveLayerSchema.models)
        let container = try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        var attempts = 0
        let startup = DatabaseStartup {
            attempts += 1
            if attempts == 1 { throw NSError(domain: "StoreLocked", code: 1) }
            return container
        }
        startup.retry()
        XCTAssertNil(startup.container, "Opening failure must not substitute an empty database")
        XCTAssertNotNil(startup.failure)
        XCTAssertEqual(attempts, 1)
        startup.retry()
        XCTAssertTrue(startup.container === container)
        XCTAssertNil(startup.failure)
        startup.retry()
        XCTAssertEqual(attempts, 2, "An open database must not be replaced on repeat presentation")
    }

    func testFutureVersionIsRecognisedEvenWhenPayloadShapeChanged() {
        let bytes = Data("{\"v\":999,\"p\":{\"newShape\":true}}".utf8)
        XCTAssertThrowsError(try StoredCoding.decode(Vehicle.self, from: bytes)) { error in
            XCTAssertEqual(error as? StoredCoding.Failure,
                           .unsupportedVersion(found: 999, supported: StoredCoding.currentVersion))
        }
    }
}
