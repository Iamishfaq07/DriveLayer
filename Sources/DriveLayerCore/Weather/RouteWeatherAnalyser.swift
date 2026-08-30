import Foundation

/// Something about the weather ahead that is worth interrupting a driver for.
struct WeatherChange: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable, CaseIterable {
        case precipitationStarting
        case precipitationIntensifying
        case precipitationClearing
        case fogRisk
        case iceRisk
        case strongWind
    }

    var id: String { "\(kind.rawValue)-\(Int(distanceMetres))" }
    var kind: Kind
    var distanceMetres: Double
    var expectedAt: Date
    var band: PrecipitationBand
    var severity: SemanticStatus
    var headline: String
    var detail: String
}

/// Turns a route forecast into at most a couple of things worth saying.
///
/// The rule that shapes this file: a driver does not want twelve weather cards every
/// few kilometres. They want to know when something *changes* — when rain starts,
/// when it gets heavier, when visibility drops. Everything else is noise while
/// driving and is filtered out here rather than in the UI.
enum RouteWeatherAnalyser {

    /// Ignore changes closer than this: there is no useful action left to take.
    static let minimumWarningDistanceMetres: Double = 1_500
    /// Beyond this, conditions will likely have changed before arrival anyway.
    static let horizonMetres: Double = 60_000

    static func changes(current: WeatherSnapshot?, along route: [RouteWeatherPoint]) -> [WeatherChange] {
        let sorted = route
            .filter { $0.distanceMetres >= minimumWarningDistanceMetres && $0.distanceMetres <= horizonMetres }
            .sorted { $0.distanceMetres < $1.distanceMetres }
        guard !sorted.isEmpty else { return [] }

        var results: [WeatherChange] = []
        let startingBand = current?.precipitationBand ?? .none

        // The first place precipitation appears or steps up a band.
        if let onset = sorted.first(where: { $0.snapshot.precipitationBand > startingBand }) {
            let band = onset.snapshot.precipitationBand
            let kind: WeatherChange.Kind = startingBand == .none ? .precipitationStarting : .precipitationIntensifying
            results.append(WeatherChange(
                kind: kind,
                distanceMetres: onset.distanceMetres,
                expectedAt: onset.expectedAt,
                band: band,
                severity: band == .heavy ? .attention : .watch,
                headline: band.displayName.uppercased(),
                detail: String(format: "Expected about %.0f km ahead.", onset.distanceMetres / 1_000)
            ))
        } else if startingBand > .none,
                  let clearing = sorted.first(where: { $0.snapshot.precipitationBand == .none }) {
            results.append(WeatherChange(
                kind: .precipitationClearing,
                distanceMetres: clearing.distanceMetres,
                expectedAt: clearing.expectedAt,
                band: .none,
                severity: .normal,
                headline: "RAIN EASING",
                detail: String(format: "Clearing about %.0f km ahead.", clearing.distanceMetres / 1_000)
            ))
        }

        if let fog = sorted.first(where: { $0.snapshot.suggestsFogRisk }), current?.suggestsFogRisk != true {
            results.append(WeatherChange(
                kind: .fogRisk,
                distanceMetres: fog.distanceMetres,
                expectedAt: fog.expectedAt,
                band: fog.snapshot.precipitationBand,
                severity: .attention,
                headline: "REDUCED VISIBILITY",
                detail: String(format: "Fog or low visibility about %.0f km ahead.", fog.distanceMetres / 1_000)
            ))
        }

        if let ice = sorted.first(where: { $0.snapshot.suggestsIceRisk }) {
            results.append(WeatherChange(
                kind: .iceRisk,
                distanceMetres: ice.distanceMetres,
                expectedAt: ice.expectedAt,
                band: ice.snapshot.precipitationBand,
                severity: .attention,
                headline: "POSSIBLE ICE",
                detail: String(format: "Near-freezing with moisture about %.0f km ahead. Conditions may be slippery.",
                               ice.distanceMetres / 1_000)
            ))
        }

        if let wind = sorted.first(where: { ($0.snapshot.windGustKmh ?? 0) >= 60 }) {
            results.append(WeatherChange(
                kind: .strongWind,
                distanceMetres: wind.distanceMetres,
                expectedAt: wind.expectedAt,
                band: wind.snapshot.precipitationBand,
                severity: .watch,
                headline: "STRONG GUSTS",
                detail: String(format: "Gusts around %.0f km/h about %.0f km ahead.",
                               wind.snapshot.windGustKmh ?? 0, wind.distanceMetres / 1_000)
            ))
        }

        // Nearest first, and never more than two while driving.
        return Array(results.sorted { $0.distanceMetres < $1.distanceMetres }.prefix(2))
    }

    /// Builds route points by walking a polyline at the driver's current speed.
    /// Used to ask a provider for weather where the driver will actually be.
    ///
    /// Stops at `limitMetres`, which defaults to the same horizon `changes` filters to.
    /// Walking the whole road instead would cost the caller one forecast lookup per
    /// ten kilometres of it — thirty for a three-hundred-kilometre drive — and then
    /// discard every result past the first sixty.
    static func waypoints(along polyline: [GeoPoint],
                          from now: Date,
                          averageSpeedKmh: Double,
                          spacingMetres: Double = 10_000,
                          limitMetres: Double = horizonMetres) -> [(point: GeoPoint, distanceMetres: Double, expectedAt: Date)] {
        guard polyline.count >= 2, averageSpeedKmh > 5 else { return [] }
        var results: [(GeoPoint, Double, Date)] = []
        var cumulative: Double = 0
        var nextTarget = spacingMetres
        let metresPerSecond = Convert.metresPerSecond(fromKmh: averageSpeedKmh)

        for index in 1..<polyline.count {
            cumulative += Geo.distance(from: polyline[index - 1], to: polyline[index])
            if cumulative > limitMetres { break }
            if cumulative >= nextTarget {
                let seconds = cumulative / metresPerSecond
                results.append((polyline[index], cumulative, now.addingTimeInterval(seconds)))
                nextTarget += spacingMetres
            }
        }
        return results.map { (point: $0.0, distanceMetres: $0.1, expectedAt: $0.2) }
    }

    /// Re-measures a route forecast against where the driver is now.
    ///
    /// The forecast behind these points is refetched every fifteen minutes; on a
    /// motorway the driver covers twenty-five kilometres in that time. Left alone,
    /// "rain about twenty kilometres ahead" stays on screen long after they have driven
    /// through it, and `minimumWarningDistanceMetres` — which exists to drop warnings
    /// too close to act on — never gets the chance to fire.
    ///
    /// Distance is re-measured *along the polyline*, not straight-line from the driver
    /// to the point: on a road that bends back on itself the straight line is shorter
    /// than the driving distance, and reporting that would be reporting a number the
    /// driver cannot use. Points already behind the driver are dropped.
    static func remeasured(_ points: [RouteWeatherPoint],
                           along polyline: [GeoPoint],
                           from position: GeoPoint) -> [RouteWeatherPoint] {
        guard !points.isEmpty, polyline.count >= 2 else { return points }

        // Cumulative distance to each vertex, on the same measure `waypoints` used, so
        // subtracting one from the other is exact rather than approximate.
        var cumulative: [Double] = [0]
        cumulative.reserveCapacity(polyline.count)
        for index in 1..<polyline.count {
            cumulative.append(cumulative[index - 1] + Geo.distance(from: polyline[index - 1],
                                                                   to: polyline[index]))
        }

        // How far along the road the driver has come: the nearest vertex to them.
        // A vertex every few hundred metres is fine for a filter measured in kilometres.
        var nearestIndex = 0
        var nearestDistance = Double.greatestFiniteMagnitude
        for (index, vertex) in polyline.enumerated() {
            let distance = Geo.distance(from: position, to: vertex)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestIndex = index
            }
        }
        let travelled = cumulative[nearestIndex]

        return points.compactMap { point in
            let remaining = point.distanceMetres - travelled
            guard remaining > 0 else { return nil }
            var moved = point
            moved.distanceMetres = remaining
            return moved
        }
    }
}
