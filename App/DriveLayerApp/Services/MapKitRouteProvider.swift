import Foundation
import MapKit

/// Road geometry from MapKit.
///
/// DriveLayer asks for a route only to know where the driver will be and roughly
/// when, so it can look up the weather there. It takes the polyline and discards
/// everything else MapKit offers — no turn instructions, no ETA shown to the driver,
/// nothing that would make this look like a navigation app it is not.
///
/// The request goes to Apple's servers, which is why route weather does nothing until
/// a driver sets a destination: it is the one feature here that sends a location off
/// the device, and it happens only when they ask for it.
struct MapKitRouteProvider: RouteProviding {

    var isAvailable: Bool { true }

    func polyline(from origin: GeoPoint, to destination: GeoPoint) async throws -> [GeoPoint] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        request.transportType = .automobile
        // One route. Alternates would only multiply the weather lookups.
        request.requestsAlternateRoutes = false

        let response: MKDirections.Response
        do {
            response = try await MKDirections(request: request).calculate()
        } catch {
            let code = (error as NSError).code
            // MKError.loadingThrottled and .placemarkNotFound both mean "no route
            // now", not "no route ever"; offline is reported separately so the empty
            // state can say something a driver can act on.
            if (error as NSError).domain == NSURLErrorDomain { throw RouteError.offline }
            if code == MKError.loadingThrottled.rawValue { throw RouteError.offline }
            throw RouteError.noRouteFound
        }

        guard let route = response.routes.first else { throw RouteError.noRouteFound }
        return Self.points(from: route.polyline, timestamp: origin.timestamp)
    }

    /// Reads an `MKPolyline`'s coordinates into DriveLayer's own point type.
    ///
    /// `getCoordinates(_:range:)` writes into a buffer the caller owns, so the array
    /// is sized from `pointCount` first.
    static func points(from polyline: MKPolyline, timestamp: Date) -> [GeoPoint] {
        let count = polyline.pointCount
        guard count > 0 else { return [] }
        var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(),
                                                   count: count)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: count))
        return coordinates.map {
            GeoPoint(latitude: $0.latitude, longitude: $0.longitude, timestamp: timestamp)
        }
    }
}

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Finds places by name, so a driver can say where they are going.
///
/// Results are held only for as long as the search sheet is open. DriveLayer keeps
/// the chosen destination's name and coordinate and nothing else — no address, no
/// place identifier, no search history.
@MainActor
@Observable
final class DestinationSearch {

    private(set) var results: [RouteDestination] = []
    private(set) var isSearching = false
    private(set) var failed = false

    private var task: Task<Void, Never>?

    func search(_ query: String, near point: GeoPoint?) {
        task?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            results = []
            isSearching = false
            failed = false
            return
        }

        isSearching = true
        failed = false
        task = Task { [weak self] in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = trimmed
            if let point {
                // Bias towards where the driver is; a search for "the station" means
                // the one near them.
                request.region = MKCoordinateRegion(center: point.coordinate,
                                                    latitudinalMeters: 100_000,
                                                    longitudinalMeters: 100_000)
            }

            let found = try? await MKLocalSearch(request: request).start()
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                self.isSearching = false
                guard let found else {
                    self.failed = true
                    self.results = []
                    return
                }
                self.results = found.mapItems.compactMap { item in
                    guard let name = item.name else { return nil }
                    let coordinate = item.placemark.coordinate
                    return RouteDestination(
                        name: name,
                        point: GeoPoint(latitude: coordinate.latitude,
                                        longitude: coordinate.longitude,
                                        timestamp: Date())
                    )
                }
            }
        }
    }

    func clear() {
        task?.cancel()
        results = []
        isSearching = false
        failed = false
    }
}
