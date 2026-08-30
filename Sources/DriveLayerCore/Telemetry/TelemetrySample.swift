import Foundation

/// A snapshot of what the vehicle reported at one instant.
///
/// Metrics are optional by construction: a missing key means "not reported", which is
/// categorically different from a value of zero. Nothing in DriveLayer may substitute
/// one for the other.
struct TelemetrySample: Codable, Sendable, Equatable {
    var timestamp: Date
    var values: [VehicleMetric: Double]

    init(timestamp: Date, values: [VehicleMetric: Double] = [:]) {
        self.timestamp = timestamp
        self.values = values
    }

    subscript(metric: VehicleMetric) -> Double? {
        get { values[metric] }
        set { values[metric] = newValue }
    }

    var isEmpty: Bool { values.isEmpty }
}

/// The live picture of the vehicle, assembled from readings that arrive at different
/// rates. Every field carries provenance and an age, because a coolant temperature
/// from four minutes ago is not the same fact as one from four seconds ago.
struct VehicleTelemetry: Sendable, Equatable {
    var updatedAt: Date
    private var entries: [VehicleMetric: Entry] = [:]

    struct Entry: Sendable, Equatable {
        var value: Double
        var timestamp: Date
        var provenance: DataProvenance
    }

    init(updatedAt: Date) {
        self.updatedAt = updatedAt
    }

    mutating func set(_ metric: VehicleMetric, value: Double, at timestamp: Date, provenance: DataProvenance = .measured) {
        entries[metric] = Entry(value: value, timestamp: timestamp, provenance: provenance)
        if timestamp > updatedAt { updatedAt = timestamp }
    }

    /// - Parameter provenance: where the reading came from. Defaults to `.measured`; the
    ///   connection manager passes `.simulated` when the transport is the simulator, so
    ///   synthetic data cannot travel through the app wearing a sensor reading's clothes.
    mutating func apply(_ reading: OBDReading, provenance: DataProvenance = .measured) {
        guard let metric = reading.metric,
              let value = reading.numericValue,
              reading.isPlausible else { return }
        set(metric, value: value, at: reading.timestamp, provenance: provenance)
    }

    /// True when any reading here came from the simulator.
    var containsSimulatedData: Bool {
        entries.values.contains { !$0.provenance.describesRealVehicle }
    }

    func entry(_ metric: VehicleMetric) -> Entry? { entries[metric] }

    func value(_ metric: VehicleMetric) -> Double? { entries[metric]?.value }

    /// A value, but only if it is fresh enough to act on.
    func value(_ metric: VehicleMetric, freshWithin interval: TimeInterval, now: Date) -> Double? {
        guard let entry = entries[metric] else { return nil }
        guard now.timeIntervalSince(entry.timestamp) <= interval else { return nil }
        return entry.value
    }

    func provenanced(_ metric: VehicleMetric) -> Provenanced<Double> {
        guard let entry = entries[metric] else { return .unavailable() }
        return Provenanced(value: entry.value, provenance: entry.provenance, timestamp: entry.timestamp)
    }

    var availableMetrics: Set<VehicleMetric> { Set(entries.keys) }

    var isEmpty: Bool { entries.isEmpty }

    /// Converts to a storable sample, dropping anything staler than the window.
    func sample(at timestamp: Date, freshWithin interval: TimeInterval = 30) -> TelemetrySample {
        var values: [VehicleMetric: Double] = [:]
        for (metric, entry) in entries where timestamp.timeIntervalSince(entry.timestamp) <= interval {
            values[metric] = entry.value
        }
        return TelemetrySample(timestamp: timestamp, values: values)
    }

    /// True when the engine is running, judged from whatever the vehicle reports.
    /// Returns `nil` rather than guessing when there is no basis at all.
    func isEngineRunning(now: Date) -> Bool? {
        if let rpm = value(.engineRPM, freshWithin: 15, now: now) { return rpm > 250 }
        if let voltage = value(.controlModuleVoltageV, freshWithin: 30, now: now) {
            // A charging system is running well above resting battery voltage.
            return voltage > 13.0
        }
        return nil
    }
}
