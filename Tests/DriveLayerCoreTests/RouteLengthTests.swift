import XCTest
@testable import DriveLayerCore

private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

/// A route from MapKit carries road geometry, not GPS fixes, and the difference is a
/// trap: `pathDistance` discards points whose accuracy it cannot vouch for, and route
/// geometry has no accuracy at all. Measuring a route with it returns zero, which is
/// the one wrong answer that does not look wrong — a zero-kilometre journey makes the
/// fuel check report the whole tank as spare and tell the driver they can reach
/// anywhere.
final class RouteLengthTests: XCTestCase {

    /// Points as `MapKitRouteProvider` actually builds them: no accuracy, no speed.
    private func routePoints() -> [GeoPoint] {
        // Roughly 1 km apart along a meridian: 0.009° of latitude is about 1 km.
        (0..<5).map { step in
            GeoPoint(latitude: 12.9716 + Double(step) * 0.009,
                     longitude: 77.5946,
                     timestamp: referenceDate)
        }
    }

    func testRouteLengthMeasuresGeometryWithoutAccuracy() {
        let metres = Geo.routeLength(routePoints())
        // Four hops of about a kilometre each.
        XCTAssertEqual(metres / 1_000, 4, accuracy: 0.15)
    }

    /// The regression this pair exists for. If someone later "simplifies" the route
    /// measurement to reuse `pathDistance`, this is what should stop them.
    func testPathDistanceReturnsZeroForRouteGeometry() {
        XCTAssertEqual(Geo.pathDistance(routePoints()), 0, accuracy: 0.001)
    }

    func testRouteLengthIsZeroForATrivialRoute() {
        XCTAssertEqual(Geo.routeLength([]), 0)
        XCTAssertEqual(Geo.routeLength([routePoints()[0]]), 0)
    }

    /// The consequence, stated as a test rather than left in a comment: a route
    /// measured as zero turns an unreachable destination into a comfortable one.
    func testAZeroLengthRouteWouldMisreportReachability() {
        // A quarter tank and a measured economy: enough range for a short hop, nowhere
        // near enough for a long one.
        let status = FuelIntelligence.status(levelPercent: .measured(25),
                                             tankCapacityLitres: 50,
                                             economy: (12.5, .fullTankHistory))
        guard let range = status.estimatedRangeKm.value else {
            return XCTFail("this status is meant to have an estimated range")
        }

        // A journey well beyond the range is correctly refused...
        guard case .insufficient = FuelIntelligence.assessJourney(distanceKm: range * 3, status: status) else {
            return XCTFail("three times the range should be insufficient")
        }
        // ...but the same journey measured as zero reads as comfortable, with the
        // whole remaining range reported as spare. That is the trap, in one assertion.
        guard case let .comfortable(reserve) = FuelIntelligence.assessJourney(distanceKm: 0, status: status) else {
            return XCTFail("a zero-length journey reads as comfortable, which is the trap")
        }
        XCTAssertEqual(reserve, range, accuracy: 0.001)
    }
}
