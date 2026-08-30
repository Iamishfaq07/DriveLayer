import XCTest
@testable import DriveLayerCore

final class DeepLinkTests: XCTestCase {

    func testEveryLinkRoundTripsThroughItsURL() {
        for link in DeepLink.allCases {
            XCTAssertEqual(DeepLink(url: link.url), link, "\(link.rawValue) did not survive its own URL")
        }
    }

    func testHostAndPathFormsAreBothAccepted() throws {
        let host = try XCTUnwrap(URL(string: "drivelayer://maintenance"))
        let path = try XCTUnwrap(URL(string: "drivelayer:///maintenance"))
        XCTAssertEqual(DeepLink(url: host), .maintenance)
        XCTAssertEqual(DeepLink(url: path), .maintenance)
    }

    func testSchemeIsCaseInsensitive() throws {
        let url = try XCTUnwrap(URL(string: "DriveLayer://Fuel"))
        XCTAssertEqual(DeepLink(url: url), .fuel)
    }

    /// A link DriveLayer does not recognise opens nothing. Falling back to a default
    /// screen would mean a mistyped link silently takes the driver somewhere.
    func testUnknownDestinationIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "drivelayer://tune-engine"))
        XCTAssertNil(DeepLink(url: url))
    }

    func testForeignSchemesAreRejected() throws {
        let https = try XCTUnwrap(URL(string: "https://drivelayer.app/maintenance"))
        let other = try XCTUnwrap(URL(string: "someotherapp://maintenance"))
        XCTAssertNil(DeepLink(url: https))
        XCTAssertNil(DeepLink(url: other))
    }

    /// The last-drive link names an intent, not a record. Carrying a trip UUID in a
    /// URL would let a widget open a drive that has since been deleted, or a stale
    /// one when a newer drive has finished.
    func testLastDriveLinkCarriesNoIdentifier() throws {
        XCTAssertEqual(DeepLink.lastTrip.url.absoluteString, "drivelayer://last-drive")
        let url = try XCTUnwrap(URL(string: "drivelayer://last-drive"))
        XCTAssertEqual(DeepLink(url: url), .lastTrip)
    }

    func testBareSchemeIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "drivelayer://"))
        XCTAssertNil(DeepLink(url: url))
    }
}

final class RouteProviderTests: XCTestCase {

    private let origin = GeoPoint(latitude: 12.90, longitude: 77.50, timestamp: Date())
    private let destination = GeoPoint(latitude: 13.10, longitude: 77.70, timestamp: Date())

    /// A driver with no destination gets no route weather, and the provider says so
    /// rather than returning an empty polyline that would read as "no weather ahead".
    func testUnavailableProviderThrowsRatherThanReturningNothing() async {
        let provider = UnavailableRouteProvider()
        XCTAssertFalse(provider.isAvailable)
        do {
            _ = try await provider.polyline(from: origin, to: destination)
            XCTFail("an unavailable provider must not return a route")
        } catch {
            XCTAssertEqual(error as? RouteError, .unavailable)
        }
    }

    func testStraightLineProviderSpansOriginToDestination() async throws {
        let points = try await StraightLineRouteProvider(stepCount: 10)
            .polyline(from: origin, to: destination)
        XCTAssertEqual(points.count, 11)
        XCTAssertEqual(points.first?.latitude ?? 0, origin.latitude, accuracy: 0.000_1)
        XCTAssertEqual(points.last?.latitude ?? 0, destination.latitude, accuracy: 0.000_1)
        XCTAssertEqual(points.last?.longitude ?? 0, destination.longitude, accuracy: 0.000_1)
    }

    /// The pipeline the app runs: a route becomes waypoints spaced along it, each
    /// with the time the driver is expected to be there.
    func testWaypointsAlongARouteCarryDistanceAndArrivalTime() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let points = try await StraightLineRouteProvider(stepCount: 200)
            .polyline(from: origin, to: destination)
        let waypoints = RouteWeatherAnalyser.waypoints(along: points,
                                                       from: now,
                                                       averageSpeedKmh: 60,
                                                       spacingMetres: 10_000)
        XCTAssertFalse(waypoints.isEmpty, "a ~30 km route should yield waypoints at 10 km spacing")

        for (index, waypoint) in waypoints.enumerated() {
            XCTAssertGreaterThan(waypoint.distanceMetres, 0)
            XCTAssertGreaterThan(waypoint.expectedAt, now, "a waypoint ahead is reached later than now")
            if index > 0 {
                XCTAssertGreaterThan(waypoint.distanceMetres, waypoints[index - 1].distanceMetres)
                XCTAssertGreaterThan(waypoint.expectedAt, waypoints[index - 1].expectedAt)
            }
        }
    }

    /// Standing still, there is no "ahead" and no honest arrival time for a point
    /// down the road, so the builder produces nothing rather than dividing by a speed
    /// it does not have.
    func testStationaryDriverGetsNoWaypoints() async throws {
        let points = try await StraightLineRouteProvider(stepCount: 200)
            .polyline(from: origin, to: destination)
        XCTAssertTrue(RouteWeatherAnalyser.waypoints(along: points,
                                                     from: Date(),
                                                     averageSpeedKmh: 0).isEmpty)
    }

    func testRouteShorterThanTheSpacingYieldsNoWaypoints() async throws {
        let nearby = GeoPoint(latitude: 12.905, longitude: 77.505, timestamp: Date())
        let points = try await StraightLineRouteProvider().polyline(from: origin, to: nearby)
        XCTAssertTrue(RouteWeatherAnalyser.waypoints(along: points,
                                                     from: Date(),
                                                     averageSpeedKmh: 60).isEmpty,
                      "a drive shorter than the sampling spacing has nothing to forecast")
    }
}
