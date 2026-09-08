import XCTest
@testable import DriveLayerCore

final class WarmUpSessionTrackerTests: XCTestCase {
    func testCompletedRealWarmUpProducesOneObservation() throws {
        var tracker = WarmUpSessionTracker()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(tracker.ingest(at: start,
                                    coolant: .measured(30, at: start),
                                    ambient: .measured(25, at: start),
                                    rpm: 900, speedKmh: 0, engineRunning: true, profile: nil))
        let end = start.addingTimeInterval(300)
        let result = tracker.ingest(at: end,
                                    coolant: .measured(82, at: end),
                                    ambient: .measured(25, at: end),
                                    rpm: 1_800, speedKmh: 60, engineRunning: true, profile: nil)
        let observation = try XCTUnwrap(result)
        XCTAssertEqual(observation.secondsToOperating, 300)
        XCTAssertEqual(observation.startingCoolantC, 30)
        XCTAssertEqual(observation.ambientC, 25)
        XCTAssertGreaterThan(observation.distanceKm ?? 0, 0)
    }

    func testSimulatedCoolantCannotEnterWarmUpHistory() {
        var tracker = WarmUpSessionTracker()
        let now = Date()
        XCTAssertNil(tracker.ingest(at: now,
                                    coolant: Provenanced(value: 30, provenance: .simulated, timestamp: now),
                                    ambient: Provenanced(value: 25, provenance: .simulated, timestamp: now),
                                    rpm: 900, speedKmh: 0, engineRunning: true, profile: nil))
        XCTAssertNil(tracker.ingest(at: now.addingTimeInterval(300),
                                    coolant: Provenanced(value: 82, provenance: .simulated,
                                                        timestamp: now.addingTimeInterval(300)),
                                    ambient: Provenanced(value: 25, provenance: .simulated, timestamp: now),
                                    rpm: 1_800, speedKmh: 60, engineRunning: true, profile: nil))
    }

    func testEngineStopDiscardsInterruptedWarmUp() {
        var tracker = WarmUpSessionTracker()
        let start = Date()
        _ = tracker.ingest(at: start, coolant: .measured(30, at: start), ambient: .unavailable(),
                           rpm: 900, speedKmh: 0, engineRunning: true, profile: nil)
        _ = tracker.ingest(at: start.addingTimeInterval(30), coolant: .measured(40, at: start), ambient: .unavailable(),
                           rpm: 0, speedKmh: 0, engineRunning: false, profile: nil)
        XCTAssertNil(tracker.ingest(at: start.addingTimeInterval(60), coolant: .measured(82, at: start), ambient: .unavailable(),
                                    rpm: 900, speedKmh: 0, engineRunning: true, profile: nil))
    }
}
