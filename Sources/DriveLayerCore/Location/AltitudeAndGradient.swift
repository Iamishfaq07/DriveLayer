import Foundation

enum AltitudeSource: String, Codable, CaseIterable, Sendable {
    /// From the GPS fix. Cheap, always available, vertically noisy.
    case satellite
    /// From the barometer, which is far more sensitive to change but drifts with weather.
    case barometricRelative
    /// Barometric change anchored to satellite altitude.
    case fused

    var typicalAccuracyMetres: Double {
        switch self {
        case .satellite: return 10
        case .barometricRelative: return 1
        case .fused: return 3
        }
    }
}

struct AltitudeSample: Codable, Sendable, Equatable {
    var altitudeMetres: Double
    var accuracyMetres: Double
    var source: AltitudeSource
    var timestamp: Date
}

/// A gradient estimate, always labelled as an estimate with a confidence, because
/// road gradient derived from consumer GPS is exactly that.
struct GradientEstimate: Sendable, Equatable {
    var percent: Double
    var overDistanceMetres: Double
    var altitudeChangeMetres: Double
    /// 0...1. Low when the altitude change is small relative to sensor accuracy.
    var confidence: Double

    var isClimb: Bool { percent >= 2.0 }
    var isDescent: Bool { percent <= -2.0 }

    /// Wording used in the UI. Deliberately avoids implying survey-grade accuracy.
    var shortDescription: String {
        let magnitude = abs(percent)
        let direction = percent >= 0 ? "climb" : "descent"
        return String(format: "%.1f%% %@", magnitude, direction)
    }
}

/// Turns a stream of fixes into a smoothed road gradient.
///
/// Two decisions matter here. Gradient is only reported over a minimum travelled
/// distance, because dividing a noisy altitude delta by a few metres of travel
/// produces nonsense. And confidence falls as the altitude change approaches sensor
/// accuracy, so the insight layer can stay quiet instead of announcing a "climb"
/// that is really GPS drift.
struct GradientCalculator: Sendable {

    struct Entry: Sendable, Equatable {
        var cumulativeDistanceMetres: Double
        var altitudeMetres: Double
        var accuracyMetres: Double
        var timestamp: Date
    }

    /// Distance over which the gradient is measured.
    let windowMetres: Double
    /// Below this the calculator reports nothing rather than guessing.
    let minimumWindowMetres: Double

    private(set) var entries: [Entry] = []
    private var cumulativeDistance: Double = 0
    private var lastPoint: GeoPoint?

    init(windowMetres: Double = 250, minimumWindowMetres: Double = 120) {
        self.windowMetres = windowMetres
        self.minimumWindowMetres = minimumWindowMetres
    }

    mutating func reset() {
        entries.removeAll()
        cumulativeDistance = 0
        lastPoint = nil
    }

    mutating func add(point: GeoPoint, altitude: AltitudeSample?) {
        if let last = lastPoint, point.isUsableForRouting, last.isUsableForRouting {
            cumulativeDistance += Geo.distance(from: last, to: point)
        }
        if point.isUsableForRouting { lastPoint = point }

        let altitudeMetres = altitude?.altitudeMetres ?? point.altitudeMetres
        guard let altitudeMetres else { return }
        let accuracy = altitude?.accuracyMetres
            ?? point.verticalAccuracyMetres
            ?? AltitudeSource.satellite.typicalAccuracyMetres

        entries.append(Entry(cumulativeDistanceMetres: cumulativeDistance,
                             altitudeMetres: altitudeMetres,
                             accuracyMetres: max(0.5, accuracy),
                             timestamp: point.timestamp))

        // Keep a little more than the window so the oldest entry brackets it.
        let cutoff = cumulativeDistance - windowMetres * 1.5
        entries.removeAll { $0.cumulativeDistanceMetres < cutoff }
    }

    /// The current gradient, or `nil` when there is not enough travel to say.
    var current: GradientEstimate? {
        guard entries.count >= 3, let newest = entries.last else { return nil }
        let target = newest.cumulativeDistanceMetres - windowMetres
        guard let oldest = entries.first(where: { $0.cumulativeDistanceMetres >= target }) ?? entries.first else {
            return nil
        }
        let run = newest.cumulativeDistanceMetres - oldest.cumulativeDistanceMetres
        guard run >= minimumWindowMetres else { return nil }

        // Median-filter each end so one bad altitude sample cannot define the gradient.
        let startAltitude = Statistics.median(entries.prefix(3).map(\.altitudeMetres)) ?? oldest.altitudeMetres
        let endAltitude = Statistics.median(entries.suffix(3).map(\.altitudeMetres)) ?? newest.altitudeMetres
        let rise = endAltitude - startAltitude
        guard let percent = Convert.gradientPercent(rise: rise, run: run) else { return nil }

        let accuracy = Statistics.mean(entries.map(\.accuracyMetres)) ?? 10
        let signalToNoise = abs(rise) / max(1, accuracy * 1.5)
        let distanceFactor = Statistics.clamp(run / windowMetres, 0...1)
        let confidence = Statistics.clamp(min(1, signalToNoise) * distanceFactor, 0...1)

        return GradientEstimate(percent: percent,
                                overDistanceMetres: run,
                                altitudeChangeMetres: rise,
                                confidence: confidence)
    }
}

/// Cumulative climb and descent over a route.
///
/// Uses hysteresis: altitude has to move by more than the threshold before it counts,
/// otherwise metre-scale GPS noise accumulates into hundreds of fictional metres of
/// climb over a long drive.
struct ElevationAccumulator: Sendable, Equatable {
    private(set) var gainMetres: Double = 0
    private(set) var lossMetres: Double = 0
    private var anchor: Double?
    let thresholdMetres: Double

    init(thresholdMetres: Double = 4.0) {
        self.thresholdMetres = thresholdMetres
    }

    mutating func add(altitudeMetres: Double) {
        guard let currentAnchor = anchor else {
            anchor = altitudeMetres
            return
        }
        let delta = altitudeMetres - currentAnchor
        guard abs(delta) >= thresholdMetres else { return }
        if delta > 0 { gainMetres += delta } else { lossMetres += -delta }
        anchor = altitudeMetres
    }

    var netMetres: Double { gainMetres - lossMetres }
}
