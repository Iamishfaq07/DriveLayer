import Foundation

/// Where the driver said they are going.
///
/// A name and a point, nothing more. DriveLayer is not a navigation app: it wants a
/// destination only so it can ask what the weather does along the way, and holding an
/// address, a place identifier or a search history would be collecting more than the
/// feature needs.
struct RouteDestination: Sendable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var point: GeoPoint

    init(id: UUID = UUID(), name: String, point: GeoPoint) {
        self.id = id
        self.name = name
        self.point = point
    }
}

/// Supplies the shape of the road between two points.
///
/// Declared here so `RouteWeatherAnalyser` can be exercised without MapKit; the real
/// implementation lives in the app target. Returning a bare polyline rather than a
/// route object is deliberate — DriveLayer wants the geometry to sample weather
/// along, and has no use for turn instructions it would then be tempted to show.
protocol RouteProviding: Sendable {
    var isAvailable: Bool { get }

    /// Points along the road from one place to another, in order.
    func polyline(from origin: GeoPoint, to destination: GeoPoint) async throws -> [GeoPoint]
}

enum RouteError: Error, Equatable, Sendable {
    case unavailable
    case noRouteFound
    case offline
}

/// A route provider that returns nothing, used when routing is switched off.
///
/// Named for what it is. A driver who has not set a destination gets no route
/// weather, and the UI says so rather than showing an empty section.
struct UnavailableRouteProvider: RouteProviding {
    var isAvailable: Bool { false }

    func polyline(from origin: GeoPoint, to destination: GeoPoint) async throws -> [GeoPoint] {
        throw RouteError.unavailable
    }
}

/// A straight line between the two points, for tests and the simulator.
///
/// Explicitly *not* a road. It exists so the weather-along-a-route pipeline can be
/// exercised end to end without MapKit, and nothing in the app offers it to a driver
/// as though it were real routing.
struct StraightLineRouteProvider: RouteProviding {
    var stepCount: Int = 24
    var isAvailable: Bool { true }

    func polyline(from origin: GeoPoint, to destination: GeoPoint) async throws -> [GeoPoint] {
        guard stepCount > 1 else { throw RouteError.noRouteFound }
        return (0...stepCount).map { step in
            let fraction = Double(step) / Double(stepCount)
            return GeoPoint(
                latitude: origin.latitude + (destination.latitude - origin.latitude) * fraction,
                longitude: origin.longitude + (destination.longitude - origin.longitude) * fraction,
                timestamp: origin.timestamp
            )
        }
    }
}
