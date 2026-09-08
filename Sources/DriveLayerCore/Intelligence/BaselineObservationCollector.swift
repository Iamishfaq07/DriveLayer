import Foundation

/// The production learning boundary. A loop tick is not a new sensor observation.
/// Owned per selected vehicle; persisted aggregates retain their existing format.
struct BaselineObservationCollector {
    private var lastObserved: [VehicleMetric: Date] = [:]

    mutating func reset() { lastObserved.removeAll() }

    static func context(telemetry: VehicleTelemetry, now: Date,
                        gradientPercent: Double?) -> BaselineContext? {
        // Voltage is not definitive engine state (accessory chargers exist).
        guard let rpm = telemetry.trustedEntry(.engineRPM, freshWithin: 15, now: now),
              rpm.provenance == .measured else { return nil }
        if rpm.value <= 250 { return .engineOff }
        guard let coolant = telemetry.trustedEntry(.coolantTemperatureC, freshWithin: 60, now: now),
              let speed = telemetry.trustedEntry(.vehicleSpeedKmh, freshWithin: 15, now: now),
              coolant.provenance == .measured, speed.provenance == .measured else { return nil }
        return BaselineEngine.context(speedKmh: speed.value,
                                      engineLoadPercent: telemetry.trustedValue(.engineLoadPercent, freshWithin: 20, now: now),
                                      coolantTemperatureC: coolant.value,
                                      gradientPercent: gradientPercent,
                                      isEngineRunning: true)
    }

    mutating func collect(_ telemetry: VehicleTelemetry, at now: Date,
                          gradientPercent: Double?, into aggregates: inout [BaselineDailyAggregate]) {
        guard !telemetry.containsSimulatedData,
              let context = Self.context(telemetry: telemetry, now: now, gradientPercent: gradientPercent) else { return }
        for metric in [VehicleMetric.coolantTemperatureC, .controlModuleVoltageV,
                       .engineLoadPercent, .fuelRateLitresPerHour] {
            guard context != .engineOff || metric == .controlModuleVoltageV,
                  let entry = telemetry.trustedEntry(metric, freshWithin: 60, now: now),
                  entry.provenance == .measured,
                  isNew(metric, timestamp: entry.timestamp) else { continue }
            add(metric, context: context, value: entry.value, at: entry.timestamp, into: &aggregates)
            // Never mix resting and charging voltage in a supposedly comparable baseline.
            if metric != .controlModuleVoltageV {
                add(metric, context: .any, value: entry.value, at: entry.timestamp, into: &aggregates)
            }
        }

        // Only compare warmed intake deltas with the same operating context.
        guard context != .engineOff, context != .coldEngine,
              let intake = telemetry.trustedEntry(.intakeAirTemperatureC, freshWithin: 30, now: now),
              let ambient = telemetry.trustedEntry(.ambientAirTemperatureC, freshWithin: 120, now: now),
              intake.provenance == .measured, ambient.provenance == .measured,
              isNew(.intakeAmbientDeltaC, timestamp: intake.timestamp) else { return }
        add(.intakeAmbientDeltaC, context: context, value: intake.value - ambient.value,
            at: min(intake.timestamp, ambient.timestamp), into: &aggregates)
    }

    private mutating func isNew(_ metric: VehicleMetric, timestamp: Date) -> Bool {
        if let last = lastObserved[metric], timestamp <= last { return false }
        lastObserved[metric] = timestamp
        return true
    }

    private func add(_ metric: VehicleMetric, context: BaselineContext, value: Double,
                     at timestamp: Date, into aggregates: inout [BaselineDailyAggregate]) {
        BaselineEngine.accumulate(into: &aggregates, key: BaselineKey(metric: metric, context: context),
                                  value: value, at: timestamp)
    }
}
