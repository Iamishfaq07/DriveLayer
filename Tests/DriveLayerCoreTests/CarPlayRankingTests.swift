import XCTest
@testable import DriveLayerCore

final class CarPlayRankingTests: XCTestCase {
    func testStatePrioritiesAreDeterministic() {
        var engine = CarPlayRankingEngine(minimumPresentationLifetime: 0)
        let all = Set(CarPlayTile.allCases)
        XCTAssertEqual(engine.rank(.init(state: .coldStart, available: all), at: .distantPast),
                       [.warmUp, .health, .range, .currentDrive])
        XCTAssertEqual(engine.rank(.init(state: .lowFuel, available: all), at: Date()),
                       [.range, .destinationReserve, .fuelRecommendation, .health])
    }

    func testRankingHysteresisHoldsDuringMinimumLifetime() {
        let start = Date(timeIntervalSince1970: 10_000)
        var engine = CarPlayRankingEngine(minimumPresentationLifetime: 20)
        let all = Set(CarPlayTile.allCases)
        let first = engine.rank(.init(state: .ordinary, available: all), at: start)
        let held = engine.rank(.init(state: .fault, available: all), at: start.addingTimeInterval(5))
        XCTAssertEqual(held, first)
        let changed = engine.rank(.init(state: .fault, available: all), at: start.addingTimeInterval(21))
        XCTAssertEqual(changed.first, .fault)
    }
}
