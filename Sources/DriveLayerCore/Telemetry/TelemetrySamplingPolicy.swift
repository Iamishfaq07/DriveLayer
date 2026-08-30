import Foundation

/// Decides what actually gets written to disk.
///
/// A drive can last hours. Storing every reading at its polling rate would write
/// millions of rows for no benefit — nobody needs coolant temperature at 1 Hz three
/// months later. Each metric gets a maximum interval and a deadband: a sample is kept
/// when enough time has passed *or* the value moved enough to be interesting.
struct TelemetrySamplingPolicy: Sendable {

    struct Rule: Sendable, Equatable {
        /// Write at least this often while the value is being reported.
        var maximumIntervalSeconds: TimeInterval
        /// Write immediately when the value moves by at least this much.
        var deadband: Double
    }

    static let `default` = TelemetrySamplingPolicy()

    private let rules: [VehicleMetric: Rule] = [
        .engineRPM: Rule(maximumIntervalSeconds: 10, deadband: 250),
        .vehicleSpeedKmh: Rule(maximumIntervalSeconds: 10, deadband: 5),
        .engineLoadPercent: Rule(maximumIntervalSeconds: 15, deadband: 8),
        .coolantTemperatureC: Rule(maximumIntervalSeconds: 60, deadband: 1.5),
        .intakeAirTemperatureC: Rule(maximumIntervalSeconds: 120, deadband: 2),
        .ambientAirTemperatureC: Rule(maximumIntervalSeconds: 300, deadband: 1),
        .throttlePositionPercent: Rule(maximumIntervalSeconds: 15, deadband: 10),
        .fuelLevelPercent: Rule(maximumIntervalSeconds: 120, deadband: 0.5),
        .fuelRateLitresPerHour: Rule(maximumIntervalSeconds: 15, deadband: 0.8),
        .controlModuleVoltageV: Rule(maximumIntervalSeconds: 120, deadband: 0.15),
        .intakeManifoldPressureKPa: Rule(maximumIntervalSeconds: 30, deadband: 8)
    ]

    private let fallback = Rule(maximumIntervalSeconds: 60, deadband: 1)

    func rule(for metric: VehicleMetric) -> Rule { rules[metric] ?? fallback }

    func shouldPersist(metric: VehicleMetric,
                       value: Double,
                       lastPersisted: (value: Double, timestamp: Date)?,
                       now: Date) -> Bool {
        guard let lastPersisted else { return true }
        let rule = rule(for: metric)
        if now.timeIntervalSince(lastPersisted.timestamp) >= rule.maximumIntervalSeconds { return true }
        return abs(value - lastPersisted.value) >= rule.deadband
    }
}

/// Applies the policy to a live telemetry stream and produces the samples worth keeping.
struct TelemetryDownsampler: Sendable {
    let policy: TelemetrySamplingPolicy
    private var lastPersisted: [VehicleMetric: (value: Double, timestamp: Date)] = [:]

    init(policy: TelemetrySamplingPolicy = .default) {
        self.policy = policy
    }

    mutating func reset() { lastPersisted.removeAll() }

    /// Returns a sample containing only the metrics that earned their place, or `nil`
    /// when nothing changed enough to be worth writing.
    mutating func consider(_ telemetry: VehicleTelemetry, at now: Date) -> TelemetrySample? {
        var kept: [VehicleMetric: Double] = [:]
        for metric in telemetry.availableMetrics {
            guard let entry = telemetry.entry(metric) else { continue }
            // Only consider readings that arrived recently; stale ones were already handled.
            guard now.timeIntervalSince(entry.timestamp) <= 30 else { continue }
            if policy.shouldPersist(metric: metric, value: entry.value, lastPersisted: lastPersisted[metric], now: now) {
                kept[metric] = entry.value
                lastPersisted[metric] = (entry.value, now)
            }
        }
        guard !kept.isEmpty else { return nil }
        return TelemetrySample(timestamp: now, values: kept)
    }
}
