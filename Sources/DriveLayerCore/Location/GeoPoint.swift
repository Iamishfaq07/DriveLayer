import Foundation

/// A location fix, independent of CoreLocation so trip and terrain maths can be
/// tested without a device.
struct GeoPoint: Codable, Sendable, Equatable {
    var latitude: Double
    var longitude: Double
    var altitudeMetres: Double?
    var horizontalAccuracyMetres: Double?
    var verticalAccuracyMetres: Double?
    var speedMetresPerSecond: Double?
    var courseDegrees: Double?
    var timestamp: Date

    init(latitude: Double,
         longitude: Double,
         altitudeMetres: Double? = nil,
         horizontalAccuracyMetres: Double? = nil,
         verticalAccuracyMetres: Double? = nil,
         speedMetresPerSecond: Double? = nil,
         courseDegrees: Double? = nil,
         timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMetres = altitudeMetres
        self.horizontalAccuracyMetres = horizontalAccuracyMetres
        self.verticalAccuracyMetres = verticalAccuracyMetres
        // CoreLocation reports -1 for an unknown speed or course; that is not a value.
        self.speedMetresPerSecond = (speedMetresPerSecond ?? -1) < 0 ? nil : speedMetresPerSecond
        self.courseDegrees = (courseDegrees ?? -1) < 0 ? nil : courseDegrees
        self.timestamp = timestamp
    }

    /// Fixes worse than this are not trustworthy enough to extend a route with.
    static let usableHorizontalAccuracyMetres: Double = 50

    var isUsableForRouting: Bool {
        guard let horizontalAccuracyMetres else { return false }
        return horizontalAccuracyMetres > 0 && horizontalAccuracyMetres <= Self.usableHorizontalAccuracyMetres
    }

    /// Rounded for logging. Precise coordinates never appear in logs.
    var coarseDescription: String {
        PrivacyLog.coarse(latitude: latitude, longitude: longitude)
    }
}

enum Geo {
    /// Mean Earth radius, metres.
    static let earthRadiusMetres: Double = 6_371_008.8

    static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

    /// Great-circle distance in metres.
    static func distance(from start: GeoPoint, to end: GeoPoint) -> Double {
        distance(fromLatitude: start.latitude, longitude: start.longitude,
                 toLatitude: end.latitude, longitude: end.longitude)
    }

    static func distance(fromLatitude lat1: Double, longitude lon1: Double,
                         toLatitude lat2: Double, longitude lon2: Double) -> Double {
        let phi1 = radians(lat1)
        let phi2 = radians(lat2)
        let deltaPhi = radians(lat2 - lat1)
        let deltaLambda = radians(lon2 - lon1)
        let a = sin(deltaPhi / 2) * sin(deltaPhi / 2)
            + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
        let c = 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
        return earthRadiusMetres * c
    }

    /// Initial bearing in degrees, 0 = north.
    static func bearing(from start: GeoPoint, to end: GeoPoint) -> Double {
        let phi1 = radians(start.latitude)
        let phi2 = radians(end.latitude)
        let deltaLambda = radians(end.longitude - start.longitude)
        let y = sin(deltaLambda) * cos(phi2)
        let x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(deltaLambda)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Length of a *drawn route* in metres: plain geometry, summed as given.
    ///
    /// Deliberately not `pathDistance`, and the difference matters enough to be worth
    /// a function of its own. `pathDistance` measures a recorded GPS trace, so it
    /// discards fixes whose accuracy it cannot vouch for — and a route from MapKit is
    /// not a trace. Its points are road geometry with no accuracy attached at all,
    /// which `isUsableForRouting` rejects outright, so `pathDistance` returns exactly
    /// zero for every route ever handed to it.
    ///
    /// Zero would not have failed loudly. It would have fed a zero-kilometre journey
    /// into the fuel reserve check, which then reports the whole tank as spare and
    /// tells the driver they can reach anywhere. Hence a separate name, and this note.
    static func routeLength(_ points: [GeoPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { $0 + distance(from: $1.0, to: $1.1) }
    }

    /// Total path length in metres, skipping fixes too inaccurate to trust and jumps
    /// that are physically impossible for a road vehicle.
    static func pathDistance(_ points: [GeoPoint], maximumPlausibleSpeedMetresPerSecond: Double = 90) -> Double {
        var total: Double = 0
        var previous: GeoPoint?
        for point in points {
            guard point.isUsableForRouting else { continue }
            defer { previous = point }
            guard let last = previous else { continue }
            let metres = distance(from: last, to: point)
            let seconds = point.timestamp.timeIntervalSince(last.timestamp)
            if seconds > 0, metres / seconds > maximumPlausibleSpeedMetresPerSecond { continue }
            total += metres
        }
        return total
    }
}
