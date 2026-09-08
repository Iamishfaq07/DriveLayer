import XCTest
@testable import DriveLayerCore

final class CarPlayRankingTests: XCTestCase {
    func testStatePrioritiesAreDeterministic() {
        var engine = CarPlayRankingEngine(minimumPresentationLifetime: 0)
        let all = Set(CarPlayTile.allCases)
        XCTAssertEqual(engine.rank(.init(state: .coldStart, available: all), at: .distantPast),
                       [.warmUp, .health, .range, .battery, .currentDrive])
        XCTAssertEqual(engine.rank(.init(state: .lowFuel, available: all), at: Date()),
                       [.range, .destinationReserve, .fuelRecommendation, .health])
    }

    func testRankingHysteresisHoldsDuringMinimumLifetime() {
        let start = Date(timeIntervalSince1970: 10_000)
        var engine = CarPlayRankingEngine(minimumPresentationLifetime: 20)
        let all = Set(CarPlayTile.allCases)
        _ = engine.rank(.init(state: .ordinary, available: all), at: start)
        let urgent = engine.rank(.init(state: .fault, available: all), at: start.addingTimeInterval(5))
        XCTAssertEqual(urgent.first, .fault)
        let held = engine.rank(.init(state: .ordinary, available: all), at: start.addingTimeInterval(6))
        XCTAssertEqual(held.first, .fault)
        let changed = engine.rank(.init(state: .ordinary, available: all), at: start.addingTimeInterval(26))
        XCTAssertEqual(changed.first, .health)
    }

    func testAvailabilityChangeFillsLockedRanking() {
        let start = Date(timeIntervalSince1970: 10_000)
        var engine = CarPlayRankingEngine(minimumPresentationLifetime: 20)
        _ = engine.rank(.init(state: .coldStart), at: start)
        let available: Set<CarPlayTile> = [.health, .range, .currentDrive, .economy]
        let changed = engine.rank(.init(state: .ordinary, available: available),
                                  at: start.addingTimeInterval(2))
        XCTAssertEqual(changed, [.health, .range, .currentDrive, .economy])
    }

    func testStateResolverUsesSafetyFirstPriority() {
        let now = Date(timeIntervalSince1970: 10_000)
        var telemetry = VehicleTelemetry(updatedAt: now)
        telemetry.set(.coolantTemperatureC, value: 30, at: now)
        telemetry.set(.vehicleSpeedKmh, value: 100, at: now)
        let context = InsightContext(now: now, isAdapterConnected: true, telemetry: telemetry,
                                     fuelStatus: FuelIntelligence.status(levelPercent: .measured(5),
                                                                        tankCapacityLitres: nil,
                                                                        economy: nil), isDriving: true)
        XCTAssertEqual(CarPlayStateResolver.resolve(context, insights: []), .lowFuel)
        let fault = DriveInsight(id: "fault", category: .vehicle, severity: .critical,
                                 title: "FAULT", summary: "Fault", createdAt: now)
        XCTAssertEqual(CarPlayStateResolver.resolve(context, insights: [fault]), .fault)
    }
}
