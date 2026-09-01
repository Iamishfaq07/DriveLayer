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

    /// The gates, owned here so that admitting a reading and judging it cannot come apart.
    ///
    /// This deliberately lives inside the type rather than in the connection manager. The
    /// gate needs the previous accepted value to judge a rate of change, so it has to
    /// persist across readings, and the only way to guarantee every admitted value has
    /// been through it is for the sole mutating entry point to own it.
    private var gates = SensorGateBank()

    struct Entry: Sendable, Equatable {
        var value: Double
        var timestamp: Date
        var provenance: DataProvenance
        /// How much this value is worth trusting. `set` defaults it to `.good` because a
        /// caller stating a value outright - a user entry, a derived figure - is not
        /// making a claim the gate can check.
        var quality: SensorQuality = .good
        /// Why the newest reading for this metric was refused, when one was. Retained so
        /// the UI and the Debug Center can say what is wrong rather than only that
        /// something is.
        var rejectionReason: String?
    }

    init(updatedAt: Date) {
        self.updatedAt = updatedAt
    }

    mutating func set(_ metric: VehicleMetric,
                      value: Double,
                      at timestamp: Date,
                      provenance: DataProvenance = .measured,
                      quality: SensorQuality = .good,
                      rejectionReason: String? = nil) {
        entries[metric] = Entry(value: value,
                                timestamp: timestamp,
                                provenance: provenance,
                                quality: quality,
                                rejectionReason: rejectionReason)
        if timestamp > updatedAt { updatedAt = timestamp }
    }

    /// Admits a decoded reading, or refuses it, and says which.
    ///
    /// Every reading the vehicle produces enters DriveLayer through here, which is why the
    /// gate is here and not in the caller. Before this, the only check was
    /// `reading.isPlausible` - a stateless range test - so a value inside the band was
    /// accepted no matter how it behaved over time. A frame that jumped 80 C in a second,
    /// a reading byte-identical for a minute after the ECU stopped answering, and the
    /// value a sensor sends when it has nothing were all stored as `measured` and passed
    /// on to the baselines, the trip and the screen.
    ///
    /// - Parameters:
    ///   - provenance: where the reading came from. Defaults to `.measured`; the
    ///     connection manager passes `.simulated` when the transport is the simulator, so
    ///     synthetic data cannot travel through the app wearing a sensor reading's clothes.
    ///   - plausibleRange: the band from the PID catalog, so the definition stays in one
    ///     place. Defaults to `nil`, which leaves the range check to `isPlausible` alone.
    /// - Returns: the gate's verdict, so the caller can report a refusal to the driver
    ///   instead of a value quietly failing to change.
    @discardableResult
    mutating func apply(_ reading: OBDReading,
                        provenance: DataProvenance = .measured,
                        plausibleRange: ClosedRange<Double>? = nil,
                        now: Date? = nil) -> SensorAdmission {
        guard let metric = reading.metric, let value = reading.numericValue else {
            return .ignored
        }

        // A value outside the band is rejected before the gate sees it, so one wild frame
        // cannot become the gate's baseline for judging the next reading's rate of change.
        guard reading.isPlausible else {
            markRejected(metric, reason: "outside the range this sensor can report")
            return .rejected(.outsidePlausibleRange(low: plausibleRange?.lowerBound ?? value,
                                                    high: plausibleRange?.upperBound ?? value))
        }

        // Judged from what the vehicle has already reported, not from the reading being
        // admitted: asking whether the engine is running using the value under test would
        // let a bad frame vouch for itself.
        let engineRunning = isEngineRunning(now: now ?? reading.timestamp)

        guard let accepted = gates.offer(value,
                                         metric: metric,
                                         at: reading.timestamp,
                                         plausibleRange: plausibleRange,
                                         engineRunning: engineRunning) else {
            let rejection = gates.rejection(for: metric)
            markRejected(metric, reason: rejection?.explanation)
            return rejection.map(SensorAdmission.rejected) ?? .ignored
        }

        set(metric, value: accepted, at: reading.timestamp, provenance: provenance, quality: .good)
        return .accepted(accepted)
    }

    /// Records that a metric's newest reading was refused, without inventing a value.
    ///
    /// When a good value is already held it stays, downgraded to `.suspect` and carrying
    /// why - the last sensible coolant temperature is worth more than nothing, provided
    /// nobody is told it is current. When there is nothing to hold, the metric stays
    /// absent: a rejected reading must never become an entry, and must never become zero.
    private mutating func markRejected(_ metric: VehicleMetric, reason: String?) {
        guard var entry = entries[metric] else { return }
        entry.quality = .suspect
        entry.rejectionReason = reason
        entries[metric] = entry
    }

    /// What happened to a reading. Returned rather than logged so the caller decides.
    enum SensorAdmission: Equatable, Sendable {
        case accepted(Double)
        case rejected(SensorSanity.Rejection)
        /// Nothing to admit: no metric, or no numeric value. Not a fault.
        case ignored

        var acceptedValue: Double? {
            if case let .accepted(value) = self { return value }
            return nil
        }

        var wasAccepted: Bool { acceptedValue != nil }

        /// Driver-facing reason, when there is one worth showing.
        var rejectionExplanation: String? {
            if case let .rejected(reason) = self { return reason.explanation }
            return nil
        }
    }

    /// How much the held value for a metric is worth trusting.
    func quality(_ metric: VehicleMetric) -> SensorQuality {
        entries[metric]?.quality ?? .unavailable
    }

    /// Why this metric's newest reading was refused, if it was.
    func rejectionReason(_ metric: VehicleMetric) -> String? {
        entries[metric]?.rejectionReason
    }

    /// Forgets the gates' history. Called when the adapter changes: the previous car's
    /// last accepted coolant temperature is not a baseline for this one.
    mutating func resetSensorGates() {
        gates.reset()
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
