import Foundation

/// The conditions an observation was taken under.
///
/// Comparing a coolant reading from a long climb with one from a motorway cruise
/// produces a false alarm, so baselines are learned per context and only ever
/// compared like with like.
enum BaselineContext: String, Codable, CaseIterable, Sendable {
    case any
    /// Stationary with the engine running.
    case idle
    /// Steady road speed, moderate load.
    case cruising
    /// Sustained positive gradient.
    case climbing
    /// Engine below its normal operating temperature.
    case coldEngine
    /// Engine warmed up and driving.
    case warmedUp

    var displayName: String {
        switch self {
        case .any: return "all driving"
        case .idle: return "idling"
        case .cruising: return "steady cruising"
        case .climbing: return "climbs"
        case .coldEngine: return "a cold engine"
        case .warmedUp: return "a warm engine"
        }
    }
}

struct BaselineKey: Hashable, Codable, Sendable {
    var metric: VehicleMetric
    var context: BaselineContext

    var storageIdentifier: String { "\(metric.rawValue)|\(context.rawValue)" }
}

/// One day's worth of a metric, in one context.
///
/// Baselines are built from daily aggregates rather than raw samples. A month of
/// per-second readings is millions of rows; a month of daily means is thirty. The
/// trade is that DriveLayer learns what is normal for a *day*, which is exactly the
/// granularity its insights speak in ("trending below your baseline for three weeks").
struct BaselineDailyAggregate: Codable, Sendable, Equatable {
    var key: BaselineKey
    var dayStart: Date
    var count: Int
    var sum: Double
    var minimum: Double
    var maximum: Double

    init(key: BaselineKey, dayStart: Date, firstValue: Double) {
        self.key = key
        self.dayStart = dayStart
        self.count = 1
        self.sum = firstValue
        self.minimum = firstValue
        self.maximum = firstValue
    }

    var mean: Double { count > 0 ? sum / Double(count) : 0 }

    mutating func add(_ value: Double) {
        count += 1
        sum += value
        minimum = Swift.min(minimum, value)
        maximum = Swift.max(maximum, value)
    }
}

/// What "normal for this car" looks like for one metric in one context.
struct MetricBaseline: Codable, Sendable, Equatable {
    var key: BaselineKey
    var dayCount: Int
    var observationCount: Int
    var mean: Double
    var median: Double
    var standardDeviation: Double?
    var percentile10: Double
    var percentile90: Double
    /// Change per day over the window, in the metric's own units.
    var trendPerDay: Double?
    var windowDays: Int
    var updatedAt: Date

    /// Enough history to be worth comparing against.
    var isEstablished: Bool {
        dayCount >= BaselineEngine.minimumDays && observationCount >= BaselineEngine.minimumObservations
    }

    /// Total change over the window implied by the trend, for copy like "-0.31 V over 30 days".
    var trendOverWindow: Double? {
        guard let trendPerDay else { return nil }
        return trendPerDay * Double(min(windowDays, dayCount))
    }

    func delta(from value: Double) -> BaselineDelta {
        let absolute = value - median
        let percent = abs(median) > 0.000_001 ? absolute / abs(median) * 100 : 0
        var zScore: Double?
        if let standardDeviation, standardDeviation > 0.000_001 {
            zScore = (value - mean) / standardDeviation
        }
        let outsideUsualRange = value < percentile10 || value > percentile90
        return BaselineDelta(value: value,
                             baselineMedian: median,
                             absolute: absolute,
                             percent: percent,
                             zScore: zScore,
                             isOutsideUsualRange: outsideUsualRange,
                             isEstablished: isEstablished)
    }
}

struct BaselineDelta: Sendable, Equatable {
    var value: Double
    var baselineMedian: Double
    var absolute: Double
    var percent: Double
    var zScore: Double?
    /// Outside the 10th–90th percentile of the learned range.
    var isOutsideUsualRange: Bool
    var isEstablished: Bool

    enum Direction: String, Sendable { case above, below, inLine }

    var direction: Direction {
        if !isOutsideUsualRange { return .inLine }
        return absolute > 0 ? .above : .below
    }

    /// Statistically notable *and* backed by enough history to say so.
    var isSignificant: Bool {
        guard isEstablished, isOutsideUsualRange else { return false }
        guard let zScore else { return true }
        return abs(zScore) >= 2.0
    }

    /// Phrasing used in insight copy. Never states a cause.
    var comparisonPhrase: String {
        switch direction {
        case .inLine: return "in line with your usual range"
        case .above: return "higher than your usual range"
        case .below: return "lower than your usual range"
        }
    }
}

/// Builds baselines from daily aggregates.
///
/// Explainable statistics only — median, percentiles, standard deviation, ordinary
/// least squares trend — and outliers are rejected before anything is computed so one
/// bad frame from a cheap adapter cannot redefine "normal".
enum BaselineEngine {

    static let minimumDays = 5
    static let minimumObservations = 40
    static let defaultWindowDays = 30

    /// Folds an observation into a day's aggregate.
    static func accumulate(into aggregates: inout [BaselineDailyAggregate],
                           key: BaselineKey,
                           value: Double,
                           at timestamp: Date,
                           calendar: Calendar = .current) {
        let dayStart = calendar.startOfDay(for: timestamp)
        if let index = aggregates.firstIndex(where: { $0.key == key && $0.dayStart == dayStart }) {
            aggregates[index].add(value)
        } else {
            aggregates.append(BaselineDailyAggregate(key: key, dayStart: dayStart, firstValue: value))
        }
    }

    static func build(key: BaselineKey,
                      from aggregates: [BaselineDailyAggregate],
                      now: Date,
                      windowDays: Int = defaultWindowDays,
                      calendar: Calendar = .current) -> MetricBaseline? {
        guard let cutoff = calendar.date(byAdding: .day, value: -windowDays, to: now) else { return nil }
        let relevant = aggregates
            .filter { $0.key == key && $0.dayStart >= cutoff && $0.dayStart <= now }
            .sorted { $0.dayStart < $1.dayStart }
        guard !relevant.isEmpty else { return nil }

        let dailyMeans = relevant.map(\.mean)
        let cleaned = Statistics.rejectingOutliers(dailyMeans)
        guard let mean = Statistics.mean(cleaned),
              let median = Statistics.median(cleaned),
              let p10 = Statistics.percentile(cleaned, 0.10),
              let p90 = Statistics.percentile(cleaned, 0.90) else { return nil }

        // Trend is computed on the unfiltered series against real dates, so a genuine
        // drift is not mistaken for outliers and discarded.
        let trend = Statistics.slopePerDay(values: dailyMeans, times: relevant.map(\.dayStart))

        return MetricBaseline(key: key,
                              dayCount: relevant.count,
                              observationCount: relevant.reduce(0) { $0 + $1.count },
                              mean: mean,
                              median: median,
                              standardDeviation: Statistics.standardDeviation(cleaned),
                              percentile10: p10,
                              percentile90: p90,
                              trendPerDay: trend,
                              windowDays: windowDays,
                              updatedAt: now)
    }

    /// Builds every baseline present in the aggregates.
    static func buildAll(from aggregates: [BaselineDailyAggregate],
                         now: Date,
                         windowDays: Int = defaultWindowDays,
                         calendar: Calendar = .current) -> [BaselineKey: MetricBaseline] {
        var result: [BaselineKey: MetricBaseline] = [:]
        for key in Set(aggregates.map(\.key)) {
            if let baseline = build(key: key, from: aggregates, now: now, windowDays: windowDays, calendar: calendar) {
                result[key] = baseline
            }
        }
        return result
    }

    /// Classifies the current driving conditions so an observation is filed correctly.
    static func context(speedKmh: Double?,
                        engineLoadPercent: Double?,
                        coolantTemperatureC: Double?,
                        gradientPercent: Double?) -> BaselineContext {
        if let coolant = coolantTemperatureC, coolant < 70 { return .coldEngine }
        if let speed = speedKmh, speed < 3 { return .idle }
        if let gradient = gradientPercent, gradient >= 3 { return .climbing }
        if let speed = speedKmh, speed >= 40, let load = engineLoadPercent, load < 60 { return .cruising }
        return .warmedUp
    }
}
