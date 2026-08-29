import Foundation

/// Small, explainable statistics. Deliberately not machine learning: every number
/// DriveLayer shows a driver has to be defensible in one sentence.
enum Statistics {

    static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Sample standard deviation (n-1). `nil` for fewer than two values.
    static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1, let m = mean(values) else { return nil }
        let sumSquares = values.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (sumSquares / Double(values.count - 1)).squareRoot()
    }

    /// Linear-interpolated percentile. `fraction` is clamped to 0...1.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let clamped = min(max(fraction, 0), 1)
        let position = clamped * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    /// Median absolute deviation — robust to the sensor spikes OBD adapters produce.
    static func medianAbsoluteDeviation(_ values: [Double]) -> Double? {
        guard let med = median(values) else { return nil }
        return median(values.map { abs($0 - med) })
    }

    /// Ordinary least squares slope of `values` against `times` (seconds), returned
    /// per day so trends read as "-0.31 V over 30 days" rather than per-second noise.
    static func slopePerDay(values: [Double], times: [Date]) -> Double? {
        guard values.count == times.count, values.count > 1 else { return nil }
        let x = times.map { $0.timeIntervalSinceReferenceDate }
        guard let meanX = mean(x), let meanY = mean(values) else { return nil }
        var numerator = 0.0
        var denominator = 0.0
        for index in 0..<x.count {
            let dx = x[index] - meanX
            numerator += dx * (values[index] - meanY)
            denominator += dx * dx
        }
        guard denominator > 0 else { return nil }
        return (numerator / denominator) * 86_400
    }

    /// Exponentially weighted moving average. `alpha` in 0...1; higher reacts faster.
    static func exponentialMovingAverage(_ values: [Double], alpha: Double) -> Double? {
        guard let first = values.first else { return nil }
        let a = min(max(alpha, 0), 1)
        var result = first
        for value in values.dropFirst() {
            result = a * value + (1 - a) * result
        }
        return result
    }

    /// Z-score of `value` against a sample. `nil` when the sample is too small or flat.
    static func zScore(value: Double, sample: [Double]) -> Double? {
        guard let m = mean(sample), let sd = standardDeviation(sample), sd > 0.000_001 else { return nil }
        return (value - m) / sd
    }

    /// Drops values further than `threshold` MADs from the median. Used before
    /// building baselines so one bad frame doesn't move "normal".
    static func rejectingOutliers(_ values: [Double], threshold: Double = 4.0) -> [Double] {
        guard values.count >= 5,
              let med = median(values),
              let mad = medianAbsoluteDeviation(values), mad > 0.000_001 else { return values }
        // 1.4826 scales MAD to be comparable with a standard deviation for normal data.
        let scaled = mad * 1.4826
        return values.filter { abs($0 - med) <= threshold * scaled }
    }

    static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
