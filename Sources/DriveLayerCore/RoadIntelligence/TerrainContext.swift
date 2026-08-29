import Foundation

/// A point on an elevation profile along the road ahead.
struct ElevationPoint: Sendable, Equatable, Codable {
    /// Distance from the driver's current position, metres.
    var distanceMetres: Double
    var altitudeMetres: Double
}

/// Supplies elevation along a route.
///
/// DriveLayer ships no elevation dataset of its own and does not pretend to: a
/// provider is either configured or terrain-ahead features stay unavailable. The
/// mock exists for development and previews and says so.
protocol ElevationProviding: Sendable {
    var isConfigured: Bool { get }
    func elevationProfile(along coordinates: [GeoPoint]) async throws -> [ElevationPoint]
}

/// A synthetic profile for development. Never used when a real provider is configured,
/// and every value it produces is marked `.inferred` by the callers that use it.
struct MockElevationProvider: ElevationProviding, Sendable {
    let shape: Shape

    enum Shape: String, CaseIterable, Sendable {
        case flat
        case longClimb
        case longDescent
        case rollingHills
    }

    init(shape: Shape = .longClimb) { self.shape = shape }

    var isConfigured: Bool { true }

    func elevationProfile(along coordinates: [GeoPoint]) async throws -> [ElevationPoint] {
        let baseAltitude = coordinates.first?.altitudeMetres ?? 320
        let step: Double = 250
        let count = 80
        return (0..<count).map { index in
            let distance = Double(index) * step
            let altitude: Double
            switch shape {
            case .flat:
                altitude = baseAltitude
            case .longClimb:
                altitude = baseAltitude + min(distance, 8_400) * 0.055
            case .longDescent:
                altitude = baseAltitude - min(distance, 6_000) * 0.06
            case .rollingHills:
                altitude = baseAltitude + sin(distance / 900) * 45
            }
            return ElevationPoint(distanceMetres: distance, altitudeMetres: altitude)
        }
    }
}

/// A sustained climb or descent found in an elevation profile.
struct TerrainFeature: Sendable, Equatable {
    enum Kind: String, Sendable, Codable {
        case climb
        case descent
    }

    var kind: Kind
    /// Distance from the driver to where the feature begins. Zero when already on it.
    var startsInMetres: Double
    var lengthMetres: Double
    var averageGradientPercent: Double
    var altitudeChangeMetres: Double

    var isUnderway: Bool { startsInMetres < 200 }

    /// The headline a driver reads. Deliberately short and specific.
    var headline: String {
        switch kind {
        case .climb: return isUnderway ? "Long climb" : "Climb ahead"
        case .descent: return isUnderway ? "Steep descent" : "Descent ahead"
        }
    }

    func detail(unitSystem: UnitSystem = .metric) -> String {
        let lengthKm = lengthMetres / 1_000
        let gradient = String(format: "%.1f%%", abs(averageGradientPercent))
        if isUnderway {
            return String(format: "%.1f km remaining at about %@ average.", lengthKm, gradient)
        }
        let startKm = startsInMetres / 1_000
        return String(format: "%.1f km of %@ average, starting in about %.1f km.", lengthKm, gradient, startKm)
    }
}

/// Finds sustained climbs and descents in an elevation profile.
///
/// Short undulations are ignored on purpose. A driver does not need to be told about
/// every bridge; they need to know when the next ten minutes are uphill.
enum TerrainAnalyser {

    /// Minimum length before a slope is worth mentioning.
    static let minimumFeatureLengthMetres: Double = 800
    /// Minimum average gradient before a slope is worth mentioning.
    static let minimumGradientPercent: Double = 2.0

    static func features(in profile: [ElevationPoint]) -> [TerrainFeature] {
        guard profile.count >= 3 else { return [] }
        let sorted = profile.sorted { $0.distanceMetres < $1.distanceMetres }

        var features: [TerrainFeature] = []
        var segmentStart = 0
        var currentKind: TerrainFeature.Kind?

        func closeSegment(endIndex: Int) {
            guard let kind = currentKind, endIndex > segmentStart else { return }
            let start = sorted[segmentStart]
            let end = sorted[endIndex]
            let length = end.distanceMetres - start.distanceMetres
            let rise = end.altitudeMetres - start.altitudeMetres
            guard length >= minimumFeatureLengthMetres,
                  let gradient = Convert.gradientPercent(rise: rise, run: length),
                  abs(gradient) >= minimumGradientPercent else { return }
            features.append(TerrainFeature(kind: kind,
                                           startsInMetres: start.distanceMetres,
                                           lengthMetres: length,
                                           averageGradientPercent: gradient,
                                           altitudeChangeMetres: rise))
        }

        for index in 1..<sorted.count {
            let rise = sorted[index].altitudeMetres - sorted[index - 1].altitudeMetres
            let run = sorted[index].distanceMetres - sorted[index - 1].distanceMetres
            let gradient = Convert.gradientPercent(rise: rise, run: run) ?? 0
            let kind: TerrainFeature.Kind? = gradient >= 1 ? .climb : (gradient <= -1 ? .descent : nil)

            if kind != currentKind {
                closeSegment(endIndex: index - 1)
                currentKind = kind
                segmentStart = index - 1
            }
        }
        closeSegment(endIndex: sorted.count - 1)

        return features.sorted { $0.startsInMetres < $1.startsInMetres }
    }

    /// The one feature worth putting in front of a driver right now, if any.
    static func mostRelevantFeature(in profile: [ElevationPoint], withinMetres horizon: Double = 15_000) -> TerrainFeature? {
        features(in: profile)
            .filter { $0.startsInMetres <= horizon }
            .max { lhs, rhs in relevance(lhs) < relevance(rhs) }
    }

    /// Longer, steeper and nearer wins.
    private static func relevance(_ feature: TerrainFeature) -> Double {
        let proximity = 1.0 / (1.0 + feature.startsInMetres / 3_000)
        return abs(feature.averageGradientPercent) * (feature.lengthMetres / 1_000) * proximity
    }
}
